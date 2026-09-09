import Foundation
import MediaSourceAPI
import Testing
import UIKit
@testable import VLCKitPlaybackAdapter

struct VLCDirectMediaProbeTests {
  private static var sampleDirectory: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("medias/mp4", isDirectory: true)
  }

  @Test("Workspace MP4 samples produce one distinct cover per source video",
        .enabled(if: FileManager.default.fileExists(atPath: sampleDirectory.path)))
  func workspaceVideoArtworkSamples() async throws {
    let urls = try FileManager.default.contentsOfDirectory(
      at: Self.sampleDirectory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.path < $1.path }
    #expect(urls.count >= 2)
    let config = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.real-artwork",
      applicationVersion: "1.0", applicationName: "Real Artwork Test", parserTimeout: .seconds(30)
    )
    let reader = try VLCMetadataReader(configuration: config)
    var artworks = Set<Data>()
    for url in urls {
      let metadata = try await reader.readMetadata(from: .local(url))
      let artwork = try #require(metadata.firstArtwork)
      #expect(UIImage(data: artwork.data) != nil)
      artworks.insert(artwork.data)
    }
    print("WORKSPACE_VIDEO_ARTWORK samples=\(urls.count) distinct=\(artworks.count)")
    #expect(artworks.count == urls.count)
  }

  @Test("Local video imports get distinct source frames without embedded covers")
  func videoArtworkComesFromEachAsset() async throws {
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.artwork-test",
      applicationVersion: "1.0", applicationName: "Artwork Test",
      parserTimeout: .seconds(30)
    )
    let reader = try VLCMetadataReader(configuration: configuration)
    var images: [Data] = []
    for name in ["artwork-red", "artwork-blue"] {
      let url = try #require(Bundle.module.url(
        forResource: name, withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let metadata = try await reader.readMetadata(from: .local(url))
      let artwork = try #require(metadata.firstArtwork)
      let image = try #require(UIImage(data: artwork.data)?.cgImage)
      #expect(image.width == 64 && image.height == 64)
      var pixel = [UInt8](repeating: 0, count: 4)
      let context = try #require(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      if name == "artwork-red" { #expect(pixel[0] > 200 && pixel[2] < 30) }
      else { #expect(pixel[2] > 200 && pixel[0] < 30) }
      images.append(artwork.data)
    }
    #expect(images[0] != images[1])
  }

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
