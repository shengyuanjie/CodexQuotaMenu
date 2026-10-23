#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "用法：$0 <Codex用量.zip>" >&2
    exit 2
fi

ARCHIVE=$1
if [[ ! -f "$ARCHIVE" ]]; then
    echo "未找到安装包：$ARCHIVE" >&2
    exit 2
fi

AUDIT_DIR=$(mktemp -d /private/tmp/codex-quota-release-audit.XXXXXX)
trap 'rm -rf "$AUDIT_DIR"' EXIT

# Check the complete ZIP envelope before extraction. Runtime configuration and
# extra top-level files must never travel with a public app archive.
python3 - "$ARCHIVE" <<'PY_AUDIT'
import re, sys, zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as archive:
    entries = archive.infolist()
    roots = {item.filename.split('/')[0] for item in entries if not item.filename.startswith('__MACOSX/')}
    if len(roots) != 1 or not next(iter(roots)).endswith('.app'):
        raise SystemExit('安全检查失败：安装包包含应用之外的文件')
    root = next(iter(roots))
    files = {root + '/' + name for name in [
        'Contents/Info.plist', 'Contents/MacOS/CodexQuotaMenu',
        'Contents/Resources/AppIcon.icns', 'Contents/_CodeSignature/CodeResources']}
    directories = {str(parent) for name in files for parent in PurePosixPath(name).parents if str(parent) != '.'}
    token = re.compile(rb'(?<![A-Za-z0-9_])[0-9]{5,}:[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])')
    for item in entries:
        name = item.filename.rstrip('/')
        if name.startswith('/') or '\\' in name or '..' in PurePosixPath(name).parts:
            raise SystemExit('安全检查失败：安装包路径无效')
        if item.is_dir():
            if name not in directories and name != '__MACOSX' and not name.startswith('__MACOSX/' + root):
                raise SystemExit('安全检查失败：安装包包含额外目录')
            continue
        allowed = name in files
        if name.startswith('__MACOSX/'):
            metadata = PurePosixPath(name[len('__MACOSX/'):])
            if metadata.name.startswith('._'):
                original = str(metadata.with_name(metadata.name[2:]))
                allowed = original in files or original in directories
        if not allowed:
            raise SystemExit('安全检查失败：安装包包含未审核文件')
        if token.search(archive.read(item)):
            raise SystemExit('安全检查失败：安装包疑似包含 Telegram Bot Token（内容已隐藏）')
print('ZIP 文件范围及 Telegram 凭据检查：通过')
PY_AUDIT

unzip -tq "$ARCHIVE"
ditto -x -k "$ARCHIVE" "$AUDIT_DIR"
APP=$(find "$AUDIT_DIR" -maxdepth 2 -type d -name '*.app' -print -quit)
if [[ -z "$APP" ]]; then
    echo "安全检查失败：安装包中没有 .app" >&2
    exit 1
fi

BINARY="$APP/Contents/MacOS/CodexQuotaMenu"
EXPECTED_FILES=(
    "Contents/Info.plist"
    "Contents/MacOS/CodexQuotaMenu"
    "Contents/Resources/AppIcon.icns"
    "Contents/_CodeSignature/CodeResources"
)

for expected in "${EXPECTED_FILES[@]}"; do
    if [[ ! -f "$APP/$expected" ]]; then
        echo "安全检查失败：缺少 $expected" >&2
        exit 1
    fi
done

ACTUAL_COUNT=$(find "$APP" -type f | wc -l | tr -d ' ')
if [[ "$ACTUAL_COUNT" != "${#EXPECTED_FILES[@]}" ]]; then
    echo "安全检查失败：应用包含未审核的额外文件" >&2
    find "$APP" -type f -print >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"
if strings - < "$BINARY" | grep -Eq '/Users/[^/]+/|/home/[^/]+/'; then
    echo "安全检查失败：二进制包含用户目录路径" >&2
    exit 1
fi

if strings - < "$BINARY" | grep -Eiq \
    'BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-'; then
    echo "安全检查失败：二进制疑似包含凭据" >&2
    exit 1
fi

if otool -L "$BINARY" | tail -n +2 | grep -Evq '^[[:space:]]+(/System/Library/|/usr/lib/)'; then
    echo "安全检查失败：发现非系统动态依赖" >&2
    otool -L "$BINARY" >&2
    exit 1
fi

echo "签名：有效（ad-hoc，未公证）"
echo "架构：$(file "$BINARY" | sed 's/.*: //')"
echo "SHA-256：$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "发布审计：通过"
