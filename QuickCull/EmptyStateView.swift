import SwiftUI
import QuickCullCore
import UniformTypeIdentifiers

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 20) {
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
}
