import Foundation

/// Acknowledgement of one external metadata or lyrics service.
public struct ProviderPrivacyConsent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let providerID: String
    public let policyVersion: String

    public init(providerID: String, policyVersion: String) {
        self.providerID = providerID
        self.policyVersion = policyVersion
    }

    public var id: String { providerID }
}

/// Persisted privacy acknowledgements for online enrichment services.
public struct PrivacyPreferences: Codable, Equatable, Hashable, Sendable {
    public static let currentPrivacyPolicyVersion = "1.1.0"
    public static let currentProviderPolicyVersion = "1.1.0"

    public let privacyPolicyVersion: String?
    public let providerConsents: [ProviderPrivacyConsent]

    public init(
        privacyPolicyVersion: String? = nil,
        providerConsents: [ProviderPrivacyConsent] = []
    ) {
        self.privacyPolicyVersion = privacyPolicyVersion

        var seen = Set<String>()
        self.providerConsents = providerConsents.filter { consent in
            !consent.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(consent.providerID).inserted
        }
    }

    public static let defaults = Self()

    public var isPrivacyPolicyAccepted: Bool {
        privacyPolicyVersion == Self.currentPrivacyPolicyVersion
    }

    public func isProviderPolicyAccepted(_ providerID: String) -> Bool {
        guard isPrivacyPolicyAccepted else { return false }
        return providerConsents.contains {
            $0.providerID == providerID
                && $0.policyVersion == Self.currentProviderPolicyVersion
        }
    }

    public func acceptingPrivacyPolicy() -> Self {
        let preservedProviderConsents = isPrivacyPolicyAccepted ? providerConsents : []
        return Self(
            privacyPolicyVersion: Self.currentPrivacyPolicyVersion,
            providerConsents: preservedProviderConsents
        )
    }

    public func acceptingProviderPolicy(_ providerID: String) -> Self {
        guard isPrivacyPolicyAccepted else { return self }

        let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return self }

        let remaining = providerConsents.filter { $0.providerID != normalizedID }
        return Self(
            privacyPolicyVersion: privacyPolicyVersion,
            providerConsents: remaining + [
                ProviderPrivacyConsent(
                    providerID: normalizedID,
                    policyVersion: Self.currentProviderPolicyVersion
                )
            ]
        )
    }

    public func revokingProviderPolicy(_ providerID: String) -> Self {
        Self(
            privacyPolicyVersion: privacyPolicyVersion,
            providerConsents: providerConsents.filter {
                $0.providerID != providerID
            }
        )
    }

    public static func revokingOnlineServices() -> Self {
        .defaults
    }
}
