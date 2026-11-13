import Foundation

enum DeliveryResult: Equatable {
    case delivered    // the server took it
    case retryLater   // no connection, a server error, or rate limited: keep the event and try again
    case rejected     // the server refused it for good: drop it
}

protocol Transport: Sendable {
    func deliver(_ body: Data) async -> DeliveryResult
}

/// Posts one event to the server. The session keeps nothing: no cookies, no cache, no credentials.
struct URLSessionTransport: Transport {
    let endpoint: URL
    let session: URLSession

    init(endpoint: URL) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func deliver(_ body: Data) async -> DeliveryResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryLater }
            switch http.statusCode {
            case 200..<300: return .delivered
            case 429, 500...: return .retryLater
            default: return .rejected
            }
        } catch {
            return .retryLater
        }
    }
}
