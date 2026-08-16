import SwiftUI

struct FlagBadge: View {
    var body: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
            .shadow(radius: 1)
            .padding(2)
    }
}
