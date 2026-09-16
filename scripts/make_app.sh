#!/bin/bash
# 打包 WinMouse.app（在 Mac 上运行）
# 只有 .app 形态：开机自启（SMAppService）才生效，辅助功能授权身份才稳定
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/WinMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WinMouse "$APP/Contents/MacOS/WinMouse"
cp Info.plist "$APP/Contents/Info.plist"
# 临时签名（ad-hoc）：权限授予跟着签名身份走，而不是文件路径
codesign --force --sign - "$APP" 2>/dev/null || true

echo "完成：$APP"
echo "提示：授权辅助功能时勾选 WinMouse（不是终端）；位置固定后再授权，移动包体会要重新授权。"
