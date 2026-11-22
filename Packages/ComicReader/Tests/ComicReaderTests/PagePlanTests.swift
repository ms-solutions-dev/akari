import Foundation
import SourcesKit
import Testing

@testable import ComicReader

@Suite("Page plan")
struct PagePlanTests {

    private func portrait(_ n: Int) -> [PageSize] {
        Array(repeating: PageSize(width: 1008, height: 1457), count: n)
    }

    @Test("Single page: one spread per page, whatever the measures")
    func single() {
        let plan = PagePlan(count: 5, measures: portrait(5), doubleSpread: false)
        #expect(plan.spreads == [.single(1), .single(2), .single(3), .single(4), .single(5)])
        #expect(plan.spread(with: 3) == .single(3))
        #expect(plan.next(to: .single(5)) == nil)
        #expect(plan.previous(before: .single(1)) == nil)
    }

    @Test("Double spread right-to-left: cover alone, then 3|2, 5|4, and 6 alone at the end")
    func doubleRtl() {
        let plan = PagePlan(count: 6, measures: portrait(6), doubleSpread: true, direction: .rightToLeft)
        #expect(
            plan.spreads == [
                .single(1), .double(links: 3, right: 2), .double(links: 5, right: 4), .single(6),
            ])
        #expect(plan.spread(with: 3)?.first == 2)
        // Scrolled, the cover sits at the far right, i.e. at the end of the row.
        #expect(plan.flattened.first == .single(6))
        #expect(plan.flattened.last == .single(1))
    }

    @Test("Double spread left-to-right: 2|3, 4|5")
    func doubleLtr() {
        let plan = PagePlan(count: 5, measures: portrait(5), doubleSpread: true, direction: .leftToRight)
        #expect(plan.spreads == [.single(1), .double(links: 2, right: 3), .double(links: 4, right: 5)])
        #expect(plan.flattened == plan.spreads)
    }

    @Test("A landscape image stands alone and restarts the pairing")
    func landscapeImage() {
        var measures = portrait(8)
        measures[3] = PageSize(width: 2016, height: 1457)  // page 4 landscape
        let plan = PagePlan(count: 8, measures: measures, doubleSpread: true, direction: .rightToLeft)
        #expect(
            plan.spreads == [
                .single(1), .double(links: 3, right: 2), .single(4), .double(links: 6, right: 5),
                .double(links: 8, right: 7),
            ])
    }

    @Test("Without a manifest all pages count as portrait; without the cover rule it starts 2|1")
    func withoutManifest() {
        let plan = PagePlan(count: 4, doubleSpread: true, coverAlone: false, direction: .rightToLeft)
        #expect(plan.spreads == [.double(links: 2, right: 1), .double(links: 4, right: 3)])
        #expect(PagePlan(count: 0).spreads.isEmpty)
    }

    @Test("Measured measures beat the manifest and fill up an empty one")
    func merged() {
        let landscape = PageSize(width: 2000, height: 1400)
        let list = PagePlan.merged([], measured: [3: landscape], count: 5)
        #expect(list.count == 5)
        #expect(list[2] == landscape)
        #expect(!list[0].landscape)
        #expect(PagePlan.merged(portrait(2), measured: [:], count: 5).count == 2)
        #expect(PagePlan.merged(portrait(2), measured: [9: landscape], count: 2).count == 2)
    }

    @Test(
        "A measured measure only counts if it says something new - otherwise every image rebuilds the reader")
    func worthMetering() {
        let manifest = [PageSize(width: 800, height: 1000), PageSize(width: 0, height: 0)]
        // Downscaled, same ratio: nothing new (800 x 1000).
        #expect(!PagePlan.worthMetering(PageSize(width: 400, height: 500), page: 1, manifest: manifest))
        // Different ratio: new - Komga had measured the page wrong.
        #expect(PagePlan.worthMetering(PageSize(width: 1000, height: 800), page: 1, manifest: manifest))
        // Manifest without measure or too short: new.
        #expect(PagePlan.worthMetering(PageSize(width: 800, height: 1000), page: 2, manifest: manifest))
        #expect(PagePlan.worthMetering(PageSize(width: 800, height: 1000), page: 3, manifest: manifest))
    }

    @Test("Webtoon closes on a clear drag to the right, not when scrolling or to the left")
    func webtoonCloseDrag() {
        #expect(ComicReaderView.closesWebtoon(CGSize(width: 140, height: 20)))
        #expect(!ComicReaderView.closesWebtoon(CGSize(width: 60, height: 0)))  // too short
        #expect(!ComicReaderView.closesWebtoon(CGSize(width: 140, height: 120)))  // diagonal: scrolling
        #expect(!ComicReaderView.closesWebtoon(CGSize(width: -200, height: 0)))  // to the left
        #expect(!ComicReaderView.closesWebtoon(CGSize(width: 0, height: 400)))  // vertical
    }

    @Test("Tap zones 25/50/25 - mirrored for right-to-left")
    func tapZones() {
        #expect(TapZone.for(x: 10, width: 400, direction: .leftToRight) == .back)
        #expect(TapZone.for(x: 200, width: 400, direction: .leftToRight) == .hud)
        #expect(TapZone.for(x: 390, width: 400, direction: .leftToRight) == .before)
        #expect(TapZone.for(x: 10, width: 400, direction: .rightToLeft) == .before)
        #expect(TapZone.for(x: 390, width: 400, direction: .rightToLeft) == .back)
        #expect(TapZone.for(x: 100, width: 400, direction: .rightToLeft) == .hud)
        #expect(TapZone.for(x: 5, width: 0, direction: .rightToLeft) == .hud)
    }

    @Test("Preload window: at home 3 back / 5 ahead, on the road ±3, clipped at the edges")
    func window() {
        #expect(Preload.window(around: 10, count: 200, atHome: true) == 7...15)
        #expect(Preload.window(around: 10, count: 200, atHome: false) == 7...13)
        #expect(Preload.window(around: 1, count: 200, atHome: true) == 1...6)
        #expect(Preload.window(around: 199, count: 200, atHome: true) == 196...200)
        #expect(Preload.window(around: 10, count: 1170, atHome: true, vertical: true) == 7...30)
        #expect(Preload.window(around: 10, count: 1170, atHome: false, vertical: true) == 7...20)
    }

    /// Dragged narrower: the same number of screens of stock, not the same number of pages.
    @Test("Preload window in the webtoon grows with narrower width, at most 60 pages")
    func windowWidth() {
        #expect(
            Preload.window(around: 500, count: 1170, atHome: true, vertical: true, width: 0.5) == 497...540)
        #expect(
            Preload.window(around: 500, count: 1170, atHome: true, vertical: true, width: 1.5) == 497...520)
        #expect(
            Preload.window(around: 500, count: 1170, atHome: true, vertical: true, width: 0.25) == 497...560)
        #expect(Preload.window(around: 10, count: 200, atHome: true, width: 0.5) == 7...15)
    }

    /// Continue at page 500, then scroll up: the window lies above.
    @Test("Preload window in the webtoon backwards: 20 up, 3 down; unchanged when paging")
    func windowBackwards() {
        #expect(
            Preload.window(around: 500, count: 1170, atHome: true, vertical: true, backward: true)
                == 480...503)
        #expect(
            Preload.window(around: 500, count: 1170, atHome: false, vertical: true, backward: true)
                == 490...503)
        #expect(
            Preload.window(around: 10, count: 1170, atHome: true, vertical: true, backward: true) == 1...13)
        #expect(Preload.window(around: 10, count: 200, atHome: true, backward: true) == 7...15)
    }

    @Test("The next volume comes from 5 pages before the end - and only at home")
    func nextVolume() {
        #expect(Preload.nextVolume(page: 190, count: 200, atHome: true) == 0)
        #expect(Preload.nextVolume(page: 195, count: 200, atHome: true) == 3)
        #expect(Preload.nextVolume(page: 200, count: 200, atHome: true) == 3)
        #expect(Preload.nextVolume(page: 198, count: 200, atHome: false) == 0)
    }
}

