import Foundation
import MediaSourceAPI
import Testing
@testable import VLCKitPlaybackAdapter

struct VLCDirectMediaProbeTests {
  @Test(
    "Direct probe accepts an explicit large local media sample",
    .enabled(if: ProcessInfo.processInfo.environment["MUSICFREE_VLC_SAMPLE_PATH"] != nil)
  )
  func probeExplicitLocalSample() async throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["MUSICFREE_VLC_SAMPLE_PATH"]
    )
    let url = URL(fileURLWithPath: path)
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.explicit-probe",
      applicationVersion: "1.0",
      applicationName: "MusicFree Explicit Probe",
      parserTimeout: .seconds(30)
    )
    let probe = try VLCMediaProbe(configuration: configuration)
    let metadataReader = try VLCMetadataReader(configuration: configuration)

    let result = try await probe.probe(.local(url)).validated()
    let metadata = try await metadataReader.readMetadata(from: .local(url))

    #expect(result.audioTracks.isEmpty == false)
    #expect(result.duration != nil)
    #expect(metadata.duration != nil)
  }

  @Test("Direct VLCKit probe of the failing and freshly re-encoded ALAC files")
  func probeFixtures() async throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.probe",
      applicationVersion: "1.0",
      applicationName: "MusicFree Probe",
      parserTimeout: .seconds(30)
    )
    let probe = try VLCMediaProbe(configuration: configuration)
    let metadataReader = try VLCMetadataReader(configuration: configuration)

    let fixtures: [(String, URL)] = [
      ("current", try #require(Bundle.module.url(
        forResource: "current",
        withExtension: "m4a",
        subdirectory: "Fixtures"
      ))),
      ("reencoded", try #require(Bundle.module.url(
        forResource: "reencoded",
        withExtension: "m4a",
        subdirectory: "Fixtures"
      )))
    ]

    var currentError: Error?
    var reencodedResult: MediaProbeResult?
    var currentMetadataError: Error?
    var reencodedMetadataError: Error?

    for (label, url) in fixtures {
      do {
        let result = try await probe.probe(.local(url))
        print(
          "DIRECT_VLC_PROBE label=\(label) status=success "
            + "tracks=\(result.audioTracks.count) "
            + "codecs=\(result.audioTracks.compactMap(\.codec)) "
            + "duration=\(String(describing: result.duration)) "
            + "hasVideo=\(result.hasVideoTrack)"
        )
        if label == "reencoded" {
          reencodedResult = result
        }
      } catch {
        print(
          "DIRECT_VLC_PROBE label=\(label) status=failure "
            + "error=\(String(reflecting: error))"
        )
        if label == "current" {
          currentError = error
        }
      }

      do {
        let metadata = try await metadataReader.readMetadata(from: .local(url))
        print(
          "DIRECT_VLC_METADATA label=\(label) status=success "
            + "title=\(String(describing: metadata.title)) "
            + "artist=\(String(describing: metadata.artist)) "
            + "album=\(String(describing: metadata.album)) "
            + "artworks=\(metadata.artworks.count)"
        )
      } catch {
        print(
          "DIRECT_VLC_METADATA label=\(label) status=failure "
            + "error=\(String(reflecting: error))"
        )
        if label == "current" {
          currentMetadataError = error
        } else {
          reencodedMetadataError = error
        }
      }
    }

    #expect(currentError == nil)
    #expect(reencodedResult?.audioTracks.isEmpty == false)
    let reencodedCodecs = reencodedResult?.audioTracks.map { $0.codec ?? "<nil>" } ?? []
    #expect(reencodedCodecs == ["Apple Lossless Audio Codec"])
    #expect(currentMetadataError == nil)
    #expect(reencodedMetadataError == nil)
  }
}
