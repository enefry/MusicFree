import Foundation
import DesignSystem
import Observation

public struct SettingsAppIconOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let alternateIconName: String?
    public let previewAssetName: String

    public init(
        id: String,
        title: String,
        alternateIconName: String?,
        previewAssetName: String
    ) {
        self.id = id
        self.title = title
        self.alternateIconName = alternateIconName
        self.previewAssetName = previewAssetName
    }
}

@MainActor
public protocol SettingsAppIconProviding: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }

    func setAlternateIconName(_ alternateIconName: String?) async throws
}

@MainActor
public final class EmptySettingsAppIconProvider: SettingsAppIconProviding {
    public init() {}

    public var supportsAlternateIcons: Bool { false }
    public var alternateIconName: String? { nil }

    public func setAlternateIconName(_: String?) async throws {
        throw SettingsAppIconError.unsupported
    }
}

private enum SettingsAppIconError: Error {
    case unsupported
}

@MainActor
@Observable
final class AppIconSettingsViewModel {
    private let provider: any SettingsAppIconProviding

    private(set) var selectedAlternateIconName: String?
    private(set) var changingAlternateIconName: String?
    private(set) var isChangingToPrimaryIcon = false
    private(set) var failureMessage: String?

    init(provider: any SettingsAppIconProviding) {
        self.provider = provider
        selectedAlternateIconName = provider.alternateIconName
    }

    var supportsAlternateIcons: Bool {
        provider.supportsAlternateIcons
    }

    func refreshSelection() {
        selectedAlternateIconName = provider.alternateIconName
    }

    func isSelected(_ option: SettingsAppIconOption) -> Bool {
        option.alternateIconName == selectedAlternateIconName
    }

    func isChanging(_ option: SettingsAppIconOption) -> Bool {
        if let alternateIconName = option.alternateIconName {
            return changingAlternateIconName == alternateIconName
        }
        return isChangingToPrimaryIcon
    }

    func select(_ option: SettingsAppIconOption) async {
        guard supportsAlternateIcons,
              changingAlternateIconName == nil,
              !isChangingToPrimaryIcon,
              !isSelected(option)
        else {
            return
        }

        failureMessage = nil
        changingAlternateIconName = option.alternateIconName
        isChangingToPrimaryIcon = option.alternateIconName == nil
        defer {
            changingAlternateIconName = nil
            isChangingToPrimaryIcon = false
        }

        do {
            try await provider.setAlternateIconName(option.alternateIconName)
            selectedAlternateIconName = provider.alternateIconName
        } catch is CancellationError {
            refreshSelection()
        } catch {
            refreshSelection()
            failureMessage = L("无法切换应用图标。")
        }
    }
}
