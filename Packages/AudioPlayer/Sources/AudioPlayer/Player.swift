import AVFoundation
import Bedrock
import Foundation
import MediaPlayer
import Observation
import SourcesKit

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The player on the main actor: an `AVQueuePlayer` over the tracks, the time in the
/// book as `track start + time in track`, lock screen and remote control,
/// smart rewind after pauses, sleep timer, report every 15 seconds.
///
/// It lives in the shell, not in the sheet: the sheet closes, the audio keeps playing,
/// and the mini player shows it. A new audiobook replaces the old one.
///
/// **Kept audiobooks it plays as `file://` directly, without the bridge.** The
/// ``AudioBridge`` only exists because AVPlayer does not trust the home certificate and cannot
/// carry the token - both are moot for a file on the device.
/// AVFoundation reads files itself most precisely: seeking and scrubbing hit the
/// sample, no partial request, no port that would have to be re-established after returning from
/// the background. Chapters spanning several tracks and the lock screen
/// do not depend on the address but on the ``AudioManifest``: the player computes the time in the book
/// from track start and time in track, wherever the track comes from. Whether a
/// manifest is local is told by ``AudioManifest/local``; ``PlayRules/address(track:in:bridge:)``
/// chooses per track - testable without sound.
@MainActor
@Observable
public final class Player {

    public private(set) var audiobook: Audiobook? {
        didSet { rememberChapter() }
    }
    public private(set) var running = false
    public private(set) var buffering = false
    public private(set) var time: TimeInterval = 0 {
        didSet { rememberChapter() }
    }
    /// The language key of the reason why the audio stopped - `nil` while
    /// everything runs. Set by ``interrupted(_:)``, cleared by the next play.
    public private(set) var failure: String?
    /// The audio dropped (network gone, track no longer fetchable) - the player's queue
    /// then holds a failed track, and it never plays again:
    /// the next play rebuilds it (``play()``).
    private var cutOff = false
    private var trackObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cutOffObservation: Task<Void, Never>?
    public private(set) var image: CGImage?
    /// The running sleep timer and when it ends (for minutes).
    public private(set) var sleep: SleepTimer?
    public private(set) var sleepEnd: Date?
    public let presets: PlayDefaults
    /// Hold on the speed button: temporarily 1x.
    public var held = false { didSet { applySpeed() } }

    public var duration: TimeInterval { audiobook?.volume.duration ?? 0 }
    /// The current chapter - stored and only set on change: as a computed value it depended
    /// on ``time``, and every view with the chapter name (mini player, chapter list) recomputed
    /// twice a second.
    public private(set) var chapterIndex: Int?

    private func rememberChapter() {
        let new = audiobook.flatMap { PlayRules.chapter(for: time, in: $0.volume) }
        if new != chapterIndex { chapterIndex = new }
    }
    public var chapter: Chapter? { chapterIndex.flatMap { audiobook?.volume.chapter[$0] } }
    public var tempo: Double { held ? 1 : presets.tempo }

    private let player = AVQueuePlayer()
    private var bridge: AudioBridge?
    private var trackIndex = 0
    private var items: [ObjectIdentifier: Int] = [:]
    private var timeObserver: Any?
    private var stateObserver: NSKeyValueObservation?
    private var endObservation: Task<Void, Never>?
    private var pausedSince: Date?
    private var lastReported: Date = .distantPast
    private var sleepTask: Task<Void, Never>?
    private var sleepChapter: Int?
    private var sleepExpired = false
    private var remoteControl = false

