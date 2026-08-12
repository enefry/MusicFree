import SwiftUI
import UniformTypeIdentifiers

struct MediaImportPicker: ViewModifier {
    @Binding var isPresented: Bool
    let onSelection: @MainActor ([URL]) async -> Void
    let onFailure: (String) -> Void

    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: $isPresented,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                consume(urls)
            case .failure(let error):
                onFailure(error.localizedDescription)
            }
        }
    }

    private func consume(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let scopedURLs = urls.map { url in
            (url: url, didStartAccess: url.startAccessingSecurityScopedResource())
        }

        // The view does not retain selected URLs. ImportServing receives them while
        // the document picker access scope is active and owns any longer-lived work.
        Task { @MainActor in
            await onSelection(urls)
            for scopedURL in scopedURLs where scopedURL.didStartAccess {
                scopedURL.url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

extension View {
    func mediaImportPicker(
        isPresented: Binding<Bool>,
        onSelection: @escaping @MainActor ([URL]) async -> Void,
        onFailure: @escaping (String) -> Void
    ) -> some View {
        modifier(
            MediaImportPicker(
                isPresented: isPresented,
                onSelection: onSelection,
                onFailure: onFailure
            )
        )
    }
}
