import AppServices
import DesignSystem
import Foundation
import MediaSourceAPI
import MusicDomain
import Observation
import SettingsAPI

public struct DSAudioSourceAuthorizationRequest: Sendable {
    public let sourceID: MediaSourceID
    public let endpoint: URL
    public let displayName: String
    public let account: String
    public let password: String
    public let deviceName: String
    public let oneTimeCode: String?
    public let challengeToken: String?

    public init(
        sourceID: MediaSourceID,
        endpoint: URL,
        displayName: String = "",
        account: String,
        password: String,
        deviceName: String,
        oneTimeCode: String? = nil,
        challengeToken: String? = nil
    ) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.displayName = displayName
        self.account = account
        self.password = password
        self.deviceName = deviceName
        self.oneTimeCode = oneTimeCode
        self.challengeToken = challengeToken
    }
}

public enum DSAudioSourceAuthorizationResult: Sendable {
    case verificationRequired(challengeToken: String?)
    case authorized
}

public typealias DSAudioSourceAuthorizer = @Sendable (
    _ request: DSAudioSourceAuthorizationRequest
) async throws -> DSAudioSourceAuthorizationResult

public enum OnlineSourceCreationResult: Sendable {
    case added(MediaSourceID)
    case verificationRequired(challengeToken: String?)
    case failed(String)
}

public typealias GoogleDriveAuthorizer = @Sendable (
    _ sourceID: MediaSourceID
) async throws -> Void

public typealias OnlineSourceCredentialRemover = @Sendable (
    _ recordID: String
) async throws -> Void

