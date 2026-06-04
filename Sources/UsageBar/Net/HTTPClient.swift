import Foundation

/// A deliberately small, synchronous HTTP client with three safety properties
/// baked in and not configurable away:
///
///   1. HOST ALLOWLIST. Every request's host must appear in `allowedHosts`,
///      which is the union of the hosts each enabled provider explicitly
///      declares. A request to anything else throws before a single byte leaves
///      the machine. This is the guarantee that "sensitive data never goes
///      anywhere except the provider APIs."
///
///   2. NO REDIRECTS. A 3xx is returned as-is, never followed. A redirect is a
///      classic way to bounce an authenticated request to an attacker host;
///      we refuse to play. (Matches the upstream tool's "policy: none".)
///
///   3. HTTPS ONLY. Plain http is rejected. TLS is validated by the OS trust
///      store (URLSession default) — we rely on the platform here rather than
///      hand-rolling certificate handling, which is the "don't reinvent the
///      internet" line.
///
/// It is synchronous (blocks the calling thread until the response or timeout)
/// because providers run on a background worker and read far more clearly
/// without nested callbacks. The networking itself is still async under the hood.
final class HTTPClient: NSObject, URLSessionTaskDelegate {

    struct Response {
        let status: Int
        let headers: [AnyHashable: Any]
        let body: Data

        var bodyText: String { String(data: body, encoding: .utf8) ?? "" }

        /// Case-insensitive header lookup.
        func header(_ name: String) -> String? {
            for (k, v) in headers {
                if let ks = k as? String, ks.caseInsensitiveCompare(name) == .orderedSame {
                    return v as? String
                }
            }
            return nil
        }
    }

    enum Method: String { case GET, POST }

    private let allowedHosts: Set<String>
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral   // no on-disk cache/cookies
        cfg.httpCookieStorage = nil                    // we set any cookies explicitly
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
        super.init()
    }

    /// Break the session→delegate(self) retain cycle when this client is being
    /// discarded (e.g. the allowlist changed and a new client is taking over).
    /// Without this, URLSession holds the delegate forever and the old client
    /// leaks. Safe to call on a client whose session was never used.
    func invalidate() {
        session.invalidateAndCancel()
    }

    /// Perform a request. Throws `UsageError` on disallowed host, bad URL,
    /// non-HTTPS, network failure, or timeout.
    func request(_ method: Method,
                 _ urlString: String,
                 headers: [String: String] = [:],
                 body: Data? = nil,
                 timeout: TimeInterval = 12) throws -> Response {

        guard let url = URL(string: urlString) else {
            throw UsageError("Bad URL.")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw UsageError("Refusing non-HTTPS request.")
        }
        guard let host = url.host, isAllowed(host) else {
            // This is the allowlist firing. Surface it loudly in logs (host is
            // not sensitive) so an unexpected egress attempt is obvious.
            Log.error("BLOCKED egress to disallowed host: \(url.host ?? "nil")")
            throw UsageError("Blocked: \(url.host ?? "unknown host") is not allowlisted.")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            req.httpBody = body
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Response, Error> = .failure(UsageError("No response."))

        let task = session.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                result = .failure(UsageError("Network error: \(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(UsageError("Not an HTTP response."))
                return
            }
            result = .success(Response(status: http.statusCode,
                                       headers: http.allHeaderFields,
                                       body: data ?? Data()))
        }
        task.resume()

        // Block the worker thread until done or hard ceiling. The +5 gives the
        // URLSession-level timeout a chance to fire its own error first.
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw UsageError("Request timed out.")
        }

        return try result.get()
    }

    private func isAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        if allowedHosts.contains(h) { return true }
        // Allow exact subdomains of an allowlisted apex (e.g. "api2.cursor.sh"
        // is allowed if "cursor.sh" is listed) but NOT arbitrary suffixes.
        for allowed in allowedHosts where h.hasSuffix("." + allowed) {
            return true
        }
        return false
    }

    // MARK: URLSessionTaskDelegate

    /// Refuse all redirects. Returning nil completes the task with the 3xx
    /// response instead of following it.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        Log.warn("Redirect refused: \(response.statusCode) -> \(request.url?.host ?? "nil")")
        completionHandler(nil)
    }
}
