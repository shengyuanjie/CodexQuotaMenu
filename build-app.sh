#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
OUTPUT_DIR=${1:-"$SCRIPT_DIR/dist"}
APP_NAME="Codex用量.app"
APP_DIR="$OUTPUT_DIR/$APP_NAME"
BINARY="$APP_DIR/Contents/MacOS/CodexQuotaMenu"

cd "$SCRIPT_DIR"
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
xcrun swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/CodexQuotaMenu" "$BINARY"
cp "Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Swift 的发布二进制仍可能包含编译机用户名和绝对源码路径，必须先剥离再签名。
strip -S "$BINARY"
if strings - < "$BINARY" | grep -Eq '/Users/[^/]+/|/home/[^/]+/'; then
    echo "安全检查失败：发布二进制仍包含用户目录路径" >&2
    exit 1
fi

# 未配置 Apple Developer 证书时使用 ad-hoc 签名，但仍启用 Hardened Runtime。
codesign --force --deep --options runtime --timestamp=none --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
