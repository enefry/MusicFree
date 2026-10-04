import Foundation

/// Data-service failures retain retry and diagnostic information across the host bridge.
public enum PluginDataError: Error, Equatable, Sendable {
    case unavailable, noMatch, network, offline, notAuthorized, invalidResponse, payloadTooLarge
    case rateLimited(retryAfterSeconds: Double?, httpStatus: Int?)
    case requestFailed(code: String, httpStatus: Int?)
}