    public init(presets: PlayDefaults = PlayDefaults()) {
        self.presets = presets
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        // AirPlay: the tracks come via the audio bridge on 127.0.0.1. With "external
        // playback" AVPlayer hands the receiver the address, and the HomePod
        // fetches 127.0.0.1 on itself - one second of buffer, then abort.
        // Hence the device decodes itself and only sends the audio.
        player.allowsExternalPlayback = false
        stateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                guard let self else { return }
                self.buffering = isWaiting
                // The player stopped by itself although nobody pressed pause: the
                // queue ends at a failed track - AVQueuePlayer
                // skips it silently and then stops (fault test: the
                // time stood at 3:59, the button said "Pause"). The state of now is checked,
                // not the reported one - a seek pauses briefly and
                // resumes right away.
                if self.running, self.player.timeControlStatus == .paused, self.time < self.duration - 1 {
                    self.interrupted(track: self.trackIndex, reason: "Player stalled", forced: true)
                }
            }
        }
        // If the player advances to a track that already failed while preloading,
        // no report comes any more - it just stands still. So check on the change.
        trackChangeObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, change in
            guard let item = change.newValue ?? nil, item.status == .failed else { return }
            Task { @MainActor in
                guard let self, let index = self.items[ObjectIdentifier(item)] else { return }
                self.interrupted(track: index, reason: "failed while advancing", forced: true)
            }
        }
    }

    private var trackChangeObserver: NSKeyValueObservation?

    // MARK: - Loading

    /// Prepares the audiobook: start the bridge (only for tracks from the server), queue
    /// the tracks, jump to the state - and does not play yet.
    public func load(_ new: Audiobook) async throws {
        if let old = audiobook, old.id == new.id { return }
        close()
        if new.volume.local {
            bridge = nil
        } else {
            let bridge = try AudioBridge(headerLines: new.headerLines, transport: new.transport)
            _ = try await bridge.launch()
            bridge.set(tracks: new.volume.tracks.map(\.address))
            self.bridge = bridge
        }
        audiobook = new
        failure = nil
        cutOff = false
        time = new.start
        setUpRemoteControl()
        observeTime()
        observeEnd()
        observeCutOff()
        bookSeries(from: new.start)
        updateLockScreen()
        // The cover on the side: `load` waited for it, and through the tunnel an
        // audiobook only played once 1,800 px of image had come through.
        Task { [weak self] in
            let loaded = await new.image()
            guard let self, self.audiobook?.id == new.id else { return }
            self.image = loaded
            self.updateLockScreen()
        }
        Diagnostics.step(
            "Audiobook: \(new.volume.tracks.count) tracks\(new.volume.local ? " from device" : ""), \(new.volume.chapter.count) chapters, from \(PlayRules.clock(new.start))",
            since: nil, area: "Player")
    }

    /// Throws everything away - the state goes out first.
    public func close() {
        guard audiobook != nil else { return }
        report()
        player.pause()
        player.removeAllItems()
        items = [:]
        bridge?.stop()
        bridge = nil
        endObservation?.cancel()
        cutOffObservation?.cancel()
        trackObservers = [:]
        failure = nil
        cutOff = false
        sleepTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        running = false
        audiobook = nil
        image = nil
        sleep = nil
        sleepEnd = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Playing

    public func play() {
        guard audiobook != nil else { return }
        activateSession()
        if let since = pausedSince {
            let back = PlayRules.rewind(afterPause: Date().timeIntervalSince(since))
            if back > 0 { jump(to: time - back, shouldReport: false) }
            pausedSince = nil
        }
        // After a drop the queue holds a failed track - requeue,
        // then the bridge fetches it once more; if the network is back, it continues.
        if cutOff {
            cutOff = false
            failure = nil
            bookSeries(from: time)
        }
        // The sleep timer has expired - play restarts it.
        if sleepExpired, let latest = presets.sleep { set(sleep: latest) }
        sleepExpired = false
        running = true
        player.playImmediately(atRate: Float(tempo))
        updateLockScreen()
    }

    public func pause() {
        guard running else { return }
        player.pause()
        running = false
        pausedSince = Date()
        report()
        updateLockScreen()
    }

    public func switchTo() {
        running ? pause() : play()
    }

    public func jump(around seconds: TimeInterval) {
        jump(to: time + seconds)
    }

    public func jump(to target: TimeInterval, shouldReport: Bool = true) {
        guard let audiobook else { return }
        let new = min(max(target, 0), max(duration - 0.5, 0))
        guard let index = PlayRules.track(for: new, in: audiobook.volume) else { return }
        let track = audiobook.volume.tracks[index]
        time = new
        let inTrack = CMTime(seconds: new - track.startTime, preferredTimescale: 600)
        if index == trackIndex, let current = player.currentItem, items[ObjectIdentifier(current)] == index {
            player.seek(to: inTrack, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let ran = running
            bookSeries(from: new)
            if ran { player.playImmediately(atRate: Float(tempo)) }
        }
        if shouldReport { report() }
        updateLockScreen()
    }

    /// "Back" with chapter threshold.
    public func previousChapter() {
        guard let audiobook else { return }
        jump(to: PlayRules.previousChapter(from: time, in: audiobook.volume))
    }

    public func nextChapter() {
        guard let audiobook, let target = PlayRules.nextChapter(from: time, in: audiobook.volume) else {
            return
        }
        jump(to: target)
    }

    public func set(tempo new: Double) {
        presets.tempo = min(max(new, 0.5), 3)
        applySpeed()
    }

    private func applySpeed() {
        player.defaultRate = Float(tempo)
        if running { player.rate = Float(tempo) }
        updateLockScreen()
    }

    // MARK: - Sleep timer

    public func set(sleep new: SleepTimer?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleep = new
        sleepEnd = nil
        sleepChapter = nil
        sleepExpired = false
        guard let new else { return }
        presets.sleep = new
        switch new {
        case .minutes(let n):
            let end = Date().addingTimeInterval(TimeInterval(n) * 60)
            sleepEnd = end
            sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(TimeInterval(n) * 60))
                guard !Task.isCancelled else { return }
                self?.sleepNow()
            }
        case .chapterEnd:
            sleepChapter = chapterIndex
        }
    }

    private func sleepNow() {
        sleep = nil
        sleepEnd = nil
        sleepChapter = nil
        sleepExpired = true
        pause()
        Diagnostics.step("Sleep timer: pause", since: nil, area: "Player")
    }

    // MARK: - Internals

    /// Queues the track at the time and the next one - the queue does not hold more,
    /// and the bridge only fetches what the player asks for.
    private func bookSeries(from time: TimeInterval) {
        guard let audiobook, let index = PlayRules.track(for: time, in: audiobook.volume) else {
            return
        }
        player.removeAllItems()
        items = [:]
        trackObservers = [:]
        trackIndex = index
        for i in index..<min(index + 2, audiobook.volume.tracks.count) {
            bookSeries(track: i, via: bridge)
        }
        let track = audiobook.volume.tracks[index]
        player.seek(
            to: CMTime(seconds: time - track.startTime, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
    }

    private func observeTime() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        // After a drop the player stands on a track that never ran - its
        // time says nothing; the state stays where ``interrupted(track:reason:forced:)``
        // set it.
        guard !cutOff, let audiobook, let current = player.currentItem,
            let index = items[ObjectIdentifier(current)]
        else {
            return
        }
        trackIndex = index
        let inTrack = player.currentTime().seconds
        guard inTrack.isFinite else { return }
        let previously = chapterIndex
        time = audiobook.volume.tracks[index].startTime + inTrack
        if running, Date().timeIntervalSince(lastReported) >= PlayRules.reportInterval { report() }
        if let sleepChapter, let now = chapterIndex, now != sleepChapter { sleepNow() }
        if previously != chapterIndex { updateLockScreen() }
    }

    private func observeEnd() {
        endObservation?.cancel()
        endObservation = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification)
            {
                guard let self, let item = notification.object as? AVPlayerItem,
                    let index = items[ObjectIdentifier(item)]
                else { continue }
                items[ObjectIdentifier(item)] = nil
                trackEnd(index)
            }
        }
    }

    private func trackEnd(_ index: Int) {
        guard let audiobook else { return }
        if index + 1 >= audiobook.volume.tracks.count {
            time = duration
            running = false
            player.pause()
            report()
            updateLockScreen()
            Diagnostics.step("Audiobook finished", since: nil, area: "Player")
            return
        }
        trackIndex = index + 1
        let next = index + 2
        if next < audiobook.volume.tracks.count, !items.values.contains(next) {
            bookSeries(track: next, via: bridge)
        }
    }

    /// Appends a track at the back - and watches over it: a track the bridge
    /// cannot fetch (network gone) reports `.failed`, and the player would stand
    /// silent while ``running`` kept saying "playing".
    private func bookSeries(track index: Int, via bridge: AudioBridge?) {
        guard let audiobook,
            let address = PlayRules.address(track: index, in: audiobook.volume, bridge: bridge?.address)
        else { return }
        let item = AVPlayerItem(url: address)
        items[ObjectIdentifier(item)] = index
        trackObservers[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error.map { String(describing: $0) } ?? "Track failed"
            Task { @MainActor in self?.interrupted(track: index, reason: reason) }
        }
        player.insert(item, after: nil)
    }

    /// `AVPlayerItemFailedToPlayToEndTime`: the track started and dropped - the
    /// connection fell in the middle of the buffer.
    private func observeCutOff() {
        cutOffObservation?.cancel()
        cutOffObservation = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVPlayerItem.failedToPlayToEndTimeNotification)
            {
                guard let self, let item = notification.object as? AVPlayerItem,
                    let index = items[ObjectIdentifier(item)]
                else { continue }
                let reason =
                    (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).map {
                        String(describing: $0)
                    } ?? "dropped"
                interrupted(track: index, reason: reason)
            }
        }
    }

    /// The audio dropped: stop cleanly like a pause - report the state, queue
    /// smart rewind - and say why. No empty player, no play button
    /// tapping into the void: the next ``play()`` requeues and tries again.
    /// A failed track that is not up yet (the preloaded next one)
    /// stops nothing - only when the player reaches it.
    private func interrupted(track index: Int, reason: String, forced: Bool = false) {
        guard audiobook != nil, !cutOff else { return }
        let active = player.currentItem.flatMap { items[ObjectIdentifier($0)] }
        Diagnostics.network.error(
            "Player: track \(index, privacy: .public) failed (\(reason, privacy: .public)), current: \(active ?? -1, privacy: .public)"
        )
        guard forced || active == nil || active == index || player.timeControlStatus != .playing else {
            return
        }
        cutOff = true
        failure = "player.interrupted"
        player.pause()
        // AVQueuePlayer skips a failed track silently and then stands on the
        // next - at time zero, i.e. at the start of the minute after next. Nothing of
        // that was heard: the state is the start of the track that was missing (test: the
        // player showed 5:00, but only up to 4:00 was heard).
        if active != index, let audiobook, audiobook.volume.tracks.indices.contains(index) {
            time = min(time, audiobook.volume.tracks[index].startTime)
        }
        if running {
            running = false
            pausedSince = Date()
            report()
        }
        updateLockScreen()
    }

    private func report() {
        guard let audiobook else { return }
        lastReported = Date()
        audiobook.report(time, PlayRules.finished(time, duration: duration))
    }

    // MARK: - Lock screen and remote control

    private func activateSession() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try? session.setActive(true)
        #endif
    }

    private func updateLockScreen() {
        guard let audiobook else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: audiobook.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: running ? tempo : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: tempo,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let subline = audiobook.subline { info[MPMediaItemPropertyArtist] = subline }
        // The chapter name appears on the lock screen - as "album".
        if let chapter { info[MPMediaItemPropertyAlbumTitle] = chapter.name }
        // MediaPlayer fetches the image on its own queue - the callback
        // must not hang on the main actor (`@Sendable`), otherwise the
        // isolation check aborts (crash at the first real cover).
        if let image {
            #if canImport(UIKit)
                let artwork = UIImage(cgImage: image)
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) {
                    @Sendable _ in artwork
                }
            #else
                let artwork = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) {
                    @Sendable _ in artwork
                }
            #endif
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(iOS)
            MPNowPlayingInfoCenter.default().playbackState = running ? .playing : .paused
        #endif
    }

    /// Headphone buttons and lock screen: play, pause, skip forward/back by the
    /// configured distances, "next/previous track" = skip, slider.
    private func setUpRemoteControl() {
        guard !remoteControl else { return }
        remoteControl = true
        let hub = MPRemoteCommandCenter.shared()
        hub.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        hub.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        hub.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.switchTo() }
            return .success
        }
        hub.skipForwardCommand.preferredIntervals = [NSNumber(value: presets.jumpForward)]
        hub.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.jump(around: TimeInterval($0.presets.jumpForward)) } }
            return .success
        }
        hub.skipBackwardCommand.preferredIntervals = [NSNumber(value: presets.jumpBack)]
        hub.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.jump(around: -TimeInterval($0.presets.jumpBack)) } }
            return .success
        }
        hub.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.jump(around: TimeInterval($0.presets.jumpForward)) } }
            return .success
        }
        hub.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.jump(around: -TimeInterval($0.presets.jumpBack)) } }
            return .success
        }
        hub.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let layout = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.jump(to: layout.positionTime) }
            return .success
        }
        hub.changePlaybackRateCommand.supportedPlaybackRates = PlayRules.tempos.map {
            NSNumber(value: $0)
        }
        hub.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let t = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.set(tempo: Double(t.playbackRate)) }
            return .success
        }
        #if os(iOS)
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVAudioSession.interruptionNotification)
                {
                    guard let self,
                        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                        let kind = AVAudioSession.InterruptionType(rawValue: raw)
                    else { continue }
                    switch kind {
                    case .began: pause()
                    case .ended:
                        let options = AVAudioSession.InterruptionOptions(
                            rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                                ?? 0)
                        if options.contains(.shouldResume) { play() }
                    @unknown default: break
                    }
                }
            }
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVAudioSession.routeChangeNotification)
                {
                    guard let self,
                        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                        AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                    else { continue }
                    // Headphones out: pause, do not keep talking from the speaker.
                    pause()
                }
            }
        #endif
    }
}
