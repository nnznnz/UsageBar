import Foundation

/// Reads single values out of a SQLite database in strict read-only mode.
///
/// Used only for the Cursor provider, whose desktop app keeps its auth token in
/// a plain SQLite file (`state.vscdb`). Rather than link a SQLite wrapper (a
/// dependency to vet) or ship our own parser (reinventing a database engine),
/// we shell out to `/usr/bin/sqlite3`, which Apple ships with macOS. It's
/// opened `immutable=1` so we can read even while Cursor is running and never
/// touch the file's contents or its write-ahead log.
enum SQLiteReader {

    /// Run a query that returns a single scalar string, or nil.
    /// `keys` are looked up against the well-known `ItemTable(key TEXT, value)`
    /// schema VS Code / Cursor use. Key names are hard-coded constants supplied
    /// by the caller (never user input), so there is no injection surface here.
    static func value(dbPath: String, key: String) -> String? {
        let expanded = Files.expand(dbPath)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            Log.warn("sqlite3 not found at /usr/bin/sqlite3; Cursor provider unavailable.")
            return nil
        }

        // Keys are fixed constants from our own code, but escape defensively
        // anyway: double up any single quotes.
        let safeKey = key.replacingOccurrences(of: "'", with: "''")
        let uri = fileURI(forExpandedPath: expanded)
        let sql = "SELECT value FROM ItemTable WHERE key = '\(safeKey)' LIMIT 1;"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = ["-readonly", "-batch", "-noheader", uri, sql]

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Signal exit via the termination handler so we can bound the wait. The
        // query returns a single tiny value, so the output pipe can't fill and
        // deadlock before exit.
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            Log.warn("sqlite3 launch failed: \(error.localizedDescription)")
            return nil
        }

        // If sqlite3 wedges (locked/corrupt DB, odd filesystem), don't let it
        // freeze the single provider worker forever — terminate after a few sec.
        if done.wait(timeout: .now() + 5) == .timedOut {
            proc.terminate()
            Log.warn("sqlite3 read timed out for Cursor DB; terminated.")
            return nil
        }

        guard proc.terminationStatus == 0 else {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !errText.isEmpty { Log.info("sqlite3 read failed: \(errText)") }
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Build a SQLite `file:` URI for a filesystem path, percent-encoding it so
    /// spaces (the default Cursor path has one: "Application Support") and other
    /// reserved characters (`?`, `#`, `%`) can't break URI parsing. Static +
    /// internal so it's unit-testable. `immutable=1` lets us read a DB that the
    /// running Cursor app holds open, without touching it.
    static func fileURI(forExpandedPath path: String) -> String {
        // URL(fileURLWithPath:) yields a correctly percent-encoded file:// URL.
        let encoded = URL(fileURLWithPath: path).absoluteString
        return encoded + "?immutable=1"
    }
}
