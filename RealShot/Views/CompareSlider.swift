import SwiftUI
import UIKit

struct RevealShape: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = max(0, min(1, fraction)) * rect.width
        return Path(CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
    }
}

/// 左「原图」/ 右「成片」的对比滑块。
/// 两张图的构图完全一致（同一个裁切、同一次重采样），所以能严丝合缝对齐。
struct CompareSlider: View {
    let before: UIImage
    let after: UIImage
    @Binding var position: Double

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedSize(for: after.size, in: geo.size)

            ZStack(alignment: .topLeading) {
                imageView(after, size: fitted)

                imageView(before, size: fitted)
                    .clipShape(RevealShape(fraction: CGFloat(position)))

                divider(width: fitted.width, height: fitted.height)

                labels(width: fitted.width)
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = value.location.x / max(fitted.width, 1)
                        position = min(max(Double(x), 0), 1)
                    }
            )
        }
    }

    private func imageView(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private func divider(width: CGFloat, height: CGFloat) -> some View {
        let x = width * CGFloat(position)
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1.1, height: height)

            Circle()
                .fill(Color.white)
                .frame(width: 30, height: 30)
                .overlay(
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.45))
                )
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .position(x: x, y: height / 2)
        .allowsHitTesting(false)
    }

    private func labels(width: CGFloat) -> some View {
        HStack {
            Text("原图")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.35), in: Capsule())
                .opacity(position > 0.12 ? 1 : 0)

            Spacer()

            Text("成片")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.35), in: Capsule())
                .opacity(position < 0.88 ? 1 : 0)
        }
        .padding(10)
        .frame(width: width, alignment: .top)
        .allowsHitTesting(false)
    }

    private func fittedSize(for imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
