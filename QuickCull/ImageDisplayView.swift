import SwiftUI
import QuickCullCore

struct ImageDisplayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let index = appState.session?.currentIndex ?? 0
        // Resolve the current file HERE, guarded: `files` shrinks on commit
        // and on filter drop-outs, and a child view re-evaluated with a
        // captured index would trap on `files[index]` (crash). Passing the
        // file — not the index — keeps the badge lookup safe and
        // id-based, like the filmstrip cells.
        let currentFile = (appState.session?.files.indices.contains(index) ?? false)
            ? appState.session?.files[index]
            : nil
        ZStack {
            Color.black
            if appState.session?.files.isEmpty == true {
                // Filter matches nothing (Flagged 0 or Keepers 0) — nothing to load, show empty black instead of spinner
                Color.black
            } else if let image = appState.displayImages?.image(at: index) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
            } else if let thumb = appState.thumbWindow?.image(at: index) {
                // The display-size decode (~100-400 ms for a 45 MP cache
                // entry) lags fast scrubbing. Show the already-resident
                // same-index thumbnail upscaled so the current photo is
                // visible immediately; the sharp image replaces it when the
                // decode lands. Same index = same photo, never a wrong image.
                // The badge must render here too: a marked photo shown
                // without its badge reads as unflagged.
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .topTrailing) { FlagBadgeOverlay(file: currentFile) }
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }
}

/// The reject-flag badge for the current photo, pinned to the image's own
/// corner so it follows the image bounds even when letterboxed.
/// Uses `FlagBadgeLogic.shouldShow` — badge belongs to photo, not container.
private struct FlagBadgeOverlay: View {
    let file: SessionFile?
    @Environment(AppState.self) private var appState

    var body: some View {
        if let file {
            let isFlagged = appState.session?.isFlagged(file) == true
            // hasImage is true here: overlay exists only on the Image branch (display or thumb), never on ProgressView
            if FlagBadgeLogic.shouldShow(isFlagged: isFlagged, hasImage: true) {
                FlagBadge(size: 44)
            }
        }
    }
}
