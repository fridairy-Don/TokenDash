import Foundation

// MARK: - APIError

enum APIError: Error, CustomStringConvertible {
    case invalidURL(String)
    case transport(URLError)
    case httpStatus(Int, Data)
    case decode(Error)
    case giveUp(String)

    var description: String {
        switch self {
        case .invalidURL(let s): return "invalid URL: \(s)"
        case .transport(let e):  return "transport: \(e.localizedDescription)"
        case .httpStatus(let c, _): return "HTTP \(c)"
        case .decode(let e):     return "decode: \(e.localizedDescription)"
        case .giveUp(let s):     return "gave up: \(s)"
        }
    }
}

// MARK: - APIClient
//
// One shared actor for every provider's HTTP call.
//   - 10s default timeout
//   - 2 retries on transient failures (network down, 5xx, 429) with exponential
//     backoff capped at 4s
//   - honours Retry-After on 429 responses
//   - respects a per-host minimum gap so we don't hammer rate-limited APIs when
//     multiple providers happen to share a refresh cycle
//
// Each provider still does its own JSON decoding because shapes differ wildly.

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private var lastRequestByHost: [String: Date] = [:]
    private let minHostGap: TimeInterval = 0.15

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    /// Perform a GET with retries. Returns raw Data on 2xx, throws APIError otherwise.
    func getData(url: URL, headers: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let timeout { req.timeoutInterval = timeout }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await perform(req)
    }

    func getJSON<T: Decodable>(_ type: T.Type,
                               url: URL,
                               headers: [String: String] = [:],
                               decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await getData(url: url, headers: headers)
        do { return try decoder.decode(type, from: data) }
        catch { throw APIError.decode(error) }
    }

    /// POST with body + headers. Returns the full HTTPURLResponse alongside
    /// the body so callers can read response headers (e.g. Groq's x-ratelimit-*
    /// which is the ONLY way to surface live quota).
    func postWithHeaders(url: URL,
                        body: Data,
                        headers: [String: String] = [:],
                        timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        if let timeout { req.timeoutInterval = timeout }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "Content-Type") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await performWithResponse(req)
    }

    // MARK: - Core

    private func perform(_ request: URLRequest) async throws -> Data {
        let host = request.url?.host ?? ""
        await throttle(host: host)

        var attempt = 0
        let maxAttempts = 3
        var lastErr: APIError?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastErr = .giveUp("non-HTTP response")
                    break
                }
                let code = http.statusCode
                if (200..<300).contains(code) { return data }
                if code == 429 || (500..<600).contains(code) {
                    let wait = Self.retryAfter(http) ?? Self.backoff(attempt)
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        continue
                    }
                }
                throw APIError.httpStatus(code, data)
            } catch let urlErr as URLError {
                lastErr = .transport(urlErr)
                if Self.isTransient(urlErr) && attempt < maxAttempts {
                    let wait = Self.backoff(attempt)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                throw APIError.transport(urlErr)
            } catch let e as APIError {
                throw e
            } catch {
                throw APIError.giveUp(error.localizedDescription)
            }
        }
        throw lastErr ?? .giveUp("unknown")
    }

    /// Same retry/backoff/throttle as `perform` but returns the full response
    /// instead of just the body. Used when callers need response headers.
    private func performWithResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        await throttle(host: host)

        var attempt = 0
        let maxAttempts = 3
        var lastErr: APIError?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastErr = .giveUp("non-HTTP response")
                    break
                }
                let code = http.statusCode
                if (200..<300).contains(code) { return (data, http) }
                if code == 429 || (500..<600).contains(code) {
                    let wait = Self.retryAfter(http) ?? Self.backoff(attempt)
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        continue
                    }
                }
                // Return non-2xx with headers so caller can still read rate-limit
                // info from a 429 (that's actually the most useful 429 to parse).
                if code == 429 { return (data, http) }
                throw APIError.httpStatus(code, data)
            } catch let urlErr as URLError {
                lastErr = .transport(urlErr)
                if Self.isTransient(urlErr) && attempt < maxAttempts {
                    let wait = Self.backoff(attempt)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                throw APIError.transport(urlErr)
            } catch let e as APIError {
                throw e
            } catch {
                throw APIError.giveUp(error.localizedDescription)
            }
        }
        throw lastErr ?? .giveUp("unknown")
    }

    private func throttle(host: String) async {
        guard !host.isEmpty else { return }
        if let last = lastRequestByHost[host] {
            let since = Date().timeIntervalSince(last)
            if since < minHostGap {
                let remaining = minHostGap - since
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRequestByHost[host] = Date()
    }

    // MARK: - Helpers

    private static func backoff(_ attempt: Int) -> TimeInterval {
        // 0.4s, 1.2s, 4s with light jitter
        let base = min(4.0, pow(3.0, Double(attempt - 1)) * 0.4)
        let jitter = Double.random(in: 0.8...1.2)
        return base * jitter
    }

    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let v = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(v) { return min(seconds, 10) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = df.date(from: v) { return min(d.timeIntervalSinceNow, 10) }
        return nil
    }

    private static func isTransient(_ err: URLError) -> Bool {
        switch err.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
