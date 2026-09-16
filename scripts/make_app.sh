#!/bin/bash
# 打包 WinMouse.app（在 Mac 上运行）
# 只有 .app 形态：开机自启（SMAppService）才生效，辅助功能授权身份才稳定
set -euo pipefail
cd "$(dirname "$0")/.."

# MAKE_APP_ARCHS="arm64 x86_64" 构建通用二进制（CI 用）；默认只构建本机架构
ARCH_ARGS=()
for a in ${MAKE_APP_ARCHS:-}; do
    ARCH_ARGS+=(--arch "$a")
done
swift build -c release "${ARCH_ARGS[@]}"

APP=build/WinMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 多架构构建的产物在 .build/apple/Products/Release 下
BIN=.build/release/WinMouse
[ -f "$BIN" ] || BIN=.build/apple/Products/Release/WinMouse
cp "$BIN" "$APP/Contents/MacOS/WinMouse"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" \
    || echo "提示：无 Resources/AppIcon.icns（可运行 swift scripts/make_icon.sh 生成），App 将无自定义图标"

# 优先用固定自签证书签名：辅助功能授权锚定证书（certificate root），
# 重新编译后不再失效。未创建证书时退回 ad-hoc（每次编译都要重新授权一次）。
IDENTITY="WinMouse Dev"
KC="$HOME/Library/Keychains/WinMouse-Dev.keychain-db"
[ -f "$KC" ] && security unlock-keychain -p winmouse-dev "$KC" 2>/dev/null || true
if codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "完成：${APP}（已用自签证书 ${IDENTITY} 签名，重编译不影响授权）"
else
    codesign --force --sign - "$APP" 2>/dev/null || true
    echo "完成：${APP}（ad-hoc 签名：每次编译后需在辅助功能里重新勾选）"
    echo "提示：运行 scripts/make_cert.sh 创建自签证书后，重新编译不再丢授权。"
fi
