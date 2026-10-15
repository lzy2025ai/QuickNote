import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var selection: SidebarItem?
    @Binding var showNewProject: Bool

    @State private var editingProject: Project?
    @State private var deletingProject: Project?
    @State private var renamingTag: String?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 红绿灯下方的标志
            HStack(spacing: 11) {
                AppMark(size: 28)
                Text("随手记")
                    .font(.song(19))
                    .tracking(6)
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 20)
            .padding(.top, Metrics.titlebarHeight + 6)
            .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 1) {
                        row(.all) { icon("note.text") } label: { "全部笔记" }
                        row(.inbox) { icon("tray") } label: { "收件箱" }
                        row(.clipboard) { icon("list.clipboard") } label: { "剪贴板" }
                    }

                    if !store.projects.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("项目").padding(.horizontal, 10).padding(.bottom, 4)
                            ForEach(store.projects) { p in
                                row(.project(p.id)) { ProjectSeal(project: p) } label: { p.name }
                                    .contextMenu {
                                        Button("编辑项目…") { editingProject = p }
                                        ProjectColorMenu(project: p)
                                        Button("导出为 Markdown…") {
                                            MarkdownExporter.exportNotes(store.notes(for: .project(p.id)), title: p.name, store: store)
                                        }
                                        Divider()
                                        Button("删除项目…", role: .destructive) { deletingProject = p }
                                    }
                            }
                        }
                    }

                    let tags = store.allTags
                    if !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("标签").padding(.horizontal, 10)
                            FlowLayout(spacing: 12, lineSpacing: 6) {
                                ForEach(tags, id: \.name) { t in
                                    tagButton(t.name)
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            // 与“备忘录”的“新建文件夹”一样放在侧栏底部
            VStack(alignment: .leading, spacing: 6) {
                if !store.syncStatus.isEmpty {
                    Label(store.syncStatus, systemImage: store.isICloud ? "icloud" : "externaldrive")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Button {
                    showNewProject = true
                } label: {
                    Label("新建项目", systemImage: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                }
                .buttonStyle(.plain)
                .help("新建项目（⇧⌘N）")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .sheet(item: $editingProject) { p in
            ProjectEditSheet(project: p).environmentObject(store)
        }
        .alert(
            "删除项目“\(deletingProject?.name ?? "")”？",
            isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
            presenting: deletingProject
        ) { p in
            Button("删除", role: .destructive) {
                if selection == .project(p.id) { selection = .all }
                store.deleteProject(p.id)
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            Text("项目内的 \(store.noteCount(.project(p.id))) 则笔记会移到收件箱，不会被删除。")
        }
        .alert(
            "重命名标签",
            isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })
        ) {
            TextField("标签名", text: $renameText)
            Button("确定") {
                if let old = renamingTag {
                    let new = Store.normalizeTag(renameText)
                    store.renameTag(old, to: new)
                    if selection == .tag(old), !new.isEmpty { selection = .tag(new) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(Palette.muted)
            .frame(width: 22, height: 22)
    }

    private func row<Icon: View>(_ item: SidebarItem, @ViewBuilder icon: () -> Icon, label: () -> String) -> some View {
        SidebarRow(selected: selection == item, count: store.noteCount(item), icon: icon(), title: label()) {
            selection = item
        }
    }

    private func tagButton(_ name: String) -> some View {
        Button {
            selection = .tag(name)
        } label: {
            Text("#" + name)
                .font(.system(size: 13, weight: selection == .tag(name) ? .semibold : .regular))
                .foregroundStyle(Palette.tag)
                .underline(selection == .tag(name), color: Palette.tag.opacity(0.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名…") {
                renameText = name
                renamingTag = name
            }
            Button("导出为 Markdown…") {
                MarkdownExporter.exportNotes(store.notes(for: .tag(name)), title: "#" + name, store: store)
            }
            Divider()
            Button("删除标签", role: .destructive) {
                if selection == .tag(name) { selection = .all }
                store.deleteTag(name)
            }
        }
    }
}

/// 侧栏的一行：选中时像一张浮起的纸片
private struct SidebarRow<Icon: View>: View {
    let selected: Bool
    let count: Int
    let icon: Icon
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                Text(title)
                    .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.numeral(14))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Palette.paper : (hovering ? Palette.paper.opacity(0.4) : Color.clear))
                    .shadow(color: selected ? Palette.shadow : .clear, radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }
}

struct ProjectEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let project: Project?
    var onCreate: ((Project) -> Void)?

    @State private var name = ""
    @State private var color: ProjectColor?

    /// 预览用：把当前输入组装成一个临时项目
    private var preview: Project {
        Project(name: name.isEmpty ? "项" : name, color: color?.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProjectSeal(project: preview, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project == nil ? "新建项目" : "编辑项目")
                        .font(.song(18, bold: true))
                        .foregroundStyle(Palette.ink)
                    Text("印章上是项目名的第一个字")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }

            TextField("项目名称，例如：乐享户外 / 装修 / 求职", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("印色")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 9), alignment: .leading, spacing: 8) {
                    colorDot(nil)
                    ForEach(ProjectColor.allCases) { colorDot($0) }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Palette.paper)
        .onAppear {
            if let project {
                name = project.name
                color = project.projectColor
            }
        }
    }

    private func colorDot(_ c: ProjectColor?) -> some View {
        Button {
            withAnimation(Motion.quick) { color = c }
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(c?.color ?? Palette.seal)
                .frame(width: 22, height: 22)
                .overlay {
                    if color == c {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.onSeal)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(c?.title ?? "朱砂（默认）")
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if var p = project {
            p.name = trimmed
            p.color = color?.rawValue
            store.updateProject(p)
        } else {
            let p = store.addProject(name: trimmed, icon: "folder", color: color?.rawValue)
            onCreate?(p)
        }
        dismiss()
    }
}
