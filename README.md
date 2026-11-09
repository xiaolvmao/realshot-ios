# 实拍 / RealShot

一个 iOS 应用：把截图、网图、渲染图、AI 生图，还原成**看起来像手机真实拍出来的照片**。

不是加个滤镜。它逐条复刻"照片之所以像照片"的物理特征。

---

## 功能

- **单张精修** —— 导入 → 选预设 → 微调 → 保存 / 分享，中间有原图对比滑块
- **批量处理** —— 一次最多选 20 张，套同一预设逐张渲染并直接写入相册；每张的随机扰动独立，不会看起来像同一个滤镜刷了二十遍。网格末尾的「＋」随时往队尾追加，全屏查看时缩略图条末尾也有一个
- **撤回 / 恢复** —— 换预设、换随机、增删照片都能一步步退回去，再原样恢复；处理结束后历史清空（已写进相册的照片撤不回来）
- **六个预设** —— 手机主摄 / 长焦人像 / CCD 数码 / 35mm 胶片 / 一次性相机 / 翻拍屏幕
- **22 个参数** —— 质感、光学、色彩、画幅四组滑杆
- **内置使用说明** —— 首页右上角「使用说明」、编辑器底部「?」，需要时点开；不做启动弹窗

---

## 快速开始

```
RealShot/
├── RealShot.xcodeproj      ← 双击打开
├── RealShot/               ← 源码（Xcode 16 的同步文件夹，新增文件自动入工程）
├── scripts/build_ipa.sh    ← 一条命令打 IPA
├── scripts/publish.py      ← 走 REST API 发布并拉回 artifact
├── .github/workflows/      ← 没有 Mac 时用 GitHub Actions 出包
├── project.yml             ← XcodeGen 备用方案
└── README.md
```

1. `open RealShot.xcodeproj`
2. 选中 RealShot target → Signing & Capabilities → 选你的 Team
3. 连真机运行（模拟器也行，但相册保存要用真机）

**要求**：Xcode 16+ / iOS 17+。

**如果 xcodeproj 打不开**（Xcode 15 及更早不认识 objectVersion 77）：

```bash
brew install xcodegen
cd RealShot && xcodegen generate
```

或者新建一个 iOS App 工程，把 `RealShot/RealShot/` 整个文件夹拖进去，选 "Create groups"，删掉自动生成的 `ContentView.swift` 和 `App.swift` 即可。

---

## 打包成 IPA

iOS 应用**只能**在 macOS 上用 Xcode 编译，Windows / Linux 上没有 iOS SDK，无法出包。两条路：

### A. 有 Mac

```bash
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
# → dist/RealShot-unsigned.ipa
```

带开发者证书签名导出（目标设备需已注册）：

```bash
./scripts/build_ipa.sh --signed --team ABCDE12345
# → dist/RealShot.ipa
```

### B. 没有 Mac

把 `RealShot/` 作为 git 仓库根目录推上 GitHub：

```bash
cd RealShot
git init && git add . && git commit -m "init"
git branch -M main
git remote add origin <你的仓库地址>
git push -u origin main
```

工作流会自动跑（macOS 15 runner，自带 Xcode 16），几分钟后在 **Actions → 最新一次运行 → Artifacts** 下载 `RealShot-unsigned-ipa`。

### 装到手机上

无签名 IPA 不能直接安装，需要用你自己的 Apple ID 重签：

- **Sideloadly**（macOS / Windows）—— 拖入 ipa、填 Apple ID、插线安装，最省事
- **AltStore** —— 支持自签续期
- 免费开发者账号签的包 **7 天过期**，到期重签一次即可

---


## 为什么截图一眼就是假的

七条破绽，管线里每一条都有对应工序：

