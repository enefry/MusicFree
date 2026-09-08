import Foundation
import MusicDomain

/// Keeps album pages aligned with source-provided disc and track positions.
/// If an album has exactly one explicit disc value, missing values are treated
/// as belonging to that disc for ordering only. The display never fabricates a
/// disc prefix for tracks whose source metadata omitted it.
enum LibraryAlbumTrackOrdering {
    static func ordered(_ tracks: [Track]) -> [Track] {
        let shouldUseDiscNumbers = usesDiscNumbers(in: tracks)
        let explicitDiscNumbers = Set(tracks.compactMap(\.discNumber))
        let inferredDiscNumber = shouldUseDiscNumbers && explicitDiscNumbers.count == 1
            ? explicitDiscNumbers.first
            : nil

        func effectiveDiscNumber(for track: Track) -> Int? {
            guard shouldUseDiscNumbers else { return nil }
            return track.discNumber ?? inferredDiscNumber
        }

        return tracks.sorted { lhs, rhs in
            switch (effectiveDiscNumber(for: lhs), effectiveDiscNumber(for: rhs)) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            let leftTrack = lhs.trackNumber ?? Int.max
            let rightTrack = rhs.trackNumber ?? Int.max
            if leftTrack != rightTrack {
                return leftTrack < rightTrack
            }

            let leftTitle = lhs.sortTitle ?? lhs.title
            let rightTitle = rhs.sortTitle ?? rhs.title
            let titleOrder = leftTitle.localizedStandardCompare(rightTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    static func displayNumber(for track: Track) -> String? {
        guard let trackNumber = track.trackNumber else { return nil }
        guard let discNumber = track.discNumber, discNumber > 1 else {
            return String(trackNumber)
        }
        return "\(discNumber)-\(trackNumber)"
    }

    static func displayNumber(for track: Track, in tracks: [Track]) -> String? {
        guard let trackNumber = track.trackNumber else { return nil }
        guard usesDiscNumbers(in: tracks),
              let discNumber = track.discNumber,
              discNumber > 1
        else {
            return String(trackNumber)
        }
        return "\(discNumber)-\(trackNumber)"
    }

    private static func usesDiscNumbers(in tracks: [Track]) -> Bool {
        let numberedTracks = tracks.filter { $0.trackNumber != nil }
        guard !numberedTracks.isEmpty else { return false }

        let explicitDiscNumbers = Set(numberedTracks.compactMap(\.discNumber))
        guard !explicitDiscNumbers.isEmpty else { return false }

        // A single explicit disc value can safely fill in missing values. With
        // multiple disc values, every numbered track must carry a disc value;
        // otherwise an isolated bad tag can move one track to another disc and
        // destroy the album's track-number order.
        return explicitDiscNumbers.count == 1
            || numberedTracks.allSatisfy { $0.discNumber != nil }
    }
}
