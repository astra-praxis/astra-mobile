import SwiftUI

/// PC 项目文件浏览：经桥 fs_files / fs_read 转发到桌面前端
/// （list_project_files / agent_read_project_file），项目路径安全由后端校验。
/// 点行预览文本内容，工具栏「引用」把 @路径 塞回输入框由 Agent 自己 read_file。
struct PCFilesView: View {
    @EnvironmentObject var store: ShellStore
    @Environment(\.dismiss) private var dismiss
    @State private var files: [String] = []
    @State private var project: String?
    @State private var error: String?
    @State private var loading = false
    @State private var filter = ""

    /// 引用回调：把选中的相对路径回填到输入框
    let onQuote: (String) -> Void

    /// sheet(item:) 用的小包装（String 做 retroactive Identifiable 会有全局告警）
    private struct FilePath: Identifiable {
        let id: String
    }

    @State private var preview: FilePath?

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    errorView(error)
                } else if loading && files.isEmpty {
                    ProgressView("正在读取 PC 项目文件…")
                } else {
                    fileListView
                }
            }
            .navigationTitle("PC 项目文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        load()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
        }
        .onAppear { load() }
    }

    private var filtered: [String] {
        filter.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var fileListView: some View {
        List {
            if let project {
                // 项目根目录：手机端只展示相对路径，根路径仅作提示
                Text("项目：\(project)")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if filtered.isEmpty {
                Text(files.isEmpty ? "项目里没有文件" : "没有匹配的文件")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered, id: \.self) { path in
                    Button {
                        preview = FilePath(id: path)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $filter, prompt: "按路径过滤")
        .sheet(item: $preview) { item in
            PCFileContentView(store: store, path: item.id) { quoted in
                dismiss()
                onQuote(quoted)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { load() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        loading = true
        error = nil
        store.requestPCFiles { project, files, err in
            loading = false
            if let err {
                self.error = err
            } else {
                self.project = project
                self.files = files
            }
        }
    }
}

/// 单个文件预览：fs_read 拉文本（后端限 256KB、限项目内路径），等宽展示 + 引用
private struct PCFileContentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var error: String?
    @State private var loading = true

    let store: ShellStore
    let path: String
    let onQuote: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("读取中…")
                } else if let error {
                    ScrollView {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                } else if let content {
                    ScrollView {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onQuote(path)
                    } label: {
                        Label("引用", systemImage: "at")
                    }
                    .disabled(content == nil && error == nil)
                }
            }
        }
        .onAppear {
            store.requestPCFileContent(path: path) { _, text, err in
                loading = false
                if let err {
                    error = err
                } else {
                    content = text ?? ""
                }
            }
        }
    }
}
