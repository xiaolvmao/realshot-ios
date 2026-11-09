import SwiftUI

struct RootView: View {
    @StateObject private var model = EditorViewModel()
    @StateObject private var batch = BatchViewModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if !batch.isEmpty {
                BatchView(model: batch)
                    .transition(.opacity)
            } else if model.source == nil {
                ImportView(model: model, batch: batch)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                EditorView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: model.source == nil)
        .animation(.easeInOut(duration: 0.28), value: batch.isEmpty)
    }
}