@Suite("Reading defaults")
struct ReadingDefaultsTests {

    private func fresh() -> ReadingDefaults {
        let persistence = UserDefaults(suiteName: "comicleser-test-" + UUID().uuidString)!
        return ReadingDefaults(persistence: persistence)
    }

    @Test("Direction: series beats server beats default - and the default is right-to-left")
    func direction() {
        let v = fresh()
        #expect(v.direction(series: "s1", server: nil) == .rightToLeft)
        #expect(v.direction(series: "s1", server: .leftToRight) == .leftToRight)
        v.set(direction: .rightToLeft, series: "s1")
        #expect(v.direction(series: "s1", server: .leftToRight) == .rightToLeft)
        v.set(direction: nil, series: "s1")
        #expect(v.direction(series: "s1", server: .leftToRight) == .leftToRight)
        v.set(defaultDirection: .leftToRight)
        #expect(v.direction(series: "s2", server: nil) == .leftToRight)
        // Webtoon stays webtoon - the reader then scrolls vertically.
        #expect(v.direction(series: nil, server: .vertical) == .vertical)
    }

    @Test("Double spread is on until a series switches it off")
    func doubleSpread() {
        let v = fresh()
        #expect(v.doubleSpread(series: "s1"))
        #expect(v.doubleSpread(series: nil))
        v.set(doubleSpread: false, series: "s1")
        #expect(!v.doubleSpread(series: "s1"))
        #expect(v.doubleSpread(series: "s2"))
    }

    @Test("Webtoon width: 100 % until a series drags it - limited to 50 to 200 %")
    func width() {
        let v = fresh()
        #expect(v.width(series: "s1") == 1)
        #expect(v.width(series: nil) == 1)
        v.set(width: 0.7, series: "s1")
        #expect(v.width(series: "s1") == 0.7)
        #expect(v.width(series: "s2") == 1)
        v.set(width: 9, series: "s1")
        #expect(v.width(series: "s1") == 2)
        v.set(width: 0.25, series: "s1")
        #expect(v.width(series: "s1") == 0.25)
        v.set(width: 0.1, series: "s1")
        #expect(v.width(series: "s1") == 0.25)
        v.set(width: 1, series: "s1")
        #expect(v.width(series: "s1") == 1)
    }
}
