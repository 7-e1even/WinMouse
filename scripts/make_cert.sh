#!/bin/bash
# 生成自签名代码签名证书 "WinMouse Dev" 并放入专用开发钥匙串（每台机器只需运行一次）
# 作用：make_app.sh 用它签名后，重新编译不再导致辅助功能授权失效
#（ad-hoc 签名的授权锚定二进制指纹，每次编译都变；证书签名锚定证书，跨编译稳定）
#
# 专用钥匙串不放进登录钥匙串：后台脚本会话写不进锁定的登录钥匙串，
# 且开发证书单独存放、随取随用，不与个人证书混放。
set -euo pipefail

IDENTITY="WinMouse Dev"
KC="$HOME/Library/Keychains/WinMouse-Dev.keychain-db"
# 开发钥匙串口令：只保护这把一次性开发证书，允许写在脚本里
KC_PASS="winmouse-dev"

[ -f "$KC" ] || security create-keychain -p "$KC_PASS" "$KC"
# 不设超时/睡眠锁定，长会话开发时 codesign 随时可用
security set-keychain-settings "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"

# 加入用户钥匙串搜索列表（codesign 按搜索列表找身份），已在列表则跳过
CURRENT=$(security list-keychains -d user | tr -d '"' | grep -v '^$')
case " $CURRENT " in
    *" $KC "*) : ;;
    *) security list-keychains -d user -s $CURRENT "$KC" ;;
esac

if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1 \
   && security find-key "$KC" 2>/dev/null | grep -q '"'"$IDENTITY"'"'; then
    echo "证书已存在，无需重复创建：$IDENTITY"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# 固定用系统自带 LibreSSL：Homebrew OpenSSL 3.x 默认的 AES/SHA-256 p12
# 会被 macOS security 工具拒绝（MAC verification failed）
OPENSSL=/usr/bin/openssl

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = WinMouse Dev
O = WinMouse
[v3]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" 2>/dev/null

# p12 口令仅用于导入，钥匙串保存后该口令不再需要
"$OPENSSL" pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$TMP/identity.p12" -passout pass:"$KC_PASS" 2>/dev/null

security import "$TMP/identity.p12" -k "$KC" -P "$KC_PASS" -T /usr/bin/codesign
# 允许 codesign 无提示使用私钥（导入时 -T 已加 ACL，这里再放宽分区）
security set-key-partition-list -k "$KC_PASS" -S apple-tool:,apple: "$KC" >/dev/null

echo "导入完成。证书与私钥："
security find-certificate -c "$IDENTITY" "$KC" >/dev/null && echo "  ✓ 证书 $IDENTITY"
security find-key "$KC" 2>/dev/null | grep -q "\"$IDENTITY\"" && echo "  ✓ 私钥（codesign 可直接使用）"