| 破绽 | 截图 / 网图的特征 | 对应处理 |
|---|---|---|
| 绝对锐利 | 文字边缘像矢量图，无振铃 | 余弦重采样（先降后升）+ 镜头柔化 |
| 无噪点 | 大面积纯色，梯度里没有颗粒 | 亮度颗粒 + 彩色噪点 |
| 无光学缺陷 | 边角同样锐利、同色 | 暗角、色散、轻微手抖、透视畸变 |
| 无动态范围限制 | 高光是 `#FFFFFF` 死白 | 高光溢出（bloom）+ 色调曲线压高光 |
| 无压缩痕迹 | PNG / 无损，8×8 块不存在 | 真正的 JPEG 编解码往返 |
| 比例不对 | 9:19.5 或任意尺寸 | 裁到 4:3 / 3:2 / 16:9，去掉状态栏 |
| 每张都一样 | 同一滤镜导致的统一质感 | 每个参数带随机微扰，种子逐张变化 |

单独做任何一条都不够。**必须全部叠在一起**，眼睛才会认。

---

## 管线

```
输入
 ├─ 几何：裁画幅 → 去状态栏 → 重采样打散像素级锐利 → 微倾斜 / 透视
 ├─ 色彩：白平衡漂移 → 曝光 → 高光溢出 → 对比饱和 → 色调曲线（抬黑位/压高光）→ 暗角
 ├─ 光学：色散 → 手抖 → 镜头柔化 → 机内锐化
 ├─ 传感器：亮度颗粒（软光叠加）+ 彩色噪点（overlay）
 ├─ 场景：屏幕像素网格（翻拍感）/ 漏光
 └─ 压缩：JPEG 编码 → 解码（可多次）→ 写 EXIF → 存相册
```

代码分布：

- `Engine/RealismEngine.swift` — 主链路，全部 Core Image
- `Engine/FrameAdapter.swift` — 画幅裁切与构图锚点
- `Engine/JpegDegrader.swift` — 真实压缩往返（不是加噪点假装）
- `Engine/ExifWriter.swift` — 写拍摄参数
- `Models/RealismParameters.swift` — 22 个参数 + 随机微扰
- `Models/CameraPreset.swift` — 6 个设备预设

渲染分辨率与原始尺寸解耦：预览固定 1100px 长边（拖滑杆也能 60fps），导出时才全尺寸跑。

---

## 六个预设

| 预设 | 质感来源 |
|---|---|
| 手机主摄 | 26mm，干净，轻微欠曝，现代手机的计算摄影味 |
| 长焦人像 | 77mm，压缩感，柔化更重，暖调 |
| CCD 数码 | 2008 年卡片机：高对比、色彩溢出、压缩痕迹明显 |
| 35mm 胶片 | 粗颗粒、抬黑位、暖白平衡、轻微漏光 |
| 一次性相机 | 塑料镜头：色散夸张、边缘垮掉、漏光 |
| 翻拍屏幕 | 拍屏幕而不是拍实物：像素网格 + 摩尔纹 + 反光 |

---

## 使用建议

- **效果最好的输入**：网图、商品图、AI 生图、视频截帧、游戏截图。它们本来就有"照片的构图"，只差光学和传感器特征。
- **裁成 4:3 并勾选"裁掉状态栏"**，这一步的收益比调任何滑杆都大。
- **不要把所有参数拉满**。真实照片的缺陷是**克制**的：颗粒 35%、柔化 45%、色散 28% 就已经很像了。拉满会立刻变成"滤镜"。
- 同一张图重复导出时点"换一种随机"，颗粒分布、手抖角度、漏光位置都会变，批量处理不会露馅。
- **纯文字截图变不成照片**。那不是真实感问题，是内容问题。

---

## 关于元数据

`画幅 → 写入模拟拍摄信息` 会写机身、镜头、光圈、快门、ISO、拍摄时间。

默认开启，理由是：一张没有任何 EXIF 的"照片"在现代系统里本身就是个破绽（相册不显示参数、AirDrop 后信息丢失）。它只用于让成片的视觉风格和元信息保持一致。

**请别用它把编造的内容伪装成纪实照片。** 工具的边界在这儿，越界的是人。

---

## 已知取舍

- 只用 Core Image，没有自定义 Metal kernel。如果要更真实的镜头散景（非高斯）或胶片光晕，需要写 `CIColorKernel`。
- 裁切是"丢掉多余部分"，没有做内容感知扩展。竖屏截图裁 4:3 会损失上下内容，所以给了构图位置滑杆。
- 不做美颜、不做人像分割、不做 HDR 合成。
- 导出尺寸上限是原图 2 倍，再放大只会糊。
