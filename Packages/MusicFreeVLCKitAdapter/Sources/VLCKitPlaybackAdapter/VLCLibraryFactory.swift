import Foundation

#if canImport(VLCKit)
@preconcurrency import VLCKit

internal enum VLCLibraryFactory {
  private static let parametersDefaultsKey = "VLCParams"

  static func shared(configuration: VLCKitAdapterConfiguration) throws -> VLCLibrary {
    // The audio-only binary removes modules referenced by VLCKit's default
    // arguments. An explicit empty list prevents libvlc_new from rejecting an
    // obsolete option such as --avi-index before the shared instance exists.
    UserDefaults.standard.set([String](), forKey: parametersDefaultsKey)

    let library = VLCLibrary.shared()
    library.setApplicationIdentifier(
      configuration.applicationIdentifier,
      withVersion: configuration.applicationVersion,
      andApplicationIconName: ""
    )
    return library
  }
}
#endif
