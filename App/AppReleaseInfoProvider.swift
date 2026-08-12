import Foundation
import SettingsFeature

/// Reads the checked-in release manifest instead of scattering dependency
/// claims through the settings UI. Missing or malformed manifests are treated
/// as unavailable release metadata and never block normal app startup.
struct AppReleaseInfoProvider: SettingsReleaseInfoProviding, @unchecked Sendable {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func releaseInfo() async -> SettingsReleaseInfo? {
        // Xcode may copy explicit resource files at the bundle root even when
        // their source path contains a directory. Support both layouts while
        // keeping the checked-in manifest as the single source of truth.
        let url = bundle.url(
            forResource: "ThirdPartyNotices/manifest",
            withExtension: "json"
        ) ?? bundle.url(forResource: "manifest", withExtension: "json")
        guard let url else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
            let appVersion = normalized(
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
            let buildNumber = normalized(
                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            )
            return SettingsReleaseInfo(
                appVersion: appVersion,
                buildNumber: buildNumber,
                dependencies: manifest.dependencies.map { $0.settingsDependency(in: bundle) }
            )
        } catch {
            return nil
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ReleaseManifest: Decodable {
    let schemaVersion: Int
    let dependencies: [ReleaseDependency]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case dependencies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported release manifest schema."
            )
        }
        self.schemaVersion = schemaVersion
        self.dependencies = try container.decode(
            [ReleaseDependency].self,
            forKey: .dependencies
        )
    }
}

private struct ReleaseDependency: Decodable {
    let id: String
    let name: String
    let version: String?
    let license: String?
    let kind: String
    let sourceURL: URL?
    let buildMaterialsURL: URL?
    let licenseURL: URL?
    let licenseFile: String?
    let revision: String?
    let checksum: String?

    func settingsDependency(in bundle: Bundle) -> SettingsDependencyLicense {
        let dependencyKind: SettingsDependencyKind
        switch kind.lowercased() {
        case "source": dependencyKind = .source
        case "binary": dependencyKind = .binary
        default: dependencyKind = .other
        }
        return SettingsDependencyLicense(
            id: id,
            name: name,
            version: version,
            license: license,
            kind: dependencyKind,
            sourceURL: sourceURL,
            buildMaterialsURL: buildMaterialsURL,
            licenseURL: licenseURL,
            licenseFile: normalized(licenseFile),
            licenseText: localLicenseText(in: bundle),
            revision: normalized(revision),
            checksum: normalized(checksum)
        )
    }

    private func localLicenseText(in bundle: Bundle) -> String? {
        guard let licenseFile = normalized(licenseFile),
              let url = bundleURL(for: licenseFile, in: bundle),
              let data = try? Data(contentsOf: url),
              data.count <= 1_000_000
        else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func bundleURL(for relativePath: String, in bundle: Bundle) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !relativePath.hasPrefix("/"),
              components.allSatisfy({ $0 != "." && $0 != ".." }),
              let resourceRoot = bundle.resourceURL
        else {
            return nil
        }

        let candidates = [
            resourceRoot.appendingPathComponent("ThirdPartyNotices", isDirectory: true)
                .appendingPathComponent(relativePath),
            resourceRoot.appendingPathComponent(relativePath)
        ]
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard standardized.path.hasPrefix(resourceRoot.standardizedFileURL.path + "/") else {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return standardized
            }
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AppDiagnosticsProvider: SettingsDiagnosticsProviding, @unchecked Sendable {
    private let exporter: AppDiagnosticsExporter

    init(exporter: AppDiagnosticsExporter) {
        self.exporter = exporter
    }

    func diagnostics() async -> SettingsDiagnosticsSnapshot {
        await MainActor.run {
            SettingsDiagnosticsSnapshot(
                entries: exporter.entries.map { entry in
                    SettingsDiagnosticEntry(
                        id: String(entry.id),
                        code: entry.code,
                        message: entry.message,
                        timestamp: entry.timestamp
                    )
                }
            )
        }
    }
}
