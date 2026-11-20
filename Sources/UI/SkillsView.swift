import SwiftUI
import UniformTypeIdentifiers

/// 技能管理页。
///
/// 技能 = 一段可复用的「怎么做这件事」的提示词。启用后会被拼进系统提示词，
/// 因此它是**零执行风险**的扩展点：不会跑代码、不会碰文件，只是让模型多知道一点你的习惯。
public struct SkillsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var editing: SkillDefinition?
    @State private var isCreating = false
    @State private var showPasteImporter = false
    @State private var showFileImporter = false
    @State private var pendingDelete: SkillDefinition?

    public init() {}

    public var body: some View {
        List {
            if let error = environment.skills.lastError {
                Section {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("知道了") { environment.skills.clearError() }
                        .font(.callout)
                }
            }

            Section {
                if environment.skills.skills.isEmpty {
                    ContentUnavailableView {
                        Label("还没有技能", systemImage: "lightbulb")
                    } description: {
                        Text("把「每次都要跟 Agent 重复说一遍」的要求存成技能。")
                    }
                } else {
                    ForEach(environment.skills.skills) { skill in
                        row(for: skill)
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first else { return }
                        pendingDelete = environment.skills.skills[index]
                    }
                }
            } header: {
                Text("技能")
            } footer: {
                Text("技能只会拼进系统提示词，不会执行任何代码。关掉开关只是不注入，定义仍然保留。")
            }
        }
        .navigationTitle("技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isCreating = true
                    } label: {
                        Label("新建技能", systemImage: "square.and.pencil")
                    }
                    Button {
                        showPasteImporter = true
                    } label: {
                        Label("粘贴 Markdown 导入", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            SkillEditorView(skill: SkillDefinition(name: "", summary: "", instructions: ""), isNew: true)
        }
        .sheet(item: $editing) { skill in
            SkillEditorView(skill: skill, isNew: false)
        }
        .sheet(isPresented: $showPasteImporter) {
            SkillPasteImporter()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.markdown, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("删除这个技能？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let skill = pendingDelete {
                    environment.skills.remove(id: skill.id)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
    }

    // MARK: - 行

    private func row(for skill: SkillDefinition) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                editing = skill
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !skill.summary.isEmpty {
                        Text(skill.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(skill.instructions.count) 字")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { skill.isEnabled },
                set: { environment.skills.setEnabled($0, id: skill.id) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - 文件导入

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if let skill = SkillStore.parse(markdown: text) {
                    _ = environment.skills.upsert(skill)
                } else {
                    environment.skills.reportError("这个文件里没有可用的技能正文。")
                }
            } catch {
                environment.skills.reportError("读取技能文件失败：\(error.localizedDescription)")
            }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                return
            }
            environment.skills.reportError("打开技能文件失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 编辑

struct SkillEditorView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SkillDefinition
    @State private var validationError: String?

    let isNew: Bool

    init(skill: SkillDefinition, isNew: Bool) {
        _draft = State(initialValue: skill)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称，例如 提交信息规范", text: $draft.name)
                    TextField("一句话说明（可留空）", text: $draft.summary)
                }

                Section {
                    TextEditor(text: $draft.instructions)
                        .frame(minHeight: 220)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("技能正文")
                } footer: {
                    Text("写「怎么做」的指令，会被原样拼进系统提示词。建议写成可执行的步骤或约束，例如：所有提交信息使用 Conventional Commits，正文用中文。")
                }

                Section {
                    Toggle("启用", isOn: $draft.isEnabled)
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "新建技能" : "编辑技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        guard draft.isValid else {
            validationError = "技能需要名称，正文不能为空。"
            return
        }
        if environment.skills.upsert(draft) {
            dismiss()
        } else {
            validationError = environment.skills.lastError ?? "保存失败，请重试。"
        }
    }
}

// MARK: - 粘贴导入

struct SkillPasteImporter: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("粘贴 Markdown")
                } footer: {
                    Text("支持最简 front matter：`---` 之间的 `name:` 与 `description:`；没有时用第一个 `# 标题` 当名字，整个正文作为技能内容。")
                }

                if let message {
                    Section {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("导入技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importSkill() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func importSkill() {
        guard let skill = SkillStore.parse(markdown: text) else {
            message = "解析失败：正文是空的。"
            return
        }
        if environment.skills.upsert(skill) {
            dismiss()
        } else {
            message = environment.skills.lastError ?? "保存失败，请重试。"
        }
    }
}