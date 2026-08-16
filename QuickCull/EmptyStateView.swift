import SwiftUI
import QuickCullCore
import UniformTypeIdentifiers

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 20) {
            if !appState.importFailures.isEmpty {
                importFailuresBanner
            }
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("QuickCull")
                .font(.largeTitle.bold())
            Text("Select raw files from any camera to start culling.")
                .foregroundStyle(.secondary)
            Button("Choose RAW Files…") { showImporter = true }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("Canon · Nikon · Sony · Fujifilm · Olympus · Panasonic · Leica · Pentax · more")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.importFiles(urls: urls)
            }
        }
    }

    /// Same dismissible banner as ScrubView: surfaces failed decodes (and
    /// all-unsupported imports) from the empty state.
    private var importFailuresBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(importFailureSummary)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Dismiss") { appState.dismissImportFailures() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.15))
    }

    private var importFailureSummary: String {
        let names = appState.importFailures
            .prefix(3)
            .map { $0.file.url.lastPathComponent }
            .joined(separator: ", ")
        let count = appState.importFailures.count
        return count > 3
            ? "\(count) file(s) could not be decoded: \(names) …"
            : "\(count) file(s) could not be decoded: \(names)"
    }
}
