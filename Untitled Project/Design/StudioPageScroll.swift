import SwiftUI

/// Grow the work area into the viewport while allowing short windows to scroll.
struct StudioPageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
            }
        }
    }
}
