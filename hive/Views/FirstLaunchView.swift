import AppKit
import Foundation
import SwiftUI

struct FirstLaunchView: View {
    @ObservedObject var viewModel: FirstLaunchViewModel

    private let amber = Color(red: 0.961, green: 0.725, blue: 0.259)
    private let installGuide = URL(string: "https://hive.admir-saheta.com/docs/getting-started/installation")!

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(spacing: 15) {
                Image("HiveBee")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 58, height: 52)

                Text("Hive needs its runtime.")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .tracking(-0.35)
                    .foregroundStyle(.primary)
            }

            Text("The Hive app uses the Hive runtime to keep your agents running. We couldn’t confirm it’s installed on this Mac.")
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Install it for me", action: viewModel.installHive)
                    .buttonStyle(.hivePrimary)
                    .disabled(viewModel.state == .installing || viewModel.state == .checking)

                Button("I have it somewhere…", action: chooseHiveBinary)
                    .buttonStyle(.hive)
                    .disabled(viewModel.state == .installing || viewModel.state == .checking)
            }

            statusMessage

            Link("hive.admir-saheta.com", destination: installGuide)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: 510, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 500)
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch viewModel.state {
        case .checking:
            Label("Checking for Hive…", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
        case .installing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installing Hive…")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(amber)
                }
            }
        case .failed(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(Color(red: 1, green: 0.68, blue: 0.43))
        case .needsInstall, .installed:
            EmptyView()
        }
    }

    private func chooseHiveBinary() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Hive executable"
        panel.message = "Select the installed Hive command-line executable."
        panel.prompt = "Choose Hive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.useHive(at: url)
    }
}

