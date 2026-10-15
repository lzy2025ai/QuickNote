import AppKit
import SwiftUI

enum ProjectColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .mint: return "薄荷"
        case .teal: return "青色"
        case .blue: return "蓝色"
        case .indigo: return "靛蓝"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .brown: return "棕色"
        case .gray: return "灰色"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .brown: return .systemBrown
        case .gray: return .systemGray
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
    var tint: Color { projectColor?.color ?? .accentColor }
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
