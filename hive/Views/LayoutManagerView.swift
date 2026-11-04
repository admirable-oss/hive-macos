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
        VStack(alignment: .leading, spacing: 16) {
            Text("Workspace layouts").font(.title2.weight(.semibold))
            Text("Export the current Hive workspace or preview a layout file before applying it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { Task { await exportLayout() } } label: {
                    Label("Export current workspace…", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking)
                Button { showingImporter = true } label: {
                    Label("Choose layout to preview…", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(isWorking)
            }
            if isWorking { ProgressView().controlSize(.small) }
            if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 520, height: 220)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [UTType(filenameExtension: "json") ?? .json, .plainText]) { result in
            if case .success(let url) = result { loadPreview(url) }
        }
        .sheet(isPresented: Binding(get: { previewData != nil }, set: { if !$0 { previewData = nil } })) {
            layoutPreview
        }
    }

    private var layoutPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview layout").font(.title2.weight(.semibold))
            Text("Applying adds the environments and tabs from this file. Existing tabs are kept.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(previewText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 300)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { previewData = nil }.keyboardShortcut(.cancelAction)
                Button("Apply Layout") { Task { await applyLayout() } }
                    .buttonStyle(.borderedProminent).disabled(isWorking)
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
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
