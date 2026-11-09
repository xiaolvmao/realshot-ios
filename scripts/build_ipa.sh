#!/usr/bin/env bash
#
# 把 RealShot 打包成 .ipa
#
#   默认：无签名 IPA。用 Sideloadly / AltStore / TrollStore 之类工具
#         用你自己的 Apple ID 重签后安装（免费账号 7 天有效）。
#
#   签名：需要已登录 Xcode 的开发者账号，且目标设备已注册。
#
# 用法：
#   ./scripts/build_ipa.sh                  # 生成 dist/RealShot-unsigned.ipa
#   ./scripts/build_ipa.sh --signed --team ABCDE12345
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="RealShot"
PROJECT="RealShot.xcodeproj"
CONFIG="Release"
DERIVED="build"
ARCHIVE="$DERIVED/$SCHEME.xcarchive"
DIST="$PROJECT_DIR/dist"

MODE="unsigned"
TEAM_ID=""

usage() {
  cat <<'EOF'
用法: scripts/build_ipa.sh [选项]

  --signed            使用开发者证书签名导出（而不是无签名）
  --team <TEAM_ID>    签名时必填，10 位 Team ID
  -h, --help          显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --signed) MODE="signed"; shift ;;
    --team)   TEAM_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

if ! command -v xcodebuild >/dev/null 2>&1; then
  cat <<'EOF'
✗ 找不到 xcodebuild。

  iOS 应用只能在 macOS + Xcode 上编译（需要 iOS SDK 和 UIKit）。
  没有 Mac 的话，用仓库里的 GitHub Actions 工作流：
  .github/workflows/build-ipa.yml —— push 之后在 Actions 里下载 artifact。
EOF
  exit 1
fi

if [[ "$MODE" == "signed" && -z "$TEAM_ID" ]]; then
  echo "✗ --signed 需要 --team <TEAM_ID>"
  exit 1
fi

echo "▸ Xcode: $(xcodebuild -version | head -1)"
echo "▸ 模式: $MODE"

rm -rf "$ARCHIVE" "$DIST"
mkdir -p "$DERIVED" "$DIST"

# ---------------------------------------------------------------- archive
if [[ "$MODE" == "unsigned" ]]; then
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED/DerivedData" \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    EXPANDED_CODE_SIGN_IDENTITY="" \
    archive
else
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED/DerivedData" \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    archive
fi

APP="$ARCHIVE/Products/Applications/$SCHEME.app"

# archive 偶尔不落地到预期路径，退回去 DerivedData 里找
if [[ ! -d "$APP" ]]; then
  FALLBACK="$DERIVED/DerivedData/Build/Products/$CONFIG-iphoneos/$SCHEME.app"
  if [[ -d "$FALLBACK" ]]; then
    APP="$FALLBACK"
    echo "▸ 用 DerivedData 产物: $APP"
  else
    echo "✗ 找不到 $SCHEME.app，编译可能失败了。"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 导出
if [[ "$MODE" == "signed" ]]; then
  PLIST="$DERIVED/ExportOptions.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$DIST" \
    -exportOptionsPlist "$PLIST" \
    -allowProvisioningUpdates

  echo
  echo "✓ 已签名 IPA:"
  ls -lh "$DIST"/*.ipa
  exit 0
fi

# ---------------------------------------------------------------- 无签名 IPA
STAGE="$DERIVED/ipa-stage"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

# 清掉可能残留的签名文件，避免重签工具混淆
rm -rf "$STAGE/Payload/$SCHEME.app/_CodeSignature" || true

( cd "$STAGE" && zip -qry "$DIST/$SCHEME-unsigned.ipa" Payload )

echo
echo "✓ 无签名 IPA:"
ls -lh "$DIST/$SCHEME-unsigned.ipa"
cat <<'EOF'

安装方式（任选其一，都会用你自己的 Apple ID 重签）：
  · macOS/Windows: Sideloadly —— 拖入 ipa，填 Apple ID，连设备安装
  · macOS/Windows: AltStore —— 支持自签续期
  · 免费开发者账号签的包 7 天后过期，需重新签

注意：无签名 IPA 不能直接双击安装，也不能上架 App Store。
EOF
