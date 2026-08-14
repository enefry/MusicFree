import DesignSystem
import MusicDomain
import SwiftUI

enum PlaylistEditorMode: Identifiable {
    case create
    case rename(PlaylistID, initialName: String)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let playlistID, _):
            return "rename-\(playlistID.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return L("新建歌单")
        case .rename:
            return L("重命名歌单")
        }
    }

    var initialName: String {
        switch self {
        case .create:
            return ""
        case .rename(_, let initialName):
            return initialName
        }
    }
}

struct PlaylistEditor: View {
    @Environment(\.dismiss) private var dismiss

    let mode: PlaylistEditorMode
    let existingPlaylists: [Playlist]
    let excludingID: PlaylistID?
    let onSave: @MainActor (String) async -> Bool

    @State private var name: String
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(
        mode: PlaylistEditorMode,
        existingPlaylists: [Playlist],
        excludingID: PlaylistID? = nil,
        onSave: @escaping @MainActor (String) async -> Bool
    ) {
        self.mode = mode
        self.existingPlaylists = existingPlaylists
        self.excludingID = excludingID
        self.onSave = onSave
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("名称"), text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(submit)
                } footer: {
                    HStack {
                        Text(L("最多 %d 个字符", PlaylistNameValidator.maximumLength))
                        Spacer(minLength: 0)
                        Text("\(name.count)/\(PlaylistNameValidator.maximumLength)")
                    }
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.destructive)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存"), action: submit)
                        .disabled(isSaving)
                }
            }
        }
    }

    private func submit() {
        guard !isSaving else {
            return
        }

        do {
            let normalizedName = try PlaylistNameValidator.validatedName(
                name,
                existingPlaylists: existingPlaylists,
                excludingID: excludingID
            )
            validationMessage = nil
            isSaving = true
            Task { @MainActor in
                let saved = await onSave(normalizedName)
                isSaving = false
                if saved {
                    dismiss()
                } else {
                    validationMessage = L("保存失败，请重试。")
                }
            }
        } catch {
            validationMessage = playlistFeatureMessage(for: error)
        }
    }
}
