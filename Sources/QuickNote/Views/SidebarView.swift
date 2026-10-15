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
        List(selection: $selection) {
            Section("资料库") {
                row("全部笔记", icon: "note.text", item: .all)
                row("收件箱", icon: "tray", item: .inbox)
                row("剪贴板历史", icon: "list.clipboard", item: .clipboard)
            }

            if !store.projects.isEmpty {
                Section("项目") {
                    ForEach(store.projects) { p in
                        Label { Text(p.name) } icon: { ProjectIcon(project: p) }
                            .badge(store.noteCount(.project(p.id)))
                            .tag(SidebarItem.project(p.id))
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
                    .onMove { store.moveProjects(from: $0, to: $1) }
                }
            }

            let tags = store.allTags
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags, id: \.name) { t in
                        Label(t.name, systemImage: "number")
                            .badge(t.count)
                            .tag(SidebarItem.tag(t.name))
                            .contextMenu {
                                Button("重命名…") {
                                    renameText = t.name
                                    renamingTag = t.name
                                }
                                Button("导出为 Markdown…") {
                                    MarkdownExporter.exportNotes(store.notes(for: .tag(t.name)), title: "#" + t.name, store: store)
                                }
                                Divider()
                                Button("删除标签", role: .destructive) {
                                    if selection == .tag(t.name) { selection = .all }
                                    store.deleteTag(t.name)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 与“备忘录”的“新建文件夹”一样放在侧栏底部
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !store.syncStatus.isEmpty {
                    Label(store.syncStatus, systemImage: store.isICloud ? "icloud" : "externaldrive")
                        .font(Typography.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    showNewProject = true
                } label: {
                    Label("新建项目", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("新建项目（⇧⌘N）")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
            Text("项目内的 \(store.noteCount(.project(p.id))) 条笔记会移到收件箱，不会被删除。")
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

    private func row(_ title: String, icon: String, item: SidebarItem) -> some View {
        Label(title, systemImage: icon)
            .badge(store.noteCount(item))
            .tag(item)
    }
}

struct ProjectEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let project: Project?
    var onCreate: ((Project) -> Void)?

    @State private var name = ""
    @State private var icon = "folder"
    @State private var color: ProjectColor?

    private let icons = [
        "folder", "briefcase", "person.2", "building.2", "cart", "creditcard",
        "star", "flag", "bookmark", "lightbulb", "hammer", "wrench.and.screwdriver",
        "doc.text", "phone", "envelope", "globe", "heart", "house",
        "graduationcap", "airplane", "camera", "music.note", "gamecontroller", "leaf",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project == nil ? "新建项目" : "编辑项目").font(.headline)

            TextField("项目名称，例如：XX 客户 / 装修 / 求职", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            Text("颜色").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                colorDot(nil)
                ForEach(ProjectColor.allCases) { colorDot($0) }
            }

            Text("图标").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                ForEach(icons, id: \.self) { name in
                    Button {
                        icon = name
                    } label: {
                        Image(systemName: name)
                            .foregroundStyle(color?.color ?? .accentColor)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(icon == name ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
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
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let project {
                name = project.name
                icon = project.icon
                color = project.projectColor
            }
        }
    }

    private func colorDot(_ c: ProjectColor?) -> some View {
        Button {
            color = c
        } label: {
            Circle()
                .fill(c?.color ?? .accentColor)
                .frame(width: 18, height: 18)
                .overlay {
                    if color == c {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(c?.title ?? "默认")
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if var p = project {
            p.name = trimmed
            p.icon = icon
            p.color = color?.rawValue
            store.updateProject(p)
        } else {
            let p = store.addProject(name: trimmed, icon: icon, color: color?.rawValue)
            onCreate?(p)
        }
        dismiss()
    }
}
