#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "用法：$0 <release-assets目录> <版本号>" >&2
    exit 2
fi

ASSETS_DIR=$1
VERSION=$2
if [[ ! -d "$ASSETS_DIR" ]]; then
    echo "禁止发布：找不到 Release 资源目录" >&2
    exit 1
fi

AUDIT_DIR=""
cleanup() {
    if [[ -n "$AUDIT_DIR" && -d "$AUDIT_DIR" ]]; then
        rm -rf "$AUDIT_DIR"
    fi
}
trap cleanup EXIT

for ARCH in arm64 x86_64; do
    ARCHIVE="$ASSETS_DIR/CodexQuotaMenu-v${VERSION}-macOS-${ARCH}.zip"
    CHECKSUM="${ARCHIVE}.sha256"

    if [[ ! -f "$ARCHIVE" || ! -f "$CHECKSUM" ]]; then
        echo "禁止发布：缺少 ${ARCH} 安装包或校验文件" >&2
        exit 1
    fi

    (
        cd "$ASSETS_DIR"
        shasum -a 256 -c "$(basename "$CHECKSUM")"
    )

    AUDIT_DIR=$(mktemp -d "/private/tmp/codex-quota-${ARCH}.XXXXXX")
    ditto -x -k "$ARCHIVE" "$AUDIT_DIR"
    BINARY=$(find "$AUDIT_DIR" -path '*/Contents/MacOS/CodexQuotaMenu' -type f -print -quit)
    if [[ -z "$BINARY" ]]; then
        echo "禁止发布：${ARCH} 安装包中没有应用二进制" >&2
        exit 1
    fi

    ACTUAL_ARCH=$(lipo -archs "$BINARY")
    rm -rf "$AUDIT_DIR"
    AUDIT_DIR=""

    if [[ "$ACTUAL_ARCH" != "$ARCH" ]]; then
        echo "禁止发布：${ARCH} 包中的实际架构为 ${ACTUAL_ARCH}" >&2
        exit 1
    fi
done

ZIP_COUNT=$(find "$ASSETS_DIR" -maxdepth 1 -name '*.zip' -type f | wc -l | tr -d ' ')
SHA_COUNT=$(find "$ASSETS_DIR" -maxdepth 1 -name '*.sha256' -type f | wc -l | tr -d ' ')
if [[ "$ZIP_COUNT" != "2" || "$SHA_COUNT" != "2" ]]; then
    echo "禁止发布：Release 必须且只能包含两套安装包及其校验文件" >&2
    exit 1
fi

echo "Release 架构门禁：arm64 与 x86_64 均验证通过"
