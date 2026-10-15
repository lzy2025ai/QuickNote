import AppKit
import SwiftUI

// MARK: - 「素笺」视觉语言：米白纸、墨色字、朱砂点缀；深色模式自动切到墨色笺

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 随系统浅色 / 深色自动切换的颜色
    static func paper(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

enum Palette {
    static let sidebarNS = NSColor.paper(0xECE3D1, 0x171512)
    static let listNS = NSColor.paper(0xF4EEE2, 0x1B1915)
    static let paperNS = NSColor.paper(0xFAF6EE, 0x211E1A)
    static let inkNS = NSColor.paper(0x23201B, 0xECE5D6)
    static let ink2NS = NSColor.paper(0x4A443A, 0xC9C0B0)
    static let mutedNS = NSColor.paper(0x6B6355, 0xA79E8E)
    static let faintNS = NSColor.paper(0xC2B49B, 0x5C554A)
    static let lineNS = NSColor.paper(0xE2D8C4, 0x2E2A24)
    static let fieldNS = NSColor.paper(0xEAE2D2, 0x2A2620)
    static let sealNS = NSColor.paper(0xB23E2A, 0xD0573F)
    static let tagNS = NSColor.paper(0x9E3A27, 0xE58B72)

    /// 侧栏
    static let sidebar = Color(nsColor: sidebarNS)
    /// 笔记列表栏
    static let list = Color(nsColor: listNS)
    /// 编辑区纸面 / 选中卡片
    static let paper = Color(nsColor: paperNS)
    /// 主文字（墨）
    static let ink = Color(nsColor: inkNS)
    /// 摘要、正文次级
    static let ink2 = Color(nsColor: ink2NS)
    /// 辅助信息
    static let muted = Color(nsColor: mutedNS)
    /// Markdown 符号、分隔点
    static let faint = Color(nsColor: faintNS)
    /// 分隔线
    static let line = Color(nsColor: lineNS)
    /// 搜索框、浅底块
    static let field = Color(nsColor: fieldNS)
    /// 朱砂（品牌色）
    static let seal = Color(nsColor: sealNS)
    /// 标签文字
    static let tag = Color(nsColor: tagNS)
    /// 字段的点状引线
    static let leader = Color(nsColor: .paper(0xCDBFA6, 0x4A443A))
    /// 印章上的字
    static let onSeal = Color(nsColor: .paper(0xFAF6EE, 0x1C1A17))
    /// 深色按钮（浅色模式下是墨色，深色模式下是纸色）
    static let button = Color(nsColor: .paper(0x23201B, 0xECE5D6))
    static let onButton = Color(nsColor: .paper(0xFAF6EE, 0x1C1A17))
    /// 已保存的小圆点
    static let saved = Color(nsColor: .paper(0x5E6E33, 0x9DAE6A))
    /// 卡片阴影
    static let shadow = Color(nsColor: .paper(0x463219, 0x000000)).opacity(0.10)
}

enum Fonts {
    /// 宋体（系统自带 Songti SC），用于标题、正文
    static func song(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let manager = NSFontManager.shared
        if let font = manager.font(withFamily: "Songti SC", traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// 衬线数字（系统自带 New York），用于日期、计数、电话
    static func numeral(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }
}

extension Font {
    static func song(_ size: CGFloat, bold: Bool = false) -> Font {
        Font(Fonts.song(size, bold: bold) as CTFont)
    }

    static func numeral(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// 统一的间距
enum Metrics {
    static let sidebarWidth: CGFloat = 216
    static let listWidth: CGFloat = 330
    /// 编辑区左右留白；正文 NSTextView 的 inset + lineFragmentPadding 与之对齐
    static let editorInset: CGFloat = 64
    static let textViewInset: CGFloat = editorInset - 5
    /// 编辑区内容最大宽度（含留白）
    static let readableWidth: CGFloat = 720
    /// 窗口顶部为红绿灯留出的高度
    static let titlebarHeight: CGFloat = 40
}

enum Typography {
    static let rowTitle = Font.system(size: 14, weight: .bold)
    static let rowDetail = Font.system(size: 12.5)
    static let meta = Font.system(size: 11.5)
    static let sectionLabel = Font.system(size: 11)
}

/// 统一的过渡动画
enum Motion {
    static let standard = Animation.easeInOut(duration: 0.2)
    static let quick = Animation.easeOut(duration: 0.15)
}

enum ChineseDate {
    private static let months = ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]
    private static let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    static func day(_ date: Date) -> String {
        String(format: "%02d", Calendar.current.component(.day, from: date))
    }

    static func month(_ date: Date) -> String {
        months[Calendar.current.component(.month, from: date) - 1]
    }

    static func weekday(_ date: Date) -> String {
        weekdays[Calendar.current.component(.weekday, from: date) - 1]
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 时间线上的分组标题：今日 / 昨日 / 十月十二日
    static func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今日" }
        if cal.isDateInYesterday(date) { return "昨日" }
        let d = cal.component(.day, from: date)
        return month(date) + "\(d)日"
    }
}

/// 分节小标题：小号、字距放宽
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typography.sectionLabel)
            .tracking(4)
            .foregroundStyle(Palette.muted)
    }
}

/// 项目印章：方形色块里写项目名第一个字
struct ProjectSeal: View {
    let project: Project
    var size: CGFloat = 22

    var body: some View {
        Text(String(project.name.prefix(1)))
            .font(.song(size * 0.55, bold: true))
            .foregroundStyle(Palette.onSeal)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).fill(project.tint))
    }
}

/// App 标志：「素纸」图标的缩小版——米白纸片上两笔墨线和一个朱砂点
struct AppMark: View {
    var size: CGFloat = 30

    var body: some View {
        let unit = size / 30
        VStack(alignment: .leading, spacing: 4 * unit) {
            Capsule().fill(Color(nsColor: NSColor(hex: 0x23201B))).frame(height: 3 * unit)
            HStack(spacing: 3 * unit) {
                Capsule().fill(Color(nsColor: NSColor(hex: 0x23201B))).frame(width: 11 * unit, height: 3 * unit)
                Circle().fill(Color(nsColor: NSColor(hex: 0xB23E2A))).frame(width: 3.4 * unit, height: 3.4 * unit)
            }
        }
        .padding(.horizontal, 6 * unit)
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 8 * unit, style: .continuous).fill(Color(nsColor: NSColor(hex: 0xFBF8F1))))
        .shadow(color: Color.black.opacity(0.14), radius: 2.5 * unit, y: 1 * unit)
        .overlay(RoundedRectangle(cornerRadius: 8 * unit, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
    }
}

/// 点状引线（字段名与内容之间）
struct DottedLeader: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(Palette.leader, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
        .frame(height: 2)
    }
}

/// 自动换行排列（标签云等）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension View {
    /// macOS 14+ 去掉可聚焦容器的系统焦点框
    @ViewBuilder
    func hideFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
