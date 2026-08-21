import Darwin
import Foundation
import MediaSourceAPI
import MusicDomain

struct ManagedMediaLocation: Sendable {
  let url: URL
  let relativePath: String
}

struct ManagedArtworkLocation: Sendable {
  let url: URL
  let wasCreated: Bool
}

enum ManagedMediaPreparationInterruptionPoint: Equatable, Sendable {
  case afterManifest
  case afterMovedFiles(Int)
}

struct ManagedMediaPreparationInterrupted: Error, Sendable {
  let point: ManagedMediaPreparationInterruptionPoint
}

struct ManagedMediaPreparationFailurePlan: Sendable {
  let prepareMove: Int
  let restoreMove: Int
}

actor ManagedMediaStore {
  private struct RemovalLocation: Codable, Sendable {
    let itemID: MediaItemID
    let originalRelativePath: String
    let quarantineFileName: String
  }

  private struct RemovalManifest: Codable, Sendable {
    let transaction: MediaRemovalTransaction
    let locations: [RemovalLocation]
  }

  private let configuration: LocalMediaConfiguration
  private let preparationInterruptionPoint: ManagedMediaPreparationInterruptionPoint?
  private let preparationFailurePlan: ManagedMediaPreparationFailurePlan?
  private let fileManager = FileManager.default
  private let contentHasher = ContentHasher()
  private struct ArtworkImportState {
    var activeClaims: Int
    var wasCreatedByImport: Bool
    var hasCommittedOwner: Bool
  }
  private var artworkImportStates: [ArtworkID: ArtworkImportState] = [:]

  private var itemsRoot: URL {
    configuration.managedRoot.appendingPathComponent("items", isDirectory: true)
  }

  private var artworkRoot: URL {
    configuration.managedRoot.appendingPathComponent("artwork", isDirectory: true)
  }

  private var pendingRoot: URL {
    configuration.quarantineRoot.appendingPathComponent("pending", isDirectory: true)
  }

  private var committedRoot: URL {
    configuration.quarantineRoot.appendingPathComponent("committed", isDirectory: true)
  }

  private var rolledBackRoot: URL {
    configuration.quarantineRoot.appendingPathComponent("rolled-back", isDirectory: true)
  }

  init(
    configuration: LocalMediaConfiguration,
    preparationInterruptionPoint: ManagedMediaPreparationInterruptionPoint? = nil,
    preparationFailurePlan: ManagedMediaPreparationFailurePlan? = nil
  ) throws {
    self.configuration = configuration
    self.preparationInterruptionPoint = preparationInterruptionPoint
    self.preparationFailurePlan = preparationFailurePlan
    let itemsRoot = configuration.managedRoot.appendingPathComponent("items", isDirectory: true)
    let artworkRoot = configuration.managedRoot.appendingPathComponent("artwork", isDirectory: true)
    let pendingRoot = configuration.quarantineRoot.appendingPathComponent("pending", isDirectory: true)
    let committedRoot = configuration.quarantineRoot.appendingPathComponent("committed", isDirectory: true)
    let rolledBackRoot = configuration.quarantineRoot.appendingPathComponent("rolled-back", isDirectory: true)
    try fileManager.createDirectory(
      at: configuration.managedRoot,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(at: itemsRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: artworkRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: configuration.quarantineRoot,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(at: pendingRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: committedRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: rolledBackRoot, withIntermediateDirectories: true)
    guard Self.isContained(itemsRoot, in: configuration.managedRoot),
          Self.isContained(artworkRoot, in: configuration.managedRoot),
          Self.isContained(pendingRoot, in: configuration.quarantineRoot),
          Self.isContained(committedRoot, in: configuration.quarantineRoot),
          Self.isContained(rolledBackRoot, in: configuration.quarantineRoot)
    else {
      throw LocalMediaError.rootContainmentViolation
    }
  }

  func mediaURL(forExternalID externalID: String) throws -> URL {
    guard Self.isValidAssetIdentifier(externalID) else {
      throw LocalMediaError.invalidItemID
    }
    guard let url = try findItemURL(forExternalID: externalID) else {
      throw LocalMediaError.itemNotFound
    }
    return url
  }

  func artworkURL(for artworkID: ArtworkID) throws -> URL? {
    let rawValue = artworkID.rawValue
    guard Self.isValidAssetIdentifier(rawValue) else {
      throw LocalMediaError.invalidItemID
    }
    for candidate in try artworkCandidates(forRawValue: rawValue) {
      guard try isSafeRegularFile(candidate, inside: artworkRoot),
            try artworkFileMatchesIdentifier(candidate, rawValue: rawValue)
      else {
        throw LocalMediaError.destinationConflict
      }
      return candidate
    }
    return nil
  }

  func existingMediaURL(forExternalID externalID: String) throws -> URL? {
    guard Self.isValidAssetIdentifier(externalID) else {
      throw LocalMediaError.invalidItemID
    }
    return try findItemURL(forExternalID: externalID)
  }

  func moveToManaged(stagedURL: URL, externalID: String) throws -> ManagedMediaLocation {
    guard Self.isValidAssetIdentifier(externalID),
          Self.isContained(stagedURL, in: configuration.stagingRoot),
          try isSafeRegularFile(stagedURL, inside: configuration.stagingRoot)
    else {
      throw LocalMediaError.rootContainmentViolation
    }

    try fileManager.createDirectory(at: itemsRoot, withIntermediateDirectories: true)
    let extensionName = Self.safeExtension(for: stagedURL)
    let fileName = externalID + (extensionName.isEmpty ? ".media" : ".\(extensionName)")
    let destination = itemsRoot.appendingPathComponent(fileName, isDirectory: false)
    guard Self.isContained(destination, in: configuration.managedRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw LocalMediaError.destinationConflict
    }
    let managedRelativePath = try relativePath(
      for: destination,
      inside: configuration.managedRoot
    )

    do {
      try fileManager.moveItem(at: stagedURL, to: destination)
    } catch {
      throw Self.isOutOfSpace(error) ? LocalMediaError.insufficientStorage : .moveFailed
    }
    return ManagedMediaLocation(
      url: destination,
      relativePath: managedRelativePath
    )
  }

  func moveManagedBack(_ managedURL: URL, to stagingURL: URL) throws {
    guard Self.isContained(managedURL, in: configuration.managedRoot),
          Self.isContained(stagingURL, in: configuration.stagingRoot)
    else {
      throw LocalMediaError.rootContainmentViolation
    }
    guard fileManager.fileExists(atPath: managedURL.path) else {
      throw LocalMediaError.itemNotFound
    }
    guard !fileManager.fileExists(atPath: stagingURL.path) else {
      throw LocalMediaError.restoreConflict
    }
    do {
      try fileManager.createDirectory(
        at: stagingURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: managedURL, to: stagingURL)
    } catch {
      throw LocalMediaError.recoveryFailed
    }
  }

  func writeArtwork(_ data: Data, artworkID: ArtworkID) throws -> ManagedArtworkLocation {
    guard !data.isEmpty, Self.isValidAssetIdentifier(artworkID.rawValue) else {
      throw LocalMediaError.invalidItemID
    }
    guard data.count <= ArtworkDataLimits.maximumByteCount else {
      throw LocalMediaError.fileTooLarge
    }
    guard artworkDataMatchesIdentifier(data, rawValue: artworkID.rawValue) else {
      throw LocalMediaError.invalidItemID
    }
    try fileManager.createDirectory(at: artworkRoot, withIntermediateDirectories: true)
    let destination = artworkRoot.appendingPathComponent(artworkID.rawValue + ".bin")
    guard Self.isContained(destination, in: configuration.managedRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }
    if fileManager.fileExists(atPath: destination.path) {
      guard try isSafeRegularFile(destination, inside: artworkRoot),
            try artworkFileMatchesIdentifier(destination, rawValue: artworkID.rawValue)
      else {
        throw LocalMediaError.destinationConflict
      }
      return ManagedArtworkLocation(url: destination, wasCreated: false)
    }
    do {
      try data.write(to: destination, options: [.atomic])
      return ManagedArtworkLocation(url: destination, wasCreated: true)
    } catch {
      throw Self.isOutOfSpace(error) ? LocalMediaError.insufficientStorage : .copyFailed
    }
  }

  func beginImportedArtworkWrite(
    _ data: Data,
    artworkID: ArtworkID
  ) throws -> ManagedArtworkLocation {
    let location = try writeArtwork(data, artworkID: artworkID)
    var state = artworkImportStates[artworkID] ?? ArtworkImportState(
      activeClaims: 0,
      wasCreatedByImport: false,
      hasCommittedOwner: false
    )
    state.activeClaims += 1
    state.wasCreatedByImport = state.wasCreatedByImport || location.wasCreated
    artworkImportStates[artworkID] = state
    return location
  }

  func finishImportedArtworkWrite(_ artworkID: ArtworkID, committed: Bool) {
    guard var state = artworkImportStates[artworkID] else { return }
    state.activeClaims = max(0, state.activeClaims - 1)
    state.hasCommittedOwner = state.hasCommittedOwner || committed
    guard state.activeClaims == 0 else {
      artworkImportStates[artworkID] = state
      return
    }

    artworkImportStates[artworkID] = nil
    if state.wasCreatedByImport && !state.hasCommittedOwner {
      removeArtwork(artworkID)
    }
  }

  func removeArtwork(_ artworkID: ArtworkID) {
    guard Self.isValidAssetIdentifier(artworkID.rawValue) else { return }
    guard let candidates = try? artworkCandidates(forRawValue: artworkID.rawValue) else {
      return
    }
    for candidate in candidates where
      (try? isSafeRegularFile(candidate, inside: artworkRoot)) == true
    {
      try? fileManager.removeItem(at: candidate)
    }
  }

  func prepareRemoval(of itemIDs: Set<MediaItemID>) throws -> MediaRemovalTransaction {
    try prepareRemoval(of: itemIDs, assetIDs: nil)
  }

  func prepareRemoval(
    of itemIDs: Set<MediaItemID>,
    assetIDs requestedAssetIDs: Set<MediaAssetID>?
  ) throws -> MediaRemovalTransaction {
    guard !itemIDs.isEmpty else {
      throw LocalMediaError.invalidRemovalState
    }
    let sortedIDs = itemIDs.sorted()
    guard sortedIDs.allSatisfy({
      $0.sourceID == .local && Self.isValidItemIdentifier($0.externalID)
    }) else {
      throw LocalMediaError.invalidItemID
    }

    let assetIDs = requestedAssetIDs ?? Set(itemIDs.map(MediaAssetID.init(legacyVariantID:)))
    guard assetIDs.allSatisfy({
      $0.sourceID == .local && Self.isValidAssetIdentifier($0.externalID)
    }) else {
      throw LocalMediaError.invalidItemID
    }

    // A resolved logical-track removal may have no physical work when every
    // referenced asset is still owned by another track. There is no durable
    // quarantine state to recover in that case, so keep the transaction as a
    // valid no-op instead of creating an empty removal manifest.
    if requestedAssetIDs?.isEmpty == true {
      return MediaRemovalTransaction(
        transactionID: UUID(),
        itemIDs: itemIDs,
        assetIDs: requestedAssetIDs
      )
    }

    var sourceLocations: [(MediaAssetID, URL, String)] = []
    for assetID in assetIDs.sorted() {
      guard let url = try findItemURL(forExternalID: assetID.externalID) else {
        throw LocalMediaError.itemNotFound
      }
      sourceLocations.append(
        (
          assetID,
          url,
          try relativePath(for: url, inside: configuration.managedRoot)
        )
      )
    }

    let transaction = MediaRemovalTransaction(
      transactionID: UUID(),
      itemIDs: itemIDs,
      assetIDs: requestedAssetIDs
    )
    let transactionName = transaction.transactionID.uuidString
    let transactionRoot = pendingRoot.appendingPathComponent(transactionName, isDirectory: true)
    let preparingRoot = pendingRoot.appendingPathComponent(
      ".preparing-\(transactionName)",
      isDirectory: true
    )
    let locations = sourceLocations.map { assetID, sourceURL, originalRelativePath in
      RemovalLocation(
        itemID: assetID.mediaItemID,
        originalRelativePath: originalRelativePath,
        quarantineFileName: sourceURL.lastPathComponent
      )
    }
    let manifest = RemovalManifest(transaction: transaction, locations: locations)

    var movedLocations: [RemovalLocation] = []
    do {
      let preparingMediaRoot = preparingRoot.appendingPathComponent("media", isDirectory: true)
      try fileManager.createDirectory(at: preparingMediaRoot, withIntermediateDirectories: true)
      try writeJSON(manifest, to: preparingRoot.appendingPathComponent("manifest.json"))
      try fileManager.moveItem(at: preparingRoot, to: transactionRoot)
      try synchronizeDirectory(at: pendingRoot)
      try interruptPreparationIfNeeded(at: .afterManifest)

      let mediaRoot = transactionRoot.appendingPathComponent("media", isDirectory: true)
      for (sourceLocation, location) in zip(sourceLocations, locations) {
        let sourceURL = sourceLocation.1
        let destination = mediaRoot.appendingPathComponent(
          location.quarantineFileName,
          isDirectory: false
        )
        guard Self.isContained(destination, in: configuration.quarantineRoot) else {
          throw LocalMediaError.rootContainmentViolation
        }
        if preparationFailurePlan?.prepareMove == movedLocations.count + 1 {
          throw LocalMediaError.moveFailed
        }
        try fileManager.moveItem(at: sourceURL, to: destination)
        movedLocations.append(location)
        try interruptPreparationIfNeeded(at: .afterMovedFiles(movedLocations.count))
      }

      return transaction
    } catch let error as ManagedMediaPreparationInterrupted {
      // Test-only crash simulation: preserve the durable on-disk state so a
      // fresh remover instance must recover it exactly as after process death.
      throw error
    } catch let error as LocalMediaError {
      do {
        try compensateFailedPreparation(
          movedLocations,
          transactionRoot: transactionRoot,
          preparingRoot: preparingRoot
        )
      } catch {
        throw LocalMediaError.recoveryFailed
      }
      throw error
    } catch {
      do {
        try compensateFailedPreparation(
          movedLocations,
          transactionRoot: transactionRoot,
          preparingRoot: preparingRoot
        )
      } catch {
        throw LocalMediaError.recoveryFailed
      }
      throw Self.isOutOfSpace(error) ? LocalMediaError.insufficientStorage : .moveFailed
    }
  }

  func pendingRemovals() async throws -> [MediaRemovalTransaction] {
    var transactions: [MediaRemovalTransaction] = []
    for entry in try pendingEntries() {
      guard Self.isContained(entry, in: pendingRoot),
            let values = try? entry.resourceValues(
              forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
            values.isDirectory == true,
            values.isSymbolicLink != true
      else { continue }
      let manifestURL = entry.appendingPathComponent("manifest.json")
      do {
        let manifest = try readJSON(RemovalManifest.self, from: manifestURL)
        try validatePendingManifest(manifest, transactionRoot: entry)
        transactions.append(manifest.transaction)
      } catch {
        await repairMalformedPendingEntry(entry)
        continue
      }
    }
    return transactions
  }

  func pendingRemovalEntryCount() throws -> Int {
    try pendingEntries().count
  }

  func commitRemoval(_ transaction: MediaRemovalTransaction) throws {
    try validateTransaction(transaction)
    if transaction.assetIDs?.isEmpty == true {
      return
    }
    if markerExists(transactionID: transaction.transactionID, in: committedRoot) {
      // A crash can occur after the committed marker is durable but before
      // the quarantine directory is removed. Finish that cleanup on retry;
      // once no pending directory remains, preserve the public already-
      // committed result for callers that repeat a completed operation.
      let transactionRoot = pendingRoot.appendingPathComponent(
        transaction.transactionID.uuidString,
        isDirectory: true
      )
      guard Self.isContained(transactionRoot, in: pendingRoot) else {
        throw LocalMediaError.rootContainmentViolation
      }
      guard fileManager.fileExists(atPath: transactionRoot.path) else {
        throw LocalMediaError.alreadyCommitted
      }
      do {
        try fileManager.removeItem(at: transactionRoot)
      } catch {
        throw LocalMediaError.deleteFailed
      }
      return
    }
    if markerExists(transactionID: transaction.transactionID, in: rolledBackRoot) {
      throw LocalMediaError.alreadyRolledBack
    }

    let (manifest, transactionRoot) = try loadPendingManifest(for: transaction)
    guard manifest.transaction == transaction else {
      throw LocalMediaError.invalidRemovalState
    }
    try validateCompletePreparation(manifest, transactionRoot: transactionRoot)
    guard Self.isContained(transactionRoot, in: pendingRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }
    do {
      try writeJSON(
        transaction,
        to: committedRoot.appendingPathComponent(transaction.transactionID.uuidString + ".json")
      )
    } catch {
      throw LocalMediaError.recoveryFailed
    }
    do {
      try fileManager.removeItem(at: transactionRoot)
    } catch {
      // The marker intentionally remains. A later recovery pass recognizes
      // the marker and removes this still-pending quarantine directory.
      throw LocalMediaError.deleteFailed
    }
  }

  func rollbackRemoval(_ transaction: MediaRemovalTransaction) throws {
    try validateTransaction(transaction)
    if transaction.assetIDs?.isEmpty == true {
      return
    }
    if markerExists(transactionID: transaction.transactionID, in: committedRoot) {
      throw LocalMediaError.alreadyCommitted
    }
    if markerExists(transactionID: transaction.transactionID, in: rolledBackRoot) {
      throw LocalMediaError.alreadyRolledBack
    }

    let (manifest, transactionRoot) = try loadPendingManifest(for: transaction)
    guard manifest.transaction == transaction else {
      throw LocalMediaError.invalidRemovalState
    }

    for location in manifest.locations {
      let originalURL = configuration.managedRoot
        .appendingPathComponent(location.originalRelativePath, isDirectory: false)
      let quarantineURL = transactionRoot
        .appendingPathComponent("media", isDirectory: true)
        .appendingPathComponent(location.quarantineFileName, isDirectory: false)
      guard Self.isContained(originalURL, in: configuration.managedRoot),
            Self.isContained(quarantineURL, in: configuration.quarantineRoot)
      else {
        throw LocalMediaError.rootContainmentViolation
      }
      if fileManager.fileExists(atPath: originalURL.path) {
        if fileManager.fileExists(atPath: quarantineURL.path) {
          throw LocalMediaError.restoreConflict
        }
        continue
      }
      guard fileManager.fileExists(atPath: quarantineURL.path) else {
        throw LocalMediaError.recoveryFailed
      }
      do {
        try fileManager.createDirectory(
          at: originalURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: quarantineURL, to: originalURL)
      } catch {
        throw LocalMediaError.moveFailed
      }
    }

    do {
      try fileManager.removeItem(at: transactionRoot)
      try writeJSON(
        transaction,
        to: rolledBackRoot.appendingPathComponent(transaction.transactionID.uuidString + ".json")
      )
    } catch {
      throw LocalMediaError.recoveryFailed
    }
  }

  private func findItemURL(forExternalID externalID: String) throws -> URL? {
    let entries = try fileManager.contentsOfDirectory(
      at: itemsRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    let prefix = externalID + "."
    for entry in entries.sorted(by: { $0.path < $1.path }) {
      guard entry.lastPathComponent.hasPrefix(prefix),
            try isSafeRegularFile(entry, inside: itemsRoot)
      else { continue }
      return entry
    }
    return nil
  }

  private func validateTransaction(_ transaction: MediaRemovalTransaction) throws {
    guard !transaction.itemIDs.isEmpty,
          transaction.itemIDs.allSatisfy({
          $0.sourceID == .local && Self.isValidItemIdentifier($0.externalID)
          }),
          transaction.assetIDs?.allSatisfy({
            $0.sourceID == .local && Self.isValidAssetIdentifier($0.externalID)
          }) ?? true
    else {
      throw LocalMediaError.invalidRemovalState
    }
  }

  private func loadPendingManifest(
    for transaction: MediaRemovalTransaction
  ) throws -> (RemovalManifest, URL) {
    let transactionRoot = pendingRoot.appendingPathComponent(transaction.transactionID.uuidString)
    guard Self.isContained(transactionRoot, in: pendingRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }
    let manifestURL = transactionRoot.appendingPathComponent("manifest.json")
    do {
      return (
        try readJSON(RemovalManifest.self, from: manifestURL),
        transactionRoot
      )
    } catch {
      throw LocalMediaError.unknownTransaction
    }
  }

  private func restoreMovedFiles(
    _ locations: [RemovalLocation],
    transactionRoot: URL
  ) throws {
    for (index, location) in locations.reversed().enumerated() {
      let source = transactionRoot
        .appendingPathComponent("media", isDirectory: true)
        .appendingPathComponent(location.quarantineFileName)
      let destination = configuration.managedRoot.appendingPathComponent(location.originalRelativePath)
      guard Self.isContained(source, in: configuration.quarantineRoot),
            Self.isContained(destination, in: configuration.managedRoot)
      else { continue }
      guard fileManager.fileExists(atPath: source.path),
            !fileManager.fileExists(atPath: destination.path)
      else { continue }
      if preparationFailurePlan?.restoreMove == index + 1 {
        throw LocalMediaError.recoveryFailed
      }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: source, to: destination)
    }
  }

  private func compensateFailedPreparation(
    _ locations: [RemovalLocation],
    transactionRoot: URL,
    preparingRoot: URL
  ) throws {
    do {
      try restoreMovedFiles(locations, transactionRoot: transactionRoot)
    } catch {
      try? fileManager.removeItem(at: preparingRoot)
      throw error
    }

    if fileManager.fileExists(atPath: transactionRoot.path) {
      try fileManager.removeItem(at: transactionRoot)
    }
    if fileManager.fileExists(atPath: preparingRoot.path) {
      try fileManager.removeItem(at: preparingRoot)
    }
  }

  private func pendingEntries() throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: pendingRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).sorted(by: { $0.path < $1.path })
  }

  private func repairMalformedPendingEntry(_ transactionRoot: URL) async {
    guard Self.isContained(transactionRoot, in: pendingRoot) else { return }
    if let transactionID = UUID(uuidString: transactionRoot.lastPathComponent),
       markerExists(transactionID: transactionID, in: committedRoot)
        || markerExists(transactionID: transactionID, in: rolledBackRoot)
    {
      return
    }

    let mediaRoot = transactionRoot.appendingPathComponent("media", isDirectory: true)
    guard Self.isContained(mediaRoot, in: transactionRoot),
          let mediaRootValues = try? mediaRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
          ),
          mediaRootValues.isDirectory == true,
          mediaRootValues.isSymbolicLink != true,
          let entries = try? fileManager.contentsOfDirectory(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
          )
    else {
      return
    }

    let candidates = entries.compactMap { source -> (String, URL, URL)? in
      guard source.deletingLastPathComponent().standardizedFileURL
              == mediaRoot.standardizedFileURL,
            (try? isSafeRegularFile(source, inside: mediaRoot)) == true,
            let contentID = Self.contentIdentifier(fromManagedFileName: source.lastPathComponent)
      else {
        return nil
      }
      let destination = itemsRoot.appendingPathComponent(
        source.lastPathComponent,
        isDirectory: false
      )
      guard Self.isContained(destination, in: itemsRoot) else { return nil }
      return (contentID, source, destination)
    }
    let candidateCounts = Dictionary(grouping: candidates, by: { $0.0 })
      .mapValues(\.count)

    for (contentID, source, destination) in candidates {
      guard candidateCounts[contentID] == 1,
            !fileManager.fileExists(atPath: destination.path)
      else {
        continue
      }
      guard let contentHash = try? await contentHasher.hash(fileAt: source),
            contentHash.caseInsensitiveCompare(
              String(contentID.dropFirst("sha256-".count))
            ) == .orderedSame
      else {
        // A malformed manifest is not permission to trust a filename. Only
        // restore bytes whose content still matches their content address.
        continue
      }
      let existingManagedURL: URL?
      do {
        existingManagedURL = try findItemURL(forExternalID: contentID)
      } catch {
        continue
      }
      guard existingManagedURL == nil else { continue }
      do {
        try fileManager.moveItem(at: source, to: destination)
        try synchronizeDirectory(at: itemsRoot)
        try synchronizeDirectory(at: mediaRoot)
      } catch {
        // The transaction directory and every unresolved candidate remain in
        // place. A successful move is never undone by deleting either copy.
        continue
      }
    }
  }

  private func validatePendingManifest(
    _ manifest: RemovalManifest,
    transactionRoot: URL
  ) throws {
    try validateTransaction(manifest.transaction)
    let expectedLocationIDs = expectedLocationIDs(for: manifest.transaction)
    guard transactionRoot.lastPathComponent == manifest.transaction.transactionID.uuidString,
          manifest.locations.count == expectedLocationIDs.count,
          Set(manifest.locations.map(\.itemID)) == expectedLocationIDs
    else {
      throw LocalMediaError.invalidRemovalState
    }
    for location in manifest.locations {
      let originalURL = configuration.managedRoot
        .appendingPathComponent(location.originalRelativePath, isDirectory: false)
      let quarantineURL = transactionRoot
        .appendingPathComponent("media", isDirectory: true)
        .appendingPathComponent(location.quarantineFileName, isDirectory: false)
      guard !location.quarantineFileName.isEmpty,
            location.quarantineFileName == URL(fileURLWithPath: location.quarantineFileName)
              .lastPathComponent,
            Self.isContained(originalURL, in: configuration.managedRoot),
            Self.isContained(quarantineURL, in: configuration.quarantineRoot)
      else {
        throw LocalMediaError.rootContainmentViolation
      }
    }
  }

  private func validateCompletePreparation(
    _ manifest: RemovalManifest,
    transactionRoot: URL
  ) throws {
    let expectedLocationIDs = expectedLocationIDs(for: manifest.transaction)
    let locationItemIDs = Set(manifest.locations.map(\.itemID))
    guard manifest.locations.count == expectedLocationIDs.count,
          locationItemIDs == expectedLocationIDs
    else {
      throw LocalMediaError.invalidRemovalState
    }

    for location in manifest.locations {
      let originalURL = configuration.managedRoot
        .appendingPathComponent(location.originalRelativePath, isDirectory: false)
      let quarantineURL = transactionRoot
        .appendingPathComponent("media", isDirectory: true)
        .appendingPathComponent(location.quarantineFileName, isDirectory: false)
      guard Self.isContained(originalURL, in: configuration.managedRoot),
            Self.isContained(quarantineURL, in: configuration.quarantineRoot)
      else {
        throw LocalMediaError.rootContainmentViolation
      }
      guard !fileManager.fileExists(atPath: originalURL.path) else {
        throw LocalMediaError.invalidRemovalState
      }
      guard fileManager.fileExists(atPath: quarantineURL.path) else {
        throw LocalMediaError.recoveryFailed
      }
    }
  }

  private func expectedLocationIDs(
    for transaction: MediaRemovalTransaction
  ) -> Set<MediaItemID> {
    if let assetIDs = transaction.assetIDs {
      return Set(assetIDs.map(\.mediaItemID))
    }
    // A nil assetIDs field is the legacy manifest shape, where every logical
    // item also identified its managed file.
    return transaction.itemIDs
  }

  private func interruptPreparationIfNeeded(
    at point: ManagedMediaPreparationInterruptionPoint
  ) throws {
    guard preparationInterruptionPoint == point else { return }
    throw ManagedMediaPreparationInterrupted(point: point)
  }

  private func relativePath(for url: URL, inside root: URL) throws -> String {
    guard Self.isContained(url, in: root) else {
      throw LocalMediaError.rootContainmentViolation
    }
    let prefix = root.standardizedFileURL.path.hasSuffix("/")
      ? root.standardizedFileURL.path
      : root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(prefix) else {
      throw LocalMediaError.rootContainmentViolation
    }
    let relative = String(path.dropFirst(prefix.count))
    let components = relative.split(separator: "/")
    guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
      throw LocalMediaError.invalidRelativePath
    }
    return relative
  }

  private func isSafeRegularFile(_ url: URL, inside root: URL) throws -> Bool {
    guard Self.isContained(url, in: root) else { return false }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private func artworkFileMatchesIdentifier(_ url: URL, rawValue: String) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let fileSize = values.fileSize,
          fileSize <= ArtworkDataLimits.maximumByteCount,
          let data = try readArtworkData(
            at: url,
            maximumByteCount: ArtworkDataLimits.maximumByteCount
          )
    else {
      return false
    }
    return artworkDataMatchesIdentifier(data, rawValue: rawValue)
  }

  private func artworkCandidates(forRawValue rawValue: String) throws -> [URL] {
    let prefix = rawValue + "."
    return try fileManager.contentsOfDirectory(
      at: artworkRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    .filter { candidate in
      candidate.lastPathComponent.hasPrefix(prefix)
        && candidate.deletingPathExtension().lastPathComponent == rawValue
        && Self.isSafeArtworkExtension(candidate.pathExtension)
    }
    .sorted {
      let lhsIsCanonical = $0.pathExtension.caseInsensitiveCompare("bin") == .orderedSame
      let rhsIsCanonical = $1.pathExtension.caseInsensitiveCompare("bin") == .orderedSame
      if lhsIsCanonical != rhsIsCanonical {
        return lhsIsCanonical
      }
      return $0.lastPathComponent < $1.lastPathComponent
    }
  }

  private func readArtworkData(at url: URL, maximumByteCount: Int) throws -> Data? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var data = Data()
    while true {
      let remaining = maximumByteCount - data.count
      let readCount = remaining == 0 ? 1 : remaining + 1
      guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
        return data
      }
      guard chunk.count <= remaining else {
        return nil
      }
      data.append(chunk)
    }
  }

  private func artworkDataMatchesIdentifier(_ data: Data, rawValue: String) -> Bool {
    let expectedHash = String(rawValue.dropFirst("sha256-".count))
    return MusicContentIdentity.sha256Hex(data).caseInsensitiveCompare(expectedHash) == .orderedSame
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    guard Self.isContained(url, in: configuration.quarantineRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }
    let data = try JSONEncoder().encode(value)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: [.atomic])
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
    try synchronizeDirectory(at: url.deletingLastPathComponent())
  }

  private func synchronizeDirectory(at url: URL) throws {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY)
    }
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    guard Self.isContained(url, in: configuration.quarantineRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
  }

  private func markerExists(transactionID: UUID, in root: URL) -> Bool {
    let marker = root.appendingPathComponent(transactionID.uuidString + ".json")
    return fileManager.fileExists(atPath: marker.path)
  }

  private static func isValidAssetIdentifier(_ value: String) -> Bool {
    guard value.hasPrefix("sha256-") else { return false }
    let hash = value.dropFirst("sha256-".count)
    return hash.count == 64 && hash.allSatisfy { $0.isHexDigit }
  }

  private static func isValidItemIdentifier(_ value: String) -> Bool {
    if isValidAssetIdentifier(value) { return true }
    return value.range(
      of: #"^cue-[0-9a-f]{64}-f[1-9][0-9]*-t[1-9][0-9]*$"#,
      options: .regularExpression
    ) != nil
  }

  private static func contentIdentifier(fromManagedFileName fileName: String) -> String? {
    let fileURL = URL(fileURLWithPath: fileName, isDirectory: false)
    let fileExtension = fileURL.pathExtension
    let contentID = fileURL.deletingPathExtension().lastPathComponent
    guard fileName == fileURL.lastPathComponent,
          !fileExtension.isEmpty,
          fileExtension == fileExtension.lowercased(),
          fileExtension.count <= 16,
          fileExtension.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
          }),
          fileName == "\(contentID).\(fileExtension)",
          isValidAssetIdentifier(contentID)
    else {
      return nil
    }
    return contentID
  }

  private static func safeExtension(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    guard !ext.isEmpty,
          ext.count <= 16,
          ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else {
      return ""
    }
    return ext
  }

  private static func isSafeArtworkExtension(_ ext: String) -> Bool {
    !ext.isEmpty
      && ext.count <= 16
      && ext.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
      }
  }

  private static func isContained(_ url: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }

  private static func isOutOfSpace(_ error: Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
      || (error.domain == NSPOSIXErrorDomain && error.code == 28)
  }
}
