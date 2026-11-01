#!/bin/bash
# Package the application entity, never the build symlink or user data.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
workspace="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
app="$workspace/build/FocusBar.app"
[[ -d "$app" ]] || { printf 'Run tools/build.sh first.\n' >&2; exit 1; }
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" == local.shijie.FocusBar ]] || exit 1
codesign --verify --strict "$app"
mkdir -p "$workspace/dist"
output="$workspace/dist/FocusBar-v2.0.0-beta.1-macOS-arm64.dmg"
[[ ! -e "$output" ]] || { printf 'Refusing to replace an existing DMG.\n' >&2; exit 1; }
file "$app/Contents/MacOS/FocusBar" | grep -q arm64 || { printf 'This release recipe requires arm64.\n' >&2; exit 1; }
staging="$(mktemp -d "$workspace/dist/dmg-staging.XXXXXX")"
# ditto follows the top-level build link; all application resources stay self-contained.
ditto "$app/" "$staging/FocusBar.app"
[[ ! -L "$staging/FocusBar.app" ]] || exit 1
ln -s /Applications "$staging/Applications"
printf '%s\n' '专注条 FocusBar v2.0.0-beta.1（Apple Silicon 测试版）' '' '将 FocusBar.app 拖入 Applications，弹出磁盘后再打开。' '' '本包仅采用 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。macOS 可能拦截首次运行；不应关闭 Gatekeeper、SIP 等安全保护。若不确定，请等待正式签名版或审阅源码后构建。' '' '项目与安装说明：https://github.com/Sam-byte1/focusbar-macos' '数据仅保存在本机，安装包不含个人数据或演示历史。' > "$staging/安装说明.txt"
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 27 ]]; then
    diskutil image create from --volumeName 'FocusBar Beta' --format UDZO "$staging" "$output"
    diskutil image info "$output" >/dev/null
else
    hdiutil create -volname 'FocusBar Beta' -srcfolder "$staging" -format UDZO "$output"
    hdiutil verify "$output"
fi
(cd "$workspace/dist" && shasum -a 256 "${output##*/}" > SHA256SUMS.txt)
printf 'Created %s\n' "$output"
