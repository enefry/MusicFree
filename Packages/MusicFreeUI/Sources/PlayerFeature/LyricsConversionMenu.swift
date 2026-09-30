import DesignSystem
import MusicDomain
import UIKit

@MainActor
enum LyricsConversionMenu {
    static func title(for script: LyricsScript) -> String {
        switch script {
        case .simplified: L("转为简体")
        case .traditional: L("转为繁体")
        }
    }

    static func make(
        offsetTitle: String = "",
        offsetActions: [UIAction],
        convert: @escaping @MainActor (LyricsScript) -> Void
    ) -> UIMenu {
        UIMenu(children: [
            UIMenu(title: "", options: .displayInline, children: [
                UIAction(
                    title: title(for: .simplified),
                    identifier: UIAction.Identifier("lyrics.convert.simplified")
                ) { _ in convert(.simplified) },
                UIAction(
                    title: title(for: .traditional),
                    identifier: UIAction.Identifier("lyrics.convert.traditional")
                ) { _ in convert(.traditional) }
            ]),
            UIMenu(title: offsetTitle, options: .displayInline, children: offsetActions)
        ])
    }
}
