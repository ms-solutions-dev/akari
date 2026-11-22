import Foundation

/// The live probe: tests against the real servers, only on demand.
///
/// `check.sh` runs without a network; the kits test against recordings. Whether a kit
/// talks to **today's** server — sign-in, extract, cover, a written reading state —
/// is shown by the live-probe script: it sets `AKARI_LEBEND=1`, and the tests
/// marked that way read the credentials from the developer's home directory. Without the
/// variable they are skipped, not passed.
public enum LiveProbe {

    public static var wanted: Bool {
        ProcessInfo.processInfo.environment["AKARI_LEBEND"] == "1"
    }

    /// Pauses the probe so that the user can see the written state in the
    /// web UI before it is reset. Duration via
    /// `AKARI_SCHAUPAUSE` in seconds, default 20; `0` skips.
    public static func showPause(_ hint: String) async {
        let seconds = Int(ProcessInfo.processInfo.environment["AKARI_SCHAUPAUSE"] ?? "") ?? 20
        guard seconds > 0 else { return }
        print("\(hint) — \(seconds) s to take a look")
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// `KEY=value` per line, `#` starts comments.
    public static func access() -> [String: String] {
        // The live probe runs on the computer; there is no home directory on the phone —
        // and the mocks are also in the app (`-attrappen`).
        let path = URL(filePath: NSHomeDirectory()).appending(path: ".akari-claude")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let z = line.trimmingCharacters(in: .whitespaces)
            guard !z.hasPrefix("#"), let equal = z.firstIndex(of: "=") else { continue }
            values[String(z[..<equal])] = String(z[z.index(after: equal)...])
        }
        return values
    }

    /// Sends a raw request and returns status, response header and body —
    /// for looking things up when a kit gets "200" and the server did nothing anyway.
    public static func raw(
        _ url: URL, method: String, body: String?, headerLines: [String: String]
    ) async throws
        -> (Int, [String: String], String)
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headerLines { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let header = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
            $0["\($1.key)"] = "\($1.value)"
        }
        return (http?.statusCode ?? 0, header, String(decoding: data, as: UTF8.self))
    }

    /// Fetches an address with the source's header lines and returns status and
    /// content type — for covers and pages that do not run through the kit.
    public static func header(
        _ url: URL, headerLines: [String: String], area: String? = nil
    ) async throws -> (Int, String) {
        var request = URLRequest(url: url)
        for (k, v) in headerLines { request.setValue(v, forHTTPHeaderField: k) }
        if let area { request.setValue(area, forHTTPHeaderField: "Range") }
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
}
