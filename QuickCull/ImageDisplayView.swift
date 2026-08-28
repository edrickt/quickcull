import SwiftUI
import QuickCullCore
#if canImport(AppKit)
import AppKit
#endif

struct ImageDisplayView: View {
    @Environment(AppState.self) private var appState
    @Binding var zoomScale: CGFloat
    @Binding var zoomLastScale: CGFloat
    @Binding var zoomOffset: CGSize
    @Binding var zoomLastOffset: CGSize
    @Binding var hudVisible: Bool

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
        let rightIndex = index + 1
        let rightFile: SessionFile? = (appState.session?.files.indices.contains(rightIndex) ?? false)
            ? appState.session?.files[rightIndex]
            : nil
        let leftCG = appState.displayImages?.image(at: index) ?? appState.thumbWindow?.image(at: index)
        let rightCG = rightFile != nil ? (appState.displayImages?.image(at: rightIndex) ?? appState.thumbWindow?.image(at: rightIndex)) : nil

        ZStack {
            Color.black
            if appState.session?.files.isEmpty == true {
                // Filter matches nothing (Flagged 0 or Unflagged 0) — nothing to load, show empty black instead of spinner
                Color.black
            } else if appState.viewMode == .split {
                HStack(spacing: 8) {
                    if hudVisible, let file = currentFile, let lcg = leftCG {
                        MetadataHUDView(file: file, cgImage: lcg, cache: appState.cache)
                            .frame(width: 240)
                            .background(.ultraThinMaterial)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack {
                                Color.black
                                if let img = leftCG, let file = currentFile {
                                    let flagColor = appState.session?.flagColor(for: file)
                                    ZoomableImageView(cgImage: img, fileID: file.id, flagColor: flagColor, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                                } else { Color.black }
                            }.frame(width: geo.size.width, height: geo.size.height)
                        }.clipped()
                        GeometryReader { geo in
                            ZStack {
                                Color.black
                                if let img = rightCG, rightFile != nil {
                                    ZoomableImageView(cgImage: img, fileID: rightFile?.id, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                                } else if rightFile == nil {
                                    VStack(spacing: 8) { Image(systemName:"photo.slash").font(.title2).foregroundStyle(.secondary)
                                                         Text("No next image").font(.caption).foregroundStyle(.secondary) }
                                } else {
                                    Color.black
                                }
                            }.frame(width: geo.size.width, height: geo.size.height)
                        }.clipped()
                    }
                    if hudVisible {
                        if let rFile = rightFile, let rcg = rightCG {
                            MetadataHUDView(file: rFile, cgImage: rcg, cache: appState.cache)
                                .frame(width: 240)
                                .background(.ultraThinMaterial)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else if rightFile == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.slash").font(.title2).foregroundStyle(.secondary)
                                Text("No next image").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 240)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .background(.ultraThinMaterial)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else {
                            // rightFile exists but rightCG still nil (thumb pending) — show Loading HUD via MetadataHUDView with nil cgImage
                            if let rFile = rightFile {
                                MetadataHUDView(file: rFile, cgImage: nil, cache: appState.cache)
                                    .frame(width: 240)
                                    .background(.ultraThinMaterial)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: hudVisible)
                .animation(.easeInOut(duration: 0.15), value: appState.viewMode)
            } else if let cgImage = leftCG { // Single (existing)
                let flagColor = currentFile.flatMap { appState.session?.flagColor(for: $0) }
                HStack(spacing: 8) { // was spacing:0 with Divider() after HUD — gap via spacing 8 + Color.black
                    if hudVisible, let file = currentFile {
                        MetadataHUDView(file: file, cgImage: cgImage, cache: appState.cache).frame(width: 240).background(.ultraThinMaterial).transition(.move(edge:.leading).combined(with:.opacity))
                        // Divider() removed — gap via HStack spacing 8
                    }
                    GeometryReader { geo in
                        ZStack {
                            Color.black
                            ZoomableImageView(cgImage: cgImage, fileID: currentFile?.id, flagColor: flagColor, scale: $zoomScale, lastScale: $zoomLastScale, offset: $zoomOffset, lastOffset: $zoomLastOffset)
                        }.frame(width: geo.size.width, height: geo.size.height)
                    }.clipped()
                }
                .animation(.easeInOut(duration: 0.2), value: hudVisible)
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

}
