import SwiftUI

struct RootView: View {
    @StateObject private var model = EditorViewModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if model.source == nil {
                ImportView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                EditorView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: model.source == nil)
    }
}
