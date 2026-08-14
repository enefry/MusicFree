import DesignSystem
import SwiftUI

struct LicenseDetailView: View {
    let dependency: SettingsDependencyLicense

    var body: some View {
        Form {
            Section(L("依赖")) {
                LabeledContent(L("名称"), value: dependency.name)
                if let version = nonEmpty(dependency.version) {
                    LabeledContent(L("版本"), value: version)
                }
                if let license = nonEmpty(dependency.license) {
                    LabeledContent(L("许可"), value: license)
                }
                LabeledContent(L("类型"), value: kindTitle)
            }

            Section(L("材料")) {
                if let licenseFile = nonEmpty(dependency.licenseFile) {
                    LabeledContent(L("本地许可文件"), value: licenseFile)
                }
                if let revision = nonEmpty(dependency.revision) {
                    LabeledContent(L("源码修订"), value: revision)
                        .textSelection(.enabled)
                }
                if let checksum = nonEmpty(dependency.checksum) {
                    LabeledContent(L("二进制校验"), value: checksum)
                        .textSelection(.enabled)
                }
                if let sourceURL = dependency.sourceURL {
                    Link(destination: sourceURL) {
                        Label(L("源码"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                if let buildMaterialsURL = dependency.buildMaterialsURL {
                    Link(destination: buildMaterialsURL) {
                        Label(L("构建材料"), systemImage: "shippingbox")
                    }
                }
                if let licenseURL = dependency.licenseURL {
                    Link(destination: licenseURL) {
                        Label(L("在线许可全文"), systemImage: "doc.text")
                    }
                }
                if dependency.sourceURL == nil,
                   dependency.buildMaterialsURL == nil,
                   dependency.licenseURL == nil,
                   nonEmpty(dependency.licenseFile) == nil,
                   nonEmpty(dependency.revision) == nil,
                   nonEmpty(dependency.checksum) == nil {
                    Text(L("未提供材料链接"))
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }

            if let licenseText = nonEmpty(dependency.licenseText) {
                Section(L("许可全文")) {
                    ScrollView(.vertical) {
                        Text(licenseText)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, MusicFreeSpacingTokens.small)
                    }
                    .frame(minHeight: 240, maxHeight: 480)
                }
            }
        }
        .navigationTitle(dependency.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var kindTitle: String {
        switch dependency.kind {
        case .source:
            return L("源码")
        case .binary:
            return L("二进制")
        case .other:
            return L("其他")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
