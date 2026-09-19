#!/bin/bash
# 导出本地 "WinMouse Dev" 自签证书为 base64 p12，用于配置 GitHub secrets，
# 让 CI 构建与本地用同一证书签名 → 自动更新替换 .app 后辅助功能授权不失效。
# 用法：scripts/export_cert.sh [输出路径，默认 build/winmouse-dev.p12.b64]
set -euo pipefail

IDENTITY="WinMouse Dev"
KC="$HOME/Library/Keychains/WinMouse-Dev.keychain-db"
KC_PASS="winmouse-dev"

OUT="${1:-build/winmouse-dev.p12.b64}"
P12="${OUT%.b64}"

[ -f "$KC" ] || { echo "未找到 $KC，请先运行 scripts/make_cert.sh"; exit 1; }
security unlock-keychain -p "$KC_PASS" "$KC"
mkdir -p "$(dirname "$OUT")"
security export -k "$KC" -t identities -f pkcs12 -P "$KC_PASS" -o "$P12"
base64 -i "$P12" -o "$OUT"
rm -f "$P12"

echo "已导出：$OUT"
echo "接着执行（把本地证书配置到 GitHub secrets）："
echo "  gh secret set WINMOUSE_DEV_P12 < $OUT"
echo "  gh secret set WINMOUSE_DEV_PASSWORD -b '$KC_PASS'"
