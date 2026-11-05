import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LayoutManagerView: View {
    let workspace: HiveWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var previewData: Data?
    @State private var previewText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "rectangle.3.group",
                title: "Workspace layouts",
                subtitle: "Export the current Hive workspace or preview a layout file before applying it.",
                onClose: { dismiss() }
            )
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    layoutAction("Export workspace", detail: "Save every environment and tab to a file.", symbol: "square.and.arrow.up") {
                        Task { await exportLayout() }
                    }
                    layoutAction("Preview a layout", detail: "Open a layout file and check it before applying.", symbol: "doc.text.magnifyingglass") {
                        showingImporter = true
                    }
                }
                .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                if let errorMessage { HiveNotice(text: errorMessage) }
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .frame(width: 540, height: 260)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: errorMessage)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [UTType(filenameExtension: "json") ?? .json, .plainText]) { result in
            if case .success(let url) = result { loadPreview(url) }
        }
        .sheet(isPresented: Binding(get: { previewData != nil }, set: { if !$0 { previewData = nil } })) {
            layoutPreview
        }
    }

    private func layoutAction(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.hiveAmber)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hiveAmber.opacity(0.14)))
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .hiveCard(padding: 12, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var layoutPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "doc.text.magnifyingglass",
                title: "Preview layout",
                subtitle: "Applying adds the environments and tabs from this file. Existing tabs are kept.",
                onClose: { previewData = nil }
            )
            VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(previewText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 300)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            HStack {
                Spacer()
                Button("Cancel") { previewData = nil }
                    .buttonStyle(.hive)
                Button { Task { await applyLayout() } } label: { Label("Apply Layout", systemImage: "checkmark") }
                    .buttonStyle(.hivePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            }
            .padding(20)
        }
        .frame(width: 640, height: 540)
    }

    private func loadPreview(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let raw = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: raw)
            guard let dict = object as? [String: Any], dict["version"] != nil, dict["environments"] != nil else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This file does not look like a Hive layout."])
            }
            previewData = raw
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            previewText = String(decoding: pretty, as: UTF8.self)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func exportLayout() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await workspace.exportLayout()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "hive-layout.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyLayout() async {
        guard let previewData else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await workspace.applyLayout(previewData)
            self.previewData = nil
            errorMessage = nil
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
