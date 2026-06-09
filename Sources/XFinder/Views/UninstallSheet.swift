import SwiftUI
import AppKit

/// AppCleaner-style uninstall dialog: lists the app's related files with checkboxes so the user can
/// pick what to remove, shows the total selected size, and moves the chosen items to the Trash.
struct UninstallSheet: View {
    let appItem: FileItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var files: [AppRelatedFile] = []
    @State private var checked: Set<URL> = []
    @State private var loading = true

    private var selectedSize: Int64 {
        files.filter { checked.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 580)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appItem.url.path))
                .resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(appItem.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                if loading {
                    Text("관련 파일을 찾는 중…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("\(files.count)개 파일")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        Text(Format.size(selectedSize, isDirectory: false))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        row(file)
                        if index < files.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func row(_ file: AppRelatedFile) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: bind(file)).toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if file.isApp {
                        Text("앱").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                }
                Text(file.displayPath)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Format.size(file.size, isDirectory: false))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Button { SystemActions.reveal(file.url) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Finder에서 보기")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { bind(file).wrappedValue.toggle() }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("모두 선택") { checked = Set(files.map(\.url)) }
                .disabled(loading || checked.count == files.count)
            Button("모두 해제") { checked = [] }
                .disabled(loading || checked.isEmpty)
            Spacer()
            Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("삭제 (\(checked.count))") { remove() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(checked.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Logic

    private func bind(_ file: AppRelatedFile) -> Binding<Bool> {
        Binding(
            get: { checked.contains(file.url) },
            set: { on in if on { checked.insert(file.url) } else { checked.remove(file.url) } }
        )
    }

    private func load() async {
        let url = appItem.url
        let result = await Task.detached(priority: .userInitiated) {
            AppUninstaller.relatedFiles(for: url)
        }.value
        files = result
        checked = Set(result.map(\.url))   // everything checked by default, like AppCleaner
        loading = false
    }

    private func remove() {
        let urls = files.filter { checked.contains($0.url) }.map(\.url)
        dismiss()
        app.performUninstall(urls)
    }
}
