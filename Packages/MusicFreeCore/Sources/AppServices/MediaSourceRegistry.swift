import MediaSourceAPI
import MusicDomain

/// The application-owned source lookup table. Source instances remain owned by
/// the composition root and are never created by this module.
internal actor MediaSourceRegistry: MediaSourceResolving {
    private let sources: [MediaSourceID: any MediaSource]

    init(sources: [any MediaSource]) throws {
        var values: [MediaSourceID: any MediaSource] = [:]
        for source in sources {
            let sourceID = source.descriptor.sourceID
            guard values[sourceID] == nil else {
                throw AppServiceError.duplicateSource(sourceID)
            }
            values[sourceID] = source
        }
        self.sources = values
    }

    func source(for sourceID: MediaSourceID) async throws -> any MediaSource {
        guard let source = sources[sourceID] else {
            throw MediaSourceError.sourceNotFound(sourceID)
        }
        return source
    }

    func registeredSourceIDs() -> [MediaSourceID] {
        sources.keys.sorted()
    }
}
