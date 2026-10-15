import SwiftUI

/// 统一的间距与字体。所有界面都从这里取值，保证节奏一致（4pt 网格，字体用系统文字样式）。
enum Metrics {
    /// 编辑器左右留白；与正文 NSTextView 的 inset + lineFragmentPadding 对齐，标题和正文左边缘完全齐平
    static let editorInset: CGFloat = 28
    static let textViewInset: CGFloat = editorInset - 5
    /// 编辑器内容最大宽度，宽窗口下保持舒适的行长
    static let readableWidth: CGFloat = 760
    static let rowVerticalPadding: CGFloat = 6
}

enum Typography {
    /// 编辑器标题
    static let editorTitle = Font.title.weight(.bold)
    /// 列表行标题
    static let rowTitle = Font.headline
    /// 列表行第二行（日期 + 摘要）
    static let rowDetail = Font.callout
    /// 辅助信息（项目、标签、来源）
    static let meta = Font.caption
}

/// 统一的过渡动画
enum Motion {
    static let standard = Animation.easeInOut(duration: 0.2)
    static let quick = Animation.easeOut(duration: 0.15)
}
