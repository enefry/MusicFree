import Foundation

#if DEBUG && canImport(LookinServer)
import UIKit

private enum LookinIgnore {
    static let classNames = [
        "_UIFloatingBarContainerView",
    ]

    static let classes: [AnyClass] = classNames.compactMap {
        NSClassFromString($0)
    }
}

extension NSObject {
    /// 不抓取这些 View 的图像
    @objc
    class func lookin_shouldCaptureImageOfView(_ view: UIView) -> Bool {
        !LookinIgnore.classes.contains {
            view.isKind(of: $0)
        }
    }

    /// 默认折叠这些 View 的内部层级
    @objc
    class func lookin_collapsedClassList() -> [String] {
        LookinIgnore.classNames
    }
}
#endif
