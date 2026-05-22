import SwiftUI
import UniformTypeIdentifiers

struct ScriptManagerView: View {
    @EnvironmentObject var scripts: ScriptStore
    @EnvironmentObject var sources: SourceManager
    @State private var showImport = false
    @State private var importMode: ImportMode = .url
    @State private var inputText: String = ""
    @State private var isLoading = false
    @State private var error: String?

    enum ImportMode: String, CaseIterable, Identifiable {
        case url = "从 URL"
        case paste = "从粘贴"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if scripts.scripts.isEmpty {
                ContentUnavailableView(
                    "暂无自定义脚本",
                    systemImage: "doc.text",
                    description: Text("点击右上角 + 从 URL 或粘贴板导入 lx-music v4 用户脚本")
                )
            } else {
                ForEach(scripts.scripts) { script in
                    let isLoaded = sources.loadedScripts.contains { $0.script.id == script.id }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(script.name).font(.headline)
                            Spacer()
                            if isLoaded {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            }
                        }
                        if !script.description.isEmpty {
                            Text(script.description).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        Text("v\(script.version) · \(script.author)").font(.caption2).foregroundColor(.secondary)
                        HStack {
                            Toggle("启用", isOn: Binding(
                                get: { script.enabled },
                                set: { newValue in
                                    scripts.toggle(script.id, enabled: newValue)
                                    if newValue {
                                        Task { await sources.load(script: script) }
                                    } else {
                                        sources.unload(scriptID: script.id)
                                    }
                                }
                            ))
                            .labelsHidden()
                            Button("重新加载") {
                                Task { await sources.load(script: script) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { idx in
                    let ids = idx.map { scripts.scripts[$0].id }
                    for id in ids {
                        sources.unload(scriptID: id)
                        scripts.remove(id)
                    }
                }
            }
        }
        .navigationTitle("自定义音源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) {
            NavigationStack {
                Form {
                    Picker("方式", selection: $importMode) {
                        ForEach(ImportMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Section(importMode == .url ? "脚本 URL" : "脚本内容") {
                        TextEditor(text: $inputText)
                            .frame(minHeight: importMode == .url ? 60 : 200)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if let error {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                    Section {
                        Button(isLoading ? "导入中..." : "导入并加载") {
                            Task { await doImport() }
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                    }
                }
                .navigationTitle("导入脚本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showImport = false; reset() }
                    }
                }
            }
        }
    }

    private func reset() {
        inputText = ""
        error = nil
        isLoading = false
    }

    private func doImport() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let raw: String
            switch importMode {
            case .url:
                guard let url = URL(string: inputText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    error = "URL 无效"; return
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let s = String(data: data, encoding: .utf8) else {
                    error = "无法以 UTF-8 解码"; return
                }
                raw = s
            case .paste:
                raw = inputText
            }
            let script = ScriptStore.parseMetadata(from: raw)
            scripts.add(script)
            await sources.load(script: script)
            showImport = false
            reset()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
