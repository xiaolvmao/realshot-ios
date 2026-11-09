import SwiftUI

/// 使用说明。刻意做成「从界面点开」的一页，而不是启动就弹的引导弹窗 ——
/// 需要的时候查，不需要的时候不打扰。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    intro
                    steps
                    suitable
                    tuning
                    batch
                    exif
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("使用说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 开头

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这是一个把「不是照片的图」变成「看起来是拍的照片」的工具。")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("它做的是复刻真实相机的物理缺陷：镜头柔化、暗角、色散、传感器噪点、高光溢出、JPEG 压缩痕迹。全部在本机完成，不上传任何图片。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(3)
        }
    }

    // MARK: 三步

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("三步上手")

            step(1, "选图", "从相册挑一张，或从剪贴板粘贴。点「批量处理」可以一次选多张。")
            step(2, "挑预设再微调", "六个预设对应六种器材。先选最接近的一个，再动滑杆。")
            step(3, "保存", "点右上角「保存」写入相册。想先看效果，拖动中间的竖线对比原图。")
        }
    }

    // MARK: 适合与不适合

    private var suitable: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("什么图效果最好")

            VStack(alignment: .leading, spacing: 8) {
                bullet("适合", "网图、商品图、渲染图、AI 生图、视频截图、游戏画面 —— 它们本来就有照片的构图，只差光学和传感器特征。", Theme.accent)
                bullet("不适合", "纯文字截图、纯色 UI、线框图。没有真实的光影关系，加完噪点也只是「一张有噪点的截图」。", Color.orange)
            }
        }
    }

    // MARK: 参数

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("参数怎么调")

            Text("新手只用记住一条：默认值已经调好了，动滑杆最多拉到 60%。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)

            VStack(spacing: 0) {
                row("颗粒", "25% – 40%", "再高就是雪花屏，不是胶片")
                divider
                row("镜头柔化", "35% – 50%", "太低边缘还是矢量感，太高整张发糊")
                divider
                row("暗角", "25% – 40%", "手机主摄其实很轻，别做成老镜头")
                divider
                row("色散", "20% – 35%", "只在画面边缘明显，中间几乎看不到才对")
                divider
                row("高光溢出", "30% – 45%", "让死白的高光有过渡，不是糊一层光")
                divider
                row("压缩次数", "1 – 2", "两次已经足够脏，三次开始有块状伪影")
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            tip("同一个预设连续处理十张不会得到十份相同的颗粒 —— 每次渲染都会在基准值附近做随机扰动。点「换一种随机」可以主动重掷。")
        }
    }

    // MARK: 批量

    private var batch: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("批量处理")

            Text("一次最多选 20 张。选好后先挑预设和画幅，再点「开始处理并保存」，它会逐张渲染并直接写进相册，缩略图上打勾的就是完成的。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(3)

            tip("批量用的是同一个预设，但每张的随机扰动独立，所以不会看起来像同一个滤镜刷了二十遍。中途失败的那张会标红，不影响其它张。")
        }
    }

    // MARK: 拍摄信息

    private var exif: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("关于「写入模拟拍摄信息」")

            Text("开启后会在文件里写入机身、镜头、光圈、快门、ISO。作用是让成片和它的视觉风格一致 —— 一张 CCD 风格的图配着 2024 年的手机机型信息，本身就是破绽。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(3)

            tip("这些信息是模拟出来的，不要拿它把编造的内容伪装成纪实照片。工具本身是中性的，用的人不是。")
        }
    }

    // MARK: 组件

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.text)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ tag: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(tag)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.14), in: Capsule())

            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ name: String, _ range: String, _ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 74, alignment: .leading)

            Text(range)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)

            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
            .padding(.leading, 12)
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(Theme.accent.opacity(0.7))
                .frame(width: 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
