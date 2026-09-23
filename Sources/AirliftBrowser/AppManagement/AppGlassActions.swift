import SwiftUI

struct AppGlassActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12, content: content).buttonStyle(.glass)
            }
        } else {
            HStack(spacing: 12, content: content).buttonStyle(.bordered)
        }
    }
}

struct AppPrimaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
