import DesignSystem
import Observation
import SwiftUI

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

struct AppIconSettingsView: View {
    let options: [SettingsAppIconOption]
    @State private var viewModel: AppIconSettingsViewModel

    @MainActor
    init(
        options: [SettingsAppIconOption],
        provider: any SettingsAppIconProviding
    ) {
        self.options = options
        _viewModel = State(initialValue: AppIconSettingsViewModel(provider: provider))
    }

    var body: some View {
//        Section(L("应用图标")) {
        VStack(alignment: .leading) {
            Text(L("应用图标"))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 16)],
                spacing: 16
            ) {
                ForEach(options) { option in
                    iconButton(option)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            if let failureMessage = viewModel.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.warning)
                    .accessibilityIdentifier("settings.appIcon.error")
            } else if !viewModel.supportsAlternateIcons {
                Text(L("当前设备不支持切换应用图标。"))
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
        }
        .task {
            viewModel.refreshSelection()
        }
    }

    private func iconButton(_ option: SettingsAppIconOption) -> some View {
        Button {
            Task { await viewModel.select(option) }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(option.previewAssetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)

                    selectionIndicator(option)
                        .offset(x: 6, y: -6)
                }
                .frame(width: 84, height: 76)

                Text(option.title)
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 88, minHeight: 112)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.supportsAlternateIcons || isChangingAnyIcon)
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(Text(viewModel.isSelected(option) ? L("已选择") : L("未选择")))
        .accessibilityAddTraits(viewModel.isSelected(option) ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.\(option.id)")
    }

    @ViewBuilder
    private func selectionIndicator(_ option: SettingsAppIconOption) -> some View {
        if viewModel.isChanging(option) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        } else if viewModel.isSelected(option) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white, MusicFreeColorTokens.accent)
                .background(Circle().fill(MusicFreeColorTokens.backgroundPrimary))
        }
    }

    private var isChangingAnyIcon: Bool {
        viewModel.changingAlternateIconName != nil || viewModel.isChangingToPrimaryIcon
    }
}
