import AppKit
import SwiftUI

enum ProjectColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    /// 传统色名
    var title: String {
        switch self {
        case .red: return "朱砂"
        case .orange: return "橘红"
        case .yellow: return "缃黄"
        case .green: return "苔绿"
        case .mint: return "青瓷"
        case .teal: return "石青"
        case .blue: return "黛蓝"
        case .indigo: return "靛青"
        case .purple: return "紫檀"
        case .pink: return "胭脂"
        case .brown: return "赭石"
        case .gray: return "烟墨"
        }
    }

    /// 偏沉稳的矿物色；深色模式下提亮
    var nsColor: NSColor {
        switch self {
        case .red: return .paper(0xB23E2A, 0xD0573F)
        case .orange: return .paper(0xB8612B, 0xD98A52)
        case .yellow: return .paper(0xA8862C, 0xD4B45E)
        case .green: return .paper(0x5E6E33, 0x9DAE6A)
        case .mint: return .paper(0x4E7A62, 0x8DBB9F)
        case .teal: return .paper(0x3F6F75, 0x7FAFB4)
        case .blue: return .paper(0x3E5868, 0x6F93A8)
        case .indigo: return .paper(0x34466E, 0x7D90C2)
        case .purple: return .paper(0x6B4E6E, 0xAB8CAE)
        case .pink: return .paper(0xA2475E, 0xD7899B)
        case .brown: return .paper(0x96602A, 0xC9935A)
        case .gray: return .paper(0x6B6355, 0xA79E8E)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// 菜单里用的彩色圆点（非模板图，菜单不会把它染成黑白）
    var swatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension Project {
    var projectColor: ProjectColor? { color.flatMap(ProjectColor.init(rawValue:)) }
    var tint: Color { projectColor?.color ?? Palette.seal }
}

/// 项目图标（带项目颜色）
struct ProjectIcon: View {
    let project: Project

    var body: some View {
        Image(systemName: project.icon)
            .foregroundStyle(project.tint)
    }
}

/// 右键菜单 / 编辑面板共用的颜色子菜单
struct ProjectColorMenu: View {
    @EnvironmentObject var store: Store
    let project: Project

    var body: some View {
        Menu("颜色") {
            Button {
                setColor(nil)
            } label: {
                Label("默认", systemImage: project.color == nil ? "checkmark" : "circle")
            }
            Divider()
            ForEach(ProjectColor.allCases) { c in
                Button {
                    setColor(c)
                } label: {
                    Label {
                        Text(project.projectColor == c ? "✓ " + c.title : c.title)
                    } icon: {
                        Image(nsImage: c.swatch)
                    }
                }
            }
        }
    }

    private func setColor(_ c: ProjectColor?) {
        var p = project
        p.color = c?.rawValue
        store.updateProject(p)
    }
}
