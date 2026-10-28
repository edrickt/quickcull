import SwiftUI
import QuickCullCore
import UniformTypeIdentifiers

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 20) {
            if !appState.importFailures.isEmpty {
                ImportFailuresBanner(failures: appState.importFailures,
                                     onDismiss: { appState.dismissImportFailures() })
            }
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("QuickCull")
                .font(.largeTitle.bold())
            Text("Select photos to start culling.")
                .foregroundStyle(.secondary)
            Button("Choose Files…") { showImporter = true }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("RAW · JPEG · PNG · HEIC — Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Leica, Pentax and more")
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
}