@MainActor
@Observable
public final class OnlineSourcesSceneModel {
    private struct CatalogFailureKey: Hashable {
        let sourceID: MediaSourceID
        let parentID: SourceObjectID?
        let mode: SourceCatalogBrowseMode
        let sort: SourceCatalogSort
        let query: String
        let pageToken: MediaSourceCursor?
    }

    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "online-source-scene"
    )
    public let serving: any OnlineSourceServing
    public let auditionServing: any OnlineAuditionServing
    public let settingsServing: any SettingsServing
    public let importer: (any ImportServing)?
    public let downloadQueue: OnlineDownloadQueue
    /// Release builds may intentionally omit the public Google OAuth client
    /// configuration. Existing Google Drive records remain visible, but new
    /// records and re-authorization must not pretend to be usable.
    public let isGoogleDriveOAuthConfigured: Bool
    private let authorizeDSAudioSource: DSAudioSourceAuthorizer?
    private let authorizeGoogleDrive: GoogleDriveAuthorizer?
    private let removeCredential: OnlineSourceCredentialRemover?

    public private(set) var snapshot = OnlineSourceSnapshot()
    public private(set) var auditionSnapshot = OnlineAuditionSnapshot.idle
    public private(set) var downloadSnapshots: [SourceObjectID: OnlineSourceDownloadSnapshot] = [:]
    public private(set) var importSnapshots: [SourceObjectID: OnlineSourceImportSnapshot] = [:]
    /// Kept as a source-level compatibility projection for callers that only
    /// need to know whether a source has failed recently. The UI uses the
    /// request-scoped accessor below so a child folder failure cannot leak
    /// into the root directory (or into a different search query).
    public private(set) var catalogFailureMessages: [MediaSourceID: String] = [:]
    public private(set) var lastError: String?
    /// A stable, redacted diagnostic code for the last user-visible failure.
    /// The UIKit add form can show this code without exposing credentials,
    /// endpoint paths, response bodies, or localized implementation details.
    public private(set) var lastErrorDiagnostic: String?
    public private(set) var feedbackMessage: String?
    public private(set) var feedbackSourceID: MediaSourceID?
    public private(set) var authenticationChallengeSourceID: MediaSourceID?
    public private(set) var authenticationFailureMessage: String?
    public private(set) var authenticationRetryToken = 0

    private var observationTask: Task<Void, Never>?
    private var auditionObservationTask: Task<Void, Never>?
    private var downloadQueueObservationTask: Task<Void, Never>?
    /// The UIKit route calls `start()` from both `viewDidLoad` and
    /// `viewDidAppear`. Serialize those calls so a slow settings read cannot
    /// install duplicate observers or race the privacy/authentication gates.
    private var startTask: Task<Void, Never>?
    /// UIKit can present the OTP challenge in a separate alert after the add
    /// form has already been dismissed. Keep the original request only in
    /// memory so the challenge can finish the same source creation flow.
    private var pendingDSAudioAuthorization: DSAudioSourceAuthorizationRequest?
    /// Settings persistence and the runtime coordinator publish on separate
    /// paths. Keep successful user intent ahead of a buffered/stale runtime
    /// snapshot so privacy consent is not requested again on the next render.
    private var pendingApplicationPrivacy: Bool?
    private var pendingSourcePrivacy: [MediaSourceID: Bool] = [:]
    private var pendingSourceNames: [MediaSourceID: String] = [:]
    private var pendingSourceEnabled: [MediaSourceID: Bool] = [:]
    private var pendingGlobalEnabled: Bool?
    private var catalogFailureDetails: [CatalogFailureKey: String] = [:]
    public init(
        serving: any OnlineSourceServing,
        auditionServing: any OnlineAuditionServing,
        settingsServing: any SettingsServing,
        importer: (any ImportServing)? = nil,
        downloadQueue: OnlineDownloadQueue? = nil,
        authorizeDSAudioSource: DSAudioSourceAuthorizer? = nil,
        authorizeGoogleDrive: GoogleDriveAuthorizer? = nil,
        removeCredential: OnlineSourceCredentialRemover? = nil,
        isGoogleDriveOAuthConfigured: Bool = true
    ) {
        self.serving = serving
        self.auditionServing = auditionServing
        self.settingsServing = settingsServing
        self.importer = importer
        self.downloadQueue = downloadQueue
            ?? OnlineDownloadQueue(
                onlineSources: serving,
                importer: importer
            )
        self.isGoogleDriveOAuthConfigured = isGoogleDriveOAuthConfigured
        self.authorizeDSAudioSource = authorizeDSAudioSource
        self.authorizeGoogleDrive = authorizeGoogleDrive
        self.removeCredential = removeCredential
    }

    public func start() async {
        if let startTask {
            await startTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.snapshot = await self.serving.snapshot()
            await self.reconcileSnapshotWithPersistedPreferences()
            self.observeDownloadQueueIfNeeded()
            self.applyDownloadQueueSnapshot(self.downloadQueue.snapshot)
            guard self.observationTask == nil else { return }

            let stream = await self.serving.makeSnapshotStream()
            self.observationTask = Task { @MainActor [weak self] in
                for await nextSnapshot in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.applySnapshot(nextSnapshot)
                }
            }

            let auditionStream = self.auditionServing.makeSnapshotStream()
            self.auditionObservationTask = Task { @MainActor [weak self] in
                for await snapshot in auditionStream {
                    guard !Task.isCancelled, let self else { return }
                    self.auditionSnapshot = snapshot
                }
            }
        }
        startTask = task
        await task.value
        startTask = nil
    }

    /// Refreshes the source gate from durable settings after returning from
    /// the Settings tab. SettingsViewModel serializes writes in its own
    /// worker, while OnlineSourceCoordinator publishes the runtime snapshot
    /// on a separate stream. Keeping this refresh explicit prevents the
    /// source detail from briefly falling back to an older disabled snapshot
    /// during that handoff.
    public func refreshPersistedState() async {
        await reconcileSnapshotWithPersistedPreferences()
    }

    /// The runtime coordinator normally publishes settings changes quickly,
    /// but a newly created UIKit route can observe its buffered snapshot before
    /// that publication arrives. Reconcile the durable settings once at route
    /// start so a previously accepted source policy is not shown again merely
    /// because the user left and re-entered the source list.
    private func reconcileSnapshotWithPersistedPreferences() async {
        guard let settings = try? await settingsServing.load() else { return }
        let onlinePreferences = settings.importPreferences.onlineSourcePreferences
        let applicationPrivacyAccepted = settings.importPreferences
            .privacyPreferences.isPrivacyPolicyAccepted

        // The settings store and the runtime coordinator do not share a
        // transaction. If SettingsViewModel just committed a toggle, the
        // coordinator can still publish its previous value for one turn. Keep
        // the durable value as a pending projection until the runtime stream
        // catches up instead of allowing that stale value to overwrite the
        // user's successful edit.
        let runtimeSnapshot = await serving.snapshot()
        if pendingGlobalEnabled == nil,
           runtimeSnapshot.isGloballyEnabled != onlinePreferences.isEnabled {
            pendingGlobalEnabled = onlinePreferences.isEnabled
        }
        if pendingApplicationPrivacy == nil,
           runtimeSnapshot.isApplicationPrivacyAccepted != applicationPrivacyAccepted {
            pendingApplicationPrivacy = applicationPrivacyAccepted
        }

        let runtimeSources = Dictionary(
            uniqueKeysWithValues: runtimeSnapshot.sources.map { ($0.sourceID, $0) }
        )
        for configuration in onlinePreferences.sources {
            guard let summary = runtimeSources[configuration.sourceID] else { continue }
            if summary.displayName != configuration.displayName {
                pendingSourceNames[configuration.sourceID] = configuration.displayName
            }
            if pendingSourceEnabled[configuration.sourceID] == nil,
               summary.isEnabled != configuration.isEnabled {
                pendingSourceEnabled[configuration.sourceID] = configuration.isEnabled
            }
            let accepted = configuration.isPrivacyPolicyAccepted(
                currentVersion: summary.privacyPolicyVersion
            )
            if pendingSourcePrivacy[configuration.sourceID] == nil,
               summary.isPrivacyAccepted != accepted {
                pendingSourcePrivacy[configuration.sourceID] = accepted
            }
        }

        snapshot = projectSnapshot(runtimeSnapshot)
    }

    public func clearError() {
        lastError = nil
        lastErrorDiagnostic = nil
    }

    /// Returns the failure for one visible catalog request. Failures are
    /// scoped by source, directory, search query and pagination cursor. A
    /// missing cursor means the first page, not "the latest failure from this
    /// directory"; otherwise a failed load-more request can leak into a later
    /// refresh of the same directory.
    public func catalogFailureMessage(
        for sourceID: MediaSourceID,
        parentID: SourceObjectID? = nil,
        mode: SourceCatalogBrowseMode = .folders,
        sort: SourceCatalogSort = .standard,
        query: String = "",
        pageToken: MediaSourceCursor? = nil
    ) -> String? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogFailureDetails[CatalogFailureKey(
            sourceID: sourceID,
            parentID: parentID,
            mode: mode,
            sort: sort,
            query: normalizedQuery,
            pageToken: pageToken
        )]
    }

    public func cancelAuthenticationChallenge() {
        authenticationChallengeSourceID = nil
        authenticationFailureMessage = nil
        pendingDSAudioAuthorization = nil
    }

    public func authenticateWithOneTimeCode(
        sourceID: MediaSourceID,
        code: String
    ) async -> Bool {
        if let pendingDSAudioAuthorization,
           pendingDSAudioAuthorization.sourceID == sourceID {
            return await completePendingDSAudioAuthorization(
                pendingDSAudioAuthorization,
                code: code
            )
        }

        do {
            try await serving.authenticate(sourceID: sourceID, oneTimeCode: code)
            authenticationChallengeSourceID = nil
            authenticationFailureMessage = nil
            authenticationRetryToken += 1
            setFeedback(L("二次验证成功"), sourceID: sourceID)
            lastError = nil
            lastErrorDiagnostic = nil
            return true
        } catch {
            if let authenticationError = error as? OnlineSourceAuthenticationError {
                presentAuthenticationChallenge(
                    for: sourceID,
                    error: authenticationError
                )
            } else {
                authenticationFailureMessage = Self.userFacingMessage(for: error)
                lastError = authenticationFailureMessage
                lastErrorDiagnostic = Self.diagnosticCode(for: error)
            }
            Self.logger.error(
                "one-time-code authentication failed source=\(sourceID.rawValue) diagnostic=\(Self.diagnosticCode(for: error))"
            )
            return false
        }
    }

    @discardableResult
    public func acceptApplicationPrivacy() async -> Bool {
        let succeeded = await run { [settingsServing] in
            try await settingsServing.acceptApplicationPrivacyForOnlineSources()
        }
        if succeeded {
            pendingApplicationPrivacy = true
            applyOptimisticSnapshot(applicationPrivacyAccepted: true)
        }
        return succeeded
    }

    public func addSource(
        sourceID: MediaSourceID,
        deviceName: String,
        providerKind: OnlineProviderKind,
        displayName: String,
        endpointText: String,
        account: String = "",
        password: String = "",
        oneTimeCode: String? = nil,
        challengeToken: String? = nil
    ) async -> OnlineSourceCreationResult {
        guard snapshot.isApplicationPrivacyAccepted else {
            let message = OnlineSourceServingError.applicationPrivacyRequired.description
            lastError = message
            lastErrorDiagnostic = "application_privacy_required"
            return .failed(message)
        }

        guard providerKind != .googleDrive || isGoogleDriveOAuthConfigured else {
            let message = L("Google Drive OAuth 尚未配置")
            lastError = message
            lastErrorDiagnostic = "google_drive_oauth_unconfigured"
            return .failed(message)
        }

        do {
            let normalizedEndpoint = endpointText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let endpoint: URL?
            if normalizedEndpoint.isEmpty {
                endpoint = nil
            } else if let value = URL(string: normalizedEndpoint) {
                endpoint = value
            } else {
                throw OnlineSourceConfigurationError.invalidEndpoint
            }

            if providerKind == .dsAudio {
                guard let endpoint, let authorizeDSAudioSource else {
                    throw OnlineSourceServingError.sourceUnavailable(sourceID)
                }
                let authorizationRequest = DSAudioSourceAuthorizationRequest(
                    sourceID: sourceID,
                    endpoint: endpoint,
                    displayName: displayName,
                    account: account,
                    password: password,
                    deviceName: deviceName,
                    oneTimeCode: oneTimeCode,
                    challengeToken: challengeToken
                )
                Self.logger.info(
                    "add source authorization begin source=\(sourceID.rawValue) provider=\(providerKind.rawValue) hasOneTimeCode=\(Self.hasValue(oneTimeCode))"
                )
                let result = try await authorizeDSAudioSource(authorizationRequest)
                switch result {
                case .authorized:
                    break
                case let .verificationRequired(token):
                    // A normal two-factor DSM account succeeds on this same
                    // request when the inline OTP is correct. If DSM still
                    // returns a challenge after an OTP was sent, do not
                    // duplicate the request: retain the form state and let
                    // the user correct the code in place.
                    guard let normalizedCode = Self.normalized(oneTimeCode) else {
                        pendingDSAudioAuthorization = DSAudioSourceAuthorizationRequest(
                            sourceID: sourceID,
                            endpoint: endpoint,
                            displayName: displayName,
                            account: account,
                            password: password,
                            deviceName: deviceName,
                            challengeToken: token
                        )
                        authenticationChallengeSourceID = sourceID
                        authenticationFailureMessage = nil
                        lastError = nil
                        return .verificationRequired(challengeToken: token)
                    }

                    pendingDSAudioAuthorization = DSAudioSourceAuthorizationRequest(
                        sourceID: sourceID,
                        endpoint: endpoint,
                        displayName: displayName,
                        account: account,
                        password: password,
                        deviceName: deviceName,
                        oneTimeCode: normalizedCode,
                        challengeToken: token
                    )
                    authenticationChallengeSourceID = sourceID
                    authenticationFailureMessage = L("验证码不正确或已过期，请重新输入后再次提交。")
                    lastError = authenticationFailureMessage
                    lastErrorDiagnostic = "invalid_one_time_code"
                    Self.logger.error(
                        "add source authorization rejected after inline OTP source=\(sourceID.rawValue)"
                    )
                    return .verificationRequired(challengeToken: token)
                }
            }
            try await persistSourceConfiguration(
                sourceID: sourceID,
                providerKind: providerKind,
                displayName: displayName,
                endpoint: endpoint
            )
            pendingDSAudioAuthorization = nil
            authenticationChallengeSourceID = nil
            authenticationFailureMessage = nil
            lastError = nil
            lastErrorDiagnostic = nil
            setFeedback(
                providerKind == .dsAudio
                    ? L("群晖设备授权成功")
                    : L("在线源已添加")
            )
            return .added(sourceID)
        } catch {
            let message = Self.userFacingMessage(for: error)
            Self.logger.error(
                "add source failed source=\(sourceID.rawValue) provider=\(providerKind.rawValue) diagnostic=\(Self.diagnosticCode(for: error))"
            )
            lastError = message
            lastErrorDiagnostic = Self.diagnosticCode(for: error)
            return .failed(message)
        }
    }

    private func completePendingDSAudioAuthorization(
        _ request: DSAudioSourceAuthorizationRequest,
        code: String
    ) async -> Bool {
        guard let authorizeDSAudioSource else {
            setError(OnlineSourceServingError.sourceUnavailable(request.sourceID))
            return false
        }

        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else {
            authenticationFailureMessage = L("请输入验证码。")
            authenticationChallengeSourceID = request.sourceID
            lastError = authenticationFailureMessage
            lastErrorDiagnostic = "one_time_code_required"
            return false
        }

        do {
            let result = try await authorizeDSAudioSource(
                DSAudioSourceAuthorizationRequest(
                    sourceID: request.sourceID,
                    endpoint: request.endpoint,
                    displayName: request.displayName,
                    account: request.account,
                    password: request.password,
                    deviceName: request.deviceName,
                    oneTimeCode: normalizedCode,
                    challengeToken: request.challengeToken
                )
            )
            switch result {
            case .authorized:
                try await persistSourceConfiguration(
                    sourceID: request.sourceID,
                    providerKind: .dsAudio,
                    displayName: request.displayName,
                    endpoint: request.endpoint
                )
                pendingDSAudioAuthorization = nil
                authenticationChallengeSourceID = nil
                authenticationFailureMessage = nil
                authenticationRetryToken += 1
                lastError = nil
                lastErrorDiagnostic = nil
                setFeedback(L("群晖设备授权成功"), sourceID: request.sourceID)
                return true
            case let .verificationRequired(token):
                pendingDSAudioAuthorization = DSAudioSourceAuthorizationRequest(
                    sourceID: request.sourceID,
                    endpoint: request.endpoint,
                    displayName: request.displayName,
                    account: request.account,
                    password: request.password,
                    deviceName: request.deviceName,
                    challengeToken: token
                )
                authenticationChallengeSourceID = request.sourceID
                authenticationFailureMessage = L("验证码不正确或已过期，请重新输入。")
                lastError = authenticationFailureMessage
                lastErrorDiagnostic = "invalid_one_time_code"
                return false
            }
        } catch let authenticationError as OnlineSourceAuthenticationError {
            pendingDSAudioAuthorization = request
            authenticationChallengeSourceID = request.sourceID
            authenticationFailureMessage = authenticationError == .invalidOneTimeCode
                ? L("验证码不正确或已过期，请重新输入。")
                : nil
            lastError = authenticationFailureMessage
            lastErrorDiagnostic = Self.diagnosticCode(for: authenticationError)
            Self.logger.error(
                "pending one-time-code authentication failed source=\(request.sourceID.rawValue) diagnostic=\(Self.diagnosticCode(for: authenticationError))"
            )
            return false
        } catch {
            lastError = Self.userFacingMessage(for: error)
            lastErrorDiagnostic = Self.diagnosticCode(for: error)
            Self.logger.error(
                "pending source authorization failed source=\(request.sourceID.rawValue) diagnostic=\(Self.diagnosticCode(for: error))"
            )
            return false
        }
    }

    private func persistSourceConfiguration(
        sourceID: MediaSourceID,
        providerKind: OnlineProviderKind,
        displayName: String,
        endpoint: URL?
    ) async throws {
        let configuration = try OnlineSourceConfiguration(
            sourceID: sourceID,
            providerKind: providerKind,
            displayName: displayName,
            endpoint: endpoint,
            credentialRecordID: sourceID.rawValue,
            isEnabled: true
        )
        let current = try await settingsServing.load()
        let preferences = try current.importPreferences.onlineSourcePreferences
            .adding(configuration)
        try await settingsServing.updateOnlineSourcePreferences(preferences)
        applyOptimisticSnapshot(
            adding: OnlineSourceSummary(
                sourceID: sourceID,
                providerKind: providerKind,
                displayName: displayName,
                privacyPolicyVersion: providerKind.defaultPrivacyPolicyVersion,
                isRegistered: false,
                isPrivacyAccepted: false,
                isEnabled: true,
                isRuntimeEnabled: false
            )
        )
    }

    public func setGlobalEnabled(_ isEnabled: Bool) async {
        guard !isEnabled || snapshot.isApplicationPrivacyAccepted else {
            setError(OnlineSourceServingError.applicationPrivacyRequired)
            return
        }
        if !isEnabled {
            await downloadQueue.stop()
            await stopOnlineOperations()
        }
        let succeeded = await run { [settingsServing] in
            try await settingsServing.setOnlineSourcesEnabled(isEnabled)
        }
        if succeeded {
            pendingGlobalEnabled = isEnabled
            applyOptimisticSnapshot(globalEnabled: isEnabled)
        }
    }

    @discardableResult
    public func renameSource(_ sourceID: MediaSourceID, to displayName: String) async -> Bool {
        do {
            let current = try await settingsServing.load()
            let preferences = current.importPreferences.onlineSourcePreferences
            guard let configuration = preferences.source(for: sourceID) else {
                throw OnlineSourcePreferencesError.sourceNotFound(sourceID)
            }
            let renamed = try configuration.renaming(to: displayName)
            try await settingsServing.updateOnlineSourcePreferences(preferences.updating(renamed))
            pendingSourceNames[sourceID] = renamed.displayName
            snapshot = projectSnapshot(snapshot)
            clearError()
            return true
        } catch {
            setError(error)
            return false
        }
    }

    public func setSourceEnabled(
        _ sourceID: MediaSourceID,
        isEnabled: Bool
    ) async {
        guard let summary = snapshot.sources.first(where: { $0.sourceID == sourceID }) else {
            setError(OnlineSourceServingError.sourceNotConfigured(sourceID))
            return
        }
        guard !isEnabled || (
            snapshot.isApplicationPrivacyAccepted
                && summary.isPrivacyAccepted
        ) else {
            setError(OnlineSourceServingError.sourcePrivacyRequired(sourceID))
            return
        }
        if !isEnabled {
            await downloadQueue.stop(for: sourceID)
            await stopOnlineOperations(for: sourceID)
        }
        let succeeded = await run { [settingsServing] in
            let current = try await settingsServing.load()
            let preferences = try current.importPreferences.onlineSourcePreferences
                .settingSourceEnabled(sourceID, enabled: isEnabled)
            try await settingsServing.updateOnlineSourcePreferences(preferences)
        }
        if succeeded {
            pendingSourceEnabled[sourceID] = isEnabled
            applyOptimisticSnapshot(sourceID: sourceID, sourceEnabled: isEnabled)
        }
    }

    @discardableResult
    public func acceptSourcePrivacy(_ sourceID: MediaSourceID) async -> Bool {
        guard let summary = snapshot.sources.first(where: { $0.sourceID == sourceID }) else {
            setError(OnlineSourceServingError.sourceNotConfigured(sourceID))
            return false
        }
        let succeeded = await run { [settingsServing] in
            try await settingsServing.acceptOnlineSourcePrivacy(
                sourceID,
                policyVersion: summary.privacyPolicyVersion
            )
        }
        if succeeded {
            pendingSourcePrivacy[sourceID] = true
            applyOptimisticSnapshot(sourceID: sourceID, privacyAccepted: true)
        }
        return succeeded
    }

    public func revokeSourcePrivacy(_ sourceID: MediaSourceID) async {
        await stopOnlineOperations(for: sourceID)
        let succeeded = await run { [settingsServing] in
            try await settingsServing.revokeOnlineSourcePrivacy(sourceID)
        }
        if succeeded {
            pendingSourcePrivacy[sourceID] = false
            pendingSourceEnabled[sourceID] = false
            applyOptimisticSnapshot(
                sourceID: sourceID,
                privacyAccepted: false,
                sourceEnabled: false
            )
        }
    }

    @discardableResult
    public func removeSource(_ sourceID: MediaSourceID) async -> Bool {
        await downloadQueue.stop(for: sourceID)
        await stopOnlineOperations(for: sourceID)
        do {
            let current = try await settingsServing.load()
            guard let configuration = current.importPreferences
                .onlineSourcePreferences.source(for: sourceID)
            else {
                throw OnlineSourcePreferencesError.sourceNotFound(sourceID)
            }

            let preferences = current.importPreferences.onlineSourcePreferences
                .removing(sourceID)
            try await settingsServing.updateOnlineSourcePreferences(preferences)

            snapshot = OnlineSourceSnapshot(
                isGloballyEnabled: snapshot.isGloballyEnabled,
                isApplicationPrivacyAccepted: snapshot.isApplicationPrivacyAccepted,
                sources: snapshot.sources.filter { $0.sourceID != sourceID }
            )
            pendingSourcePrivacy.removeValue(forKey: sourceID)
            pendingSourceNames.removeValue(forKey: sourceID)
            pendingSourceEnabled.removeValue(forKey: sourceID)

            downloadQueue.discardSnapshots(for: sourceID)
            downloadSnapshots = downloadSnapshots.filter { $0.key.sourceID != sourceID }
            importSnapshots = importSnapshots.filter { $0.key.sourceID != sourceID }
            catalogFailureDetails = catalogFailureDetails.filter {
                $0.key.sourceID != sourceID
            }
            catalogFailureMessages.removeValue(forKey: sourceID)

            authenticationChallengeSourceID = nil
            authenticationFailureMessage = nil
            feedbackMessage = L("在线源已删除")
            lastError = nil

            if let recordID = configuration.credentialRecordID,
               let removeCredential {
                do {
                    try await removeCredential(recordID)
                } catch {
                    lastError = L("来源已删除，但系统凭据清理失败：%@", Self.userFacingMessage(for: error))
                    lastErrorDiagnostic = "credential_cleanup_failed_\(Self.diagnosticCode(for: error))"
                }
            }
            return true
        } catch {
            setError(error)
            return false
        }
    }

    public func authorizeGoogleDrive(for sourceID: MediaSourceID) async {
        guard snapshot.isApplicationPrivacyAccepted else {
            setError(OnlineSourceServingError.applicationPrivacyRequired)
            return
        }
        guard let summary = snapshot.sources.first(where: { $0.sourceID == sourceID }) else {
            setError(OnlineSourceServingError.sourceNotConfigured(sourceID))
            return
        }
        guard summary.isPrivacyAccepted else {
            setError(OnlineSourceServingError.sourcePrivacyRequired(sourceID))
            return
        }
        guard snapshot.isGloballyEnabled, summary.isEnabled else {
            setError(OnlineSourceServingError.sourceDisabled(sourceID))
            return
        }
        guard isGoogleDriveOAuthConfigured else {
            setError(message: L("Google Drive OAuth 尚未配置"), diagnostic: "google_drive_oauth_unconfigured")
            return
        }
        guard let authorizeGoogleDrive else {
            setError(message: L("Google Drive OAuth 尚未配置"), diagnostic: "google_drive_authorizer_missing")
            return
        }
        do {
            try await authorizeGoogleDrive(sourceID)
            setFeedback(L("Google Drive 已授权"), sourceID: sourceID)
            lastError = nil
            lastErrorDiagnostic = nil
        } catch {
            setError(error)
        }
    }

    public func loadCatalog(
        for sourceID: MediaSourceID,
        parentID: SourceObjectID? = nil,
        mode: SourceCatalogBrowseMode = .folders,
        sort: SourceCatalogSort = .standard
    ) async -> [SourceCatalogItem] {
        await loadCatalogPage(
            for: sourceID,
            parentID: parentID,
            mode: mode,
            sort: sort
        )?.items ?? []
    }

    public func loadCatalogPage(
        for sourceID: MediaSourceID,
        parentID: SourceObjectID? = nil,
        mode: SourceCatalogBrowseMode = .folders,
        sort: SourceCatalogSort = .standard,
        pageToken: MediaSourceCursor? = nil
    ) async -> SourceCatalogPage? {
        let failureKey = CatalogFailureKey(
            sourceID: sourceID,
            parentID: parentID,
            mode: mode,
            sort: sort,
            query: "",
            pageToken: pageToken
        )
        clearCatalogFailure(for: failureKey)
        Self.logger.info(
            "catalog load begin source=\(sourceID.rawValue) mode=\(mode.rawValue) sort=\(sort.key.rawValue):\(sort.direction.rawValue) parent=\(parentID?.externalID ?? "root") page=\(pageToken?.rawValue ?? "first")"
        )
        do {
            let page = try await serving.browse(
                sourceID: sourceID,
                request: SourceBrowseRequest(
                    parentID: parentID,
                    mode: mode,
                    sort: sort,
                    pageToken: pageToken
                )
            )
            lastError = nil
            if pageToken == nil {
                clearCatalogFailures(
                    forSource: sourceID,
                    parentID: parentID,
                    mode: mode,
                    sort: sort,
                    query: ""
                )
            }
            lastErrorDiagnostic = nil
            Self.logger.info(
                "catalog load completed source=\(sourceID.rawValue) mode=\(mode.rawValue) items=\(page.items.count) next=\(page.nextPageToken?.rawValue ?? "none")"
            )
            return page
        } catch {
            let message = Self.userFacingMessage(for: error)
            recordCatalogFailure(message, for: failureKey)
            lastErrorDiagnostic = Self.diagnosticCode(for: error)
            Self.logger.error(
                "catalog load failed source=\(sourceID.rawValue) mode=\(mode.rawValue) parent=\(parentID?.externalID ?? "root") page=\(pageToken?.rawValue ?? "first") diagnostic=\(Self.diagnosticCode(for: error))"
            )
            if !handleAuthenticationChallenge(error, sourceID: sourceID) {
                // A load-more failure is rendered in the catalog footer and
                // must not later surface as an unrelated modal error after
                // the user leaves the directory. The first page remains
                // eligible for the normal route-level error presentation.
                lastError = pageToken == nil ? message : nil
            }
            return nil
        }
    }

    public func searchCatalog(
        for sourceID: MediaSourceID,
        query: String,
        parentID: SourceObjectID? = nil,
        mode: SourceCatalogBrowseMode = .folders,
        sort: SourceCatalogSort = .standard
    ) async -> [SourceCatalogItem] {
        await searchCatalogPage(
            for: sourceID,
            query: query,
            parentID: parentID,
            mode: mode,
            sort: sort
        )?.items ?? []
    }

    public func searchCatalogPage(
        for sourceID: MediaSourceID,
        query: String,
        parentID: SourceObjectID? = nil,
        mode: SourceCatalogBrowseMode = .folders,
        sort: SourceCatalogSort = .standard,
        pageToken: MediaSourceCursor? = nil
    ) async -> SourceCatalogPage? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let failureKey = CatalogFailureKey(
            sourceID: sourceID,
            parentID: parentID,
            mode: mode,
            sort: sort,
            query: normalizedQuery,
            pageToken: pageToken
        )
        clearCatalogFailure(for: failureKey)
        Self.logger.info(
            "catalog search begin source=\(sourceID.rawValue) mode=\(mode.rawValue) sort=\(sort.key.rawValue):\(sort.direction.rawValue) parent=\(parentID?.externalID ?? "root") page=\(pageToken?.rawValue ?? "first") queryLength=\(normalizedQuery.count)"
        )
        do {
            let page = try await serving.search(
                sourceID: sourceID,
                request: SourceSearchRequest(
                    query: normalizedQuery,
                    parentID: parentID,
                    mode: mode,
                    sort: sort,
                    pageToken: pageToken
                )
            )
            lastError = nil
            if pageToken == nil {
                clearCatalogFailures(
                    forSource: sourceID,
                    parentID: parentID,
                    mode: mode,
                    sort: sort,
                    query: normalizedQuery
                )
            }
            lastErrorDiagnostic = nil
            Self.logger.info(
                "catalog search completed source=\(sourceID.rawValue) mode=\(mode.rawValue) items=\(page.items.count) next=\(page.nextPageToken?.rawValue ?? "none")"
            )
            return page
        } catch {
            let message = Self.userFacingMessage(for: error)
            recordCatalogFailure(message, for: failureKey)
            lastErrorDiagnostic = Self.diagnosticCode(for: error)
            Self.logger.error(
                "catalog search failed source=\(sourceID.rawValue) mode=\(mode.rawValue) parent=\(parentID?.externalID ?? "root") page=\(pageToken?.rawValue ?? "first") diagnostic=\(Self.diagnosticCode(for: error))"
            )
            if !handleAuthenticationChallenge(error, sourceID: sourceID) {
                lastError = pageToken == nil ? message : nil
            }
            return nil
        }
    }

    private func recordCatalogFailure(
        _ message: String,
        for key: CatalogFailureKey
    ) {
        catalogFailureDetails[key] = message
        catalogFailureMessages[key.sourceID] = message
    }

    private func clearCatalogFailure(for key: CatalogFailureKey) {
        catalogFailureDetails.removeValue(forKey: key)
        rebuildCatalogFailureProjection(for: key.sourceID)
    }

    private func clearCatalogFailures(
        forSource sourceID: MediaSourceID,
        parentID: SourceObjectID?,
        mode: SourceCatalogBrowseMode,
        sort: SourceCatalogSort,
        query: String
    ) {
        catalogFailureDetails = catalogFailureDetails.filter {
            !(
                    $0.key.sourceID == sourceID
                        && $0.key.parentID == parentID
                        && $0.key.mode == mode
                        && $0.key.sort == sort
                        && $0.key.query == query
            )
        }
        rebuildCatalogFailureProjection(for: sourceID)
    }

    private func rebuildCatalogFailureProjection(for sourceID: MediaSourceID) {
        guard let remaining = catalogFailureDetails
            .filter({ $0.key.sourceID == sourceID })
            .sorted(by: { lhs, rhs in
                (lhs.key.pageToken?.rawValue ?? "")
                    < (rhs.key.pageToken?.rawValue ?? "")
            })
            .last
        else {
            catalogFailureMessages.removeValue(forKey: sourceID)
            return
        }
        catalogFailureMessages[sourceID] = remaining.value
    }

    public func audition(
        sourceID: MediaSourceID,
        item: SourceCatalogItem
    ) async {
        guard let summary = snapshot.sources.first(where: { $0.sourceID == sourceID }) else {
            setError(OnlineSourceServingError.sourceNotConfigured(sourceID))
            return
        }
        guard summary.capabilities.contains(.onlinePlayback) else {
            setError(OnlineSourceServingError.operationUnsupported(
                sourceID,
                "online audition"
            ))
            return
        }
        do {
            try await auditionServing.audition(
                sourceID: sourceID,
                item: item
            )
            auditionSnapshot = auditionServing.snapshot
            setFeedback(
                L("正在临时试听，不会加入播放队列或历史"),
                sourceID: sourceID
            )
            lastError = nil
            lastErrorDiagnostic = nil
        } catch {
            auditionSnapshot = auditionServing.snapshot
            if !handleAuthenticationChallenge(error, sourceID: sourceID) {
                setError(error)
            }
        }
    }

    /// Starts audition using the current catalog order so next/previous and
    /// the queue sheet operate on the same visible result set.
    public func startAudition(
        sourceID: MediaSourceID,
        items: [SourceCatalogItem],
        startingItemID: SourceObjectID
    ) async {
        guard let summary = snapshot.sources.first(where: { $0.sourceID == sourceID }),
              summary.capabilities.contains(.onlinePlayback)
        else { return }
        do {
            try await auditionServing.start(
                sourceID: sourceID,
                items: items.filter(\.isPlayable),
                startingItemID: startingItemID
            )
            auditionSnapshot = auditionServing.snapshot
            setFeedback(L("正在临时试听，不会加入播放队列或历史"), sourceID: sourceID)
            lastError = nil
            lastErrorDiagnostic = nil
        } catch {
            auditionSnapshot = auditionServing.snapshot
            if !handleAuthenticationChallenge(error, sourceID: sourceID) { setError(error) }
        }
    }

    public func pauseAudition() async {
        await auditionServing.pause()
        auditionSnapshot = auditionServing.snapshot
    }

    public func resumeAudition() async {
        do {
            try await auditionServing.resume()
            auditionSnapshot = auditionServing.snapshot
            lastError = nil
            lastErrorDiagnostic = nil
        } catch {
            auditionSnapshot = auditionServing.snapshot
            if let sourceID = auditionSnapshot.sourceID {
                if !handleAuthenticationChallenge(error, sourceID: sourceID) {
                    setError(error)
                }
            } else {
                setError(error)
            }
        }
    }

    public func retryAudition() async {
        do {
            try await auditionServing.retry()
            auditionSnapshot = auditionServing.snapshot
            lastError = nil
            lastErrorDiagnostic = nil
        } catch {
            auditionSnapshot = auditionServing.snapshot
            if let sourceID = auditionSnapshot.sourceID {
                if !handleAuthenticationChallenge(error, sourceID: sourceID) {
                    setError(error)
                }
            } else {
                setError(error)
            }
        }
    }

    public func stopAudition() async {
        let sourceID = auditionSnapshot.sourceID
        await auditionServing.stop()
        auditionSnapshot = auditionServing.snapshot
        setFeedback(L("试听已停止"), sourceID: sourceID)
    }

    public func stopAudition(for sourceID: MediaSourceID) async {
        guard auditionSnapshot.sourceID == sourceID,
              auditionSnapshot.hasRetainedSession
        else {
            return
        }
        await stopAudition()
    }

    public func startDownload(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        displayName: String,
        metadataHint: MediaImportMetadataHint? = nil
    ) {
        observeDownloadQueueIfNeeded()
        feedbackMessage = nil
        downloadQueue.startDownload(
            sourceID: sourceID,
            itemID: itemID,
            displayName: displayName,
            metadataHint: metadataHint
        )
    }

    /// Imports every audio object below a remote folder or album. Discovery
    /// walks the Provider catalog with pagination, while downloads use a
    /// three-item upper bound so a large NAS folder cannot retain an
    /// unbounded number of staged files. A plain audio item is routed to the
    /// existing single-item flow.
    public func startImport(
        sourceID: MediaSourceID,
        item: SourceCatalogItem
    ) {
        guard item.id.sourceID == sourceID else {
            setError(OnlineSourceServingError.sourceNotConfigured(sourceID))
            return
        }
        observeDownloadQueueIfNeeded()
        feedbackMessage = nil
        downloadQueue.startImport(sourceID: sourceID, item: item)
        applyDownloadQueueSnapshot(downloadQueue.snapshot, emitFeedback: false)
    }

    /// Starts the same recursive import flow from the Provider root. The root
    /// is not a Provider-owned catalog object, so it uses a private synthetic
    /// identity while discovery still sends `parentID: nil` to the Provider.
    public func startImportFromRoot(
        sourceID: MediaSourceID,
        displayName: String
    ) {
        observeDownloadQueueIfNeeded()
        feedbackMessage = nil
        downloadQueue.startImportFromRoot(
            sourceID: sourceID,
            displayName: displayName
        )
        applyDownloadQueueSnapshot(downloadQueue.snapshot, emitFeedback: false)
    }

    public func cancelDownload(_ itemID: SourceObjectID) async {
        await downloadQueue.cancelDownload(itemID)
        applyDownloadQueueSnapshot(downloadQueue.snapshot, emitFeedback: false)
        setFeedback(L("下载与导入已取消"), sourceID: itemID.sourceID)
    }

    public func cancelImport(_ rootItemID: SourceObjectID) async {
        await downloadQueue.cancelImport(rootItemID)
        applyDownloadQueueSnapshot(downloadQueue.snapshot, emitFeedback: false)
        setFeedback(L("下载与导入已取消"), sourceID: rootItemID.sourceID)
    }

    public func cancelAllDownloads() async {
        await downloadQueue.stop()
        applyDownloadQueueSnapshot(downloadQueue.snapshot, emitFeedback: false)
        setFeedback(L("所有在线源下载与导入已取消"), sourceID: nil)
    }

    private func observeDownloadQueueIfNeeded() {
        guard downloadQueueObservationTask == nil else { return }
        applyDownloadQueueSnapshot(downloadQueue.snapshot, emitFeedback: false)
        let stream = downloadQueue.makeSnapshotStream()
        downloadQueueObservationTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                // AsyncStream preserves every queued value, but the UI may
                // also synchronously project the queue's current snapshot
                // after an awaited cancel/start operation. Reading the
                // queue-owned latest value here prevents an older buffered
                // progress event from rolling a terminal state backwards.
                self.applyDownloadQueueSnapshot(self.downloadQueue.snapshot)
            }
        }
    }

    private func applyDownloadQueueSnapshot(
        _ nextSnapshot: OnlineDownloadQueueSnapshot,
        emitFeedback: Bool = true
    ) {
        let previousDownloads = downloadSnapshots
        let previousImports = importSnapshots
        downloadSnapshots = nextSnapshot.downloads
        importSnapshots = nextSnapshot.imports

        guard emitFeedback else { return }

        for (itemID, next) in nextSnapshot.downloads {
            guard previousDownloads[itemID]?.phase != next.phase else { continue }
            switch next.phase {
            case .completed:
                setFeedback(L("已下载并导入媒体库"), sourceID: itemID.sourceID)
            case .alreadyImported:
                setFeedback(L("媒体已存在，无需重复导入"), sourceID: itemID.sourceID)
            case .skipped:
                setFeedback(L("媒体已跳过，没有新增到资料库"), sourceID: itemID.sourceID)
            case .cancelled:
                setFeedback(L("下载与导入已取消"), sourceID: itemID.sourceID)
            case .failed:
                setFeedback(L("下载或导入失败，请重试。"), sourceID: itemID.sourceID)
            case .downloading, .importing:
                break
            }
        }

        for (rootItemID, next) in nextSnapshot.imports {
            guard previousImports[rootItemID]?.phase != next.phase else { continue }
            switch next.phase {
            case .completed:
                setFeedback(L("文件夹导入已完成"), sourceID: rootItemID.sourceID)
            case .cancelled:
                setFeedback(L("下载与导入已取消"), sourceID: rootItemID.sourceID)
            case .failed:
                setFeedback(L("目录导入失败，请重试"), sourceID: rootItemID.sourceID)
            case .discovering, .downloading, .importing:
                break
            }
        }
    }

    private func setFeedback(
        _ message: String?,
        sourceID: MediaSourceID? = nil
    ) {
        feedbackMessage = message
        feedbackSourceID = message == nil ? nil : sourceID
    }

    @discardableResult
    private func run(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await operation()
            lastError = nil
            lastErrorDiagnostic = nil
            return true
        } catch {
            lastError = Self.userFacingMessage(for: error)
            lastErrorDiagnostic = Self.diagnosticCode(for: error)
            return false
        }
    }

    private func setError(_ error: Error) {
        setError(
            message: Self.userFacingMessage(for: error),
            diagnostic: Self.diagnosticCode(for: error)
        )
    }

    private func setError(message: String, diagnostic: String) {
        lastError = message
        lastErrorDiagnostic = diagnostic
    }

    /// Settings are persisted through an actor and the AppService runtime
    /// receives the change through a separate stream. Reflect successful user
    /// intent immediately so the UI does not briefly render the old gate while
    /// waiting for that stream; the runtime snapshot will still replace this
    /// projection as soon as it arrives.
    private func applyOptimisticSnapshot(
        globalEnabled: Bool? = nil,
        applicationPrivacyAccepted: Bool? = nil,
        sourceID: MediaSourceID? = nil,
        privacyAccepted: Bool? = nil,
        sourceEnabled: Bool? = nil,
        adding: OnlineSourceSummary? = nil
    ) {
        let nextGlobalEnabled = globalEnabled ?? snapshot.isGloballyEnabled
        let nextApplicationPrivacyAccepted = applicationPrivacyAccepted
            ?? snapshot.isApplicationPrivacyAccepted
        let nextSources = snapshot.sources.map { summary in
            guard summary.sourceID == sourceID else {
                return summaryWithRuntime(
                    summary,
                    globalEnabled: nextGlobalEnabled,
                    applicationPrivacyAccepted: nextApplicationPrivacyAccepted
                )
            }
            return summaryWithRuntime(
                summary,
                globalEnabled: nextGlobalEnabled,
                applicationPrivacyAccepted: nextApplicationPrivacyAccepted,
                privacyAccepted: privacyAccepted,
                sourceEnabled: sourceEnabled
            )
        } + (adding.map { [$0] } ?? [])

        snapshot = OnlineSourceSnapshot(
            isGloballyEnabled: nextGlobalEnabled,
            isApplicationPrivacyAccepted: nextApplicationPrivacyAccepted,
            sources: nextSources
        )
    }

    private func summaryWithRuntime(
        _ summary: OnlineSourceSummary,
        globalEnabled: Bool,
        applicationPrivacyAccepted: Bool,
        privacyAccepted: Bool? = nil,
        sourceEnabled: Bool? = nil
    ) -> OnlineSourceSummary {
        let nextPrivacyAccepted = privacyAccepted ?? summary.isPrivacyAccepted
        let nextSourceEnabled = sourceEnabled ?? summary.isEnabled
        return OnlineSourceSummary(
            sourceID: summary.sourceID,
            providerKind: summary.providerKind,
            displayName: pendingSourceNames[summary.sourceID] ?? summary.displayName,
            capabilities: summary.capabilities,
            privacyPolicyVersion: summary.privacyPolicyVersion,
            isRegistered: summary.isRegistered,
            isPrivacyAccepted: nextPrivacyAccepted,
            isEnabled: nextSourceEnabled,
            isRuntimeEnabled: globalEnabled
                && applicationPrivacyAccepted
                && nextPrivacyAccepted
                && nextSourceEnabled
                && summary.isRegistered
        )
    }

    private func applySnapshot(_ nextSnapshot: OnlineSourceSnapshot) async {
        let previousSnapshot = snapshot
        if pendingGlobalEnabled == nextSnapshot.isGloballyEnabled {
            pendingGlobalEnabled = nil
        }
        if pendingApplicationPrivacy == nextSnapshot.isApplicationPrivacyAccepted {
            pendingApplicationPrivacy = nil
        }
        let sourceIDs = Set(nextSnapshot.sources.map(\.sourceID))
        pendingSourceNames = pendingSourceNames.filter { sourceIDs.contains($0.key) }
        pendingSourcePrivacy = pendingSourcePrivacy.filter { sourceIDs.contains($0.key) }
        pendingSourceEnabled = pendingSourceEnabled.filter { sourceIDs.contains($0.key) }
        for summary in nextSnapshot.sources {
            if pendingSourceNames[summary.sourceID] == summary.displayName {
                pendingSourceNames.removeValue(forKey: summary.sourceID)
            }
            if pendingSourcePrivacy[summary.sourceID] == summary.isPrivacyAccepted {
                pendingSourcePrivacy.removeValue(forKey: summary.sourceID)
            }
            if pendingSourceEnabled[summary.sourceID] == summary.isEnabled {
                pendingSourceEnabled.removeValue(forKey: summary.sourceID)
            }
        }
        let projectedSnapshot = projectSnapshot(nextSnapshot)
        snapshot = projectedSnapshot
        guard previousSnapshot != projectedSnapshot else { return }

        await downloadQueue.stopUnavailable(using: projectedSnapshot)

        if let auditionSourceID = auditionSnapshot.sourceID,
           auditionSnapshot.hasRetainedSession,
           !isRuntimeEnabled(projectedSnapshot, sourceID: auditionSourceID) {
            await auditionServing.close()
            auditionSnapshot = auditionServing.snapshot
        }
    }

    private func projectSnapshot(_ base: OnlineSourceSnapshot) -> OnlineSourceSnapshot {
        let globalEnabled = pendingGlobalEnabled ?? base.isGloballyEnabled
        let applicationPrivacyAccepted = pendingApplicationPrivacy
            ?? base.isApplicationPrivacyAccepted
        let sources = base.sources.map { summary in
            summaryWithRuntime(
                summary,
                globalEnabled: globalEnabled,
                applicationPrivacyAccepted: applicationPrivacyAccepted,
                privacyAccepted: pendingSourcePrivacy[summary.sourceID],
                sourceEnabled: pendingSourceEnabled[summary.sourceID]
            )
        }
        return OnlineSourceSnapshot(
            isGloballyEnabled: globalEnabled,
            isApplicationPrivacyAccepted: applicationPrivacyAccepted,
            sources: sources
        )
    }

    private func stopOnlineOperations(for sourceID: MediaSourceID? = nil) async {
        await downloadQueue.stop(for: sourceID)
        if let sourceID,
           auditionSnapshot.sourceID == sourceID,
           auditionSnapshot.hasRetainedSession {
            await auditionServing.close()
            auditionSnapshot = auditionServing.snapshot
        } else if sourceID == nil, auditionSnapshot.hasRetainedSession {
            await auditionServing.close()
            auditionSnapshot = auditionServing.snapshot
        }
    }

    private func isRuntimeEnabled(
        _ sourceSnapshot: OnlineSourceSnapshot,
        sourceID: MediaSourceID
    ) -> Bool {
        sourceSnapshot.sources.first { $0.sourceID == sourceID }?.isRuntimeEnabled == true
    }

    private func handleAuthenticationChallenge(
        _ error: Error,
        sourceID: MediaSourceID
    ) -> Bool {
        guard let authenticationError = error as? OnlineSourceAuthenticationError else {
            return false
        }
        presentAuthenticationChallenge(for: sourceID, error: authenticationError)
        lastError = nil
        lastErrorDiagnostic = Self.diagnosticCode(for: authenticationError)
        return true
    }

    private func presentAuthenticationChallenge(
        for sourceID: MediaSourceID,
        error: OnlineSourceAuthenticationError
    ) {
        authenticationChallengeSourceID = sourceID
        switch error {
        case .oneTimeCodeRequired:
            authenticationFailureMessage = nil
        case .invalidOneTimeCode:
            authenticationFailureMessage = L("验证码不正确或已过期，请重新输入。")
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func hasValue(_ value: String?) -> Bool {
        normalized(value) != nil
    }

    /// Keep diagnostics useful in simulator/device logs without serializing
    /// provider credentials, URLs, response bodies, or arbitrary localized
    /// error text. Known domain errors retain their stable case; NSError
    /// values retain only domain and numeric code.
    private static func diagnosticCode(for error: Error) -> String {
        if let authenticationError = error as? OnlineSourceAuthenticationError {
            switch authenticationError {
            case .oneTimeCodeRequired:
                return "one_time_code_required"
            case .invalidOneTimeCode:
                return "invalid_one_time_code"
            }
        }
        if let configurationError = error as? OnlineSourceConfigurationError {
            switch configurationError {
            case .emptyDisplayName:
                return "empty_display_name"
            case .emptyPrivacyPolicyVersion:
                return "empty_privacy_policy_version"
            case .invalidEndpoint:
                return "invalid_endpoint"
            case .endpointContainsSensitiveComponents:
                return "endpoint_contains_sensitive_components"
            }
        }
        if let servingError = error as? OnlineSourceServingError {
            switch servingError {
            case .applicationPrivacyRequired:
                return "application_privacy_required"
            case .sourceNotConfigured:
                return "source_not_configured"
            case .sourcePrivacyRequired:
                return "source_privacy_required"
            case .sourceDisabled:
                return "source_disabled"
            case .sourceUnavailable:
                return "source_unavailable"
            case .operationUnsupported:
                return "operation_unsupported"
            }
        }
        if let urlError = error as? URLError {
            return "url_\(urlError.code.rawValue)"
        }
        let nsError = error as NSError
        if !nsError.domain.isEmpty {
            return "NSError(\(nsError.domain):\(nsError.code))"
        }
        return String(describing: type(of: error))
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let authenticationError = error as? OnlineSourceAuthenticationError {
            switch authenticationError {
            case .oneTimeCodeRequired:
                return L("DSM 要求输入一次性验证码。")
            case .invalidOneTimeCode:
                return L("验证码不正确或已过期，请重新输入。")
            }
        }

        if let configurationError = error as? OnlineSourceConfigurationError {
            switch configurationError {
            case .emptyDisplayName:
                return L("请输入在线源名称。")
            case .emptyPrivacyPolicyVersion:
                return L("在线源隐私协议版本无效。")
            case .invalidEndpoint:
                return L("请输入有效的 HTTP 或 HTTPS 地址。")
            case .endpointContainsSensitiveComponents:
                return L("地址不能包含账号、密码、查询参数或片段。")
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                return L("DS Audio 地址无效，请检查地址格式。")
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet:
                return L("无法连接 DSM，请检查网络和 DS Audio 地址。")
            case .timedOut:
                return L("连接 DSM 超时，请检查网络后重试。")
            default:
                break
            }
        }

        let description = (error as? LocalizedError)?.errorDescription
            ?? L("在线源操作失败，请查看日志后重试。")
        if let servingError = error as? OnlineSourceServingError {
            switch servingError {
            case .applicationPrivacyRequired:
                return L("请先同意应用隐私协议。")
            case .sourceNotConfigured:
                return L("在线源配置不存在，请重新添加。")
            case .sourcePrivacyRequired:
                return L("请先同意此在线源的隐私协议。")
            case .sourceDisabled:
                return L("此在线源已停用，请在设置中重新启用。")
            case .sourceUnavailable:
                return L("当前版本暂不支持此在线源。")
            case let .operationUnsupported(_, operation):
                return L("此在线源暂不支持：%@。", operation)
            }
        }
        return description.isEmpty ? L("在线源操作失败，请查看日志后重试。") : description
    }
}
