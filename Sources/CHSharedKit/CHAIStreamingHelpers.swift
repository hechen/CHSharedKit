import Foundation

/// Shared helpers used by streaming provider implementations.
///
/// Kept internal to the concrete providers so each one can reuse the same
/// status-code mapping without reimplementing it. Not part of the public API.
enum CHAIStreamingHelpers {

    /// Maps an HTTP response to a typed `CHAIError` for the common status
    /// codes that streaming calls care about. `domain` is used only for the
    /// generic `networkError` case.
    static func checkHTTP(_ response: URLResponse, domain: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CHAIError.networkError(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299: return
        case 401: throw CHAIError.invalidKey
        case 429: throw CHAIError.rateLimited
        default:
            throw CHAIError.networkError(
                NSError(domain: domain, code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            )
        }
    }
}
