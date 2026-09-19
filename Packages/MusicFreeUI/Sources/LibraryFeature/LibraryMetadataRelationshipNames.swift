enum TrackMetadataEditorRelationshipNames {
    static func forUpdate(
        originalNames: [String]?,
        currentValue: String
    ) -> [String]? {
        if let originalNames {
            guard displayNames(originalNames) != currentValue else {
                return originalNames
            }
            return split(currentValue)
        }

        // A missing album has no album-artist relationship to clear. Keep nil
        // for an untouched blank field so the service can apply its default
        // album-artist fallback when the user creates an album.
        let names = split(currentValue)
        return names.isEmpty ? nil : names
    }

    static func displayNames(_ names: [String]) -> String {
        names.joined(separator: " / ")
    }

    private static func split(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
