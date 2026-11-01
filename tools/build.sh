#!/bin/bash
# Run from the workspace, never from the downloaded source tree.
# Old successful versions are retained; no resource directories are merged.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() { printf 'build: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: %s [--debug] [--source /absolute/upstream-root] [--output /absolute/build-directory]\n' "$0"
}
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
source_root="$workspace/TomatoBar"
output="$workspace/build"
debug=0
while (($#)); do
    case "$1" in
        --debug) debug=1; shift ;;
        --source|--output)
            (($# >= 2)) || fail "Missing value for $1"
            [[ "$2" == /* ]] || fail "$1 requires an absolute path"
            case "$1" in --source) source_root="$2" ;; --output) output="$2" ;; esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
done
[[ -d "$source_root" ]] || fail "Source root not found: $source_root"
source_root="$(CDPATH= cd -- "$source_root" && pwd -P)"
cwd="$(pwd -P)"
case "$cwd/" in
    "$source_root/"*|"$workspace/TomatoBar/"*|"$workspace"/download-*)
        fail 'Refusing to run from downloaded content; invoke tools/build.sh from the workspace.' ;;
esac
[[ ! -L "$output" ]] || fail 'Output directory must not be a symlink'
/bin/mkdir -p -- "$output"
output="$(CDPATH= cd -- "$output" && pwd -P)"
case "$output/" in
    "$source_root/"*|"$workspace/TomatoBar/"*|"$script_dir/"*|"$workspace"/download-*)
        fail 'Output must be outside downloaded source and tools directories' ;;
esac
[[ "$output" != / && "$output" != "$workspace" ]] || fail 'Choose a dedicated build directory'

source_dir="$source_root/TomatoBar"
# Intentionally explicit: never compile files discovered in the download.
sources=(
    "$source_dir/App.swift"
    "$source_dir/View.swift"
    "$source_dir/State.swift"
    "$source_dir/Timer.swift"
    "$source_dir/Notifications.swift"
    "$source_dir/Player.swift"
    "$source_dir/Log.swift"
    "$source_dir/ProgressImage.swift"
    "$source_dir/HotKey.swift"
    "$source_dir/FocusData.swift"
    "$source_dir/FocusStore.swift"
    "$source_dir/Statistics.swift"
    "$source_dir/MainWindow.swift"
    "$source_dir/FocusViews.swift"
    "$source_dir/Dashboard.swift"
)
for source_file in "${sources[@]}" "$source_dir/Info.plist"; do
    [[ -f "$source_file" && ! -L "$source_file" ]] || fail "Missing or symlinked input: $source_file"
done
/usr/bin/plutil -lint "$source_dir/Info.plist" >/dev/null
bundle_id='local.shijie.FocusBar'
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$source_dir/Info.plist")" == "$bundle_id" ]] || fail 'Unexpected source bundle identifier'

# Only replace the symlink published by this script, and verify its target.
# A pre-existing real app (including an Xcode build) is never overwritten.
destination="$output/FocusBar.app"
check_destination() {
    local previous marker
    if [[ -L "$destination" ]]; then
        previous="$(/usr/bin/readlink "$destination")"
        case "$previous" in
            .focusbar-build.*/FocusBar.app) ;;
            *) fail 'Existing FocusBar.app is not a managed build link' ;;
        esac
        [[ "$previous" != *'/../'* && "$previous" != *'/./'* ]] || fail 'Invalid managed build link'
        [[ "${previous%/FocusBar.app}" != */* ]] || fail 'Invalid managed version directory'
        [[ ! -L "$output/${previous%/FocusBar.app}" && ! -L "$output/$previous" ]] || fail 'Managed version must be a real directory'
        [[ -f "$output/$previous/Contents/Resources/.focusbar-build" ]] || fail 'Existing app has no build ownership marker'
        IFS= read -r marker < "$output/$previous/Contents/Resources/.focusbar-build"
        [[ "$marker" == 'FocusBar tools/build.sh v1' ]] || fail 'Unexpected build ownership marker'
        [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$output/$previous/Contents/Info.plist")" == "$bundle_id" ]] || fail 'Existing app has a different bundle identifier'
    elif [[ -e "$destination" ]]; then
        fail 'Existing FocusBar.app is unmanaged; move it aside explicitly before building.'
    fi
}
check_destination

# Every build gets an empty version directory. Failed versions remain for diagnosis.
staging="$(/usr/bin/mktemp -d "$output/.focusbar-build.XXXXXX")"
app="$staging/FocusBar.app"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$staging/module-cache"
/bin/cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
for artwork in FocusBar.icns FocusBarMark.png; do
    [[ -f "$workspace/assets/$artwork" && ! -L "$workspace/assets/$artwork" ]] || fail "Missing original artwork: $artwork"
    /bin/cp "$workspace/assets/$artwork" "$app/Contents/Resources/$artwork"
done
printf 'FocusBar tools/build.sh v1\n' > "$app/Contents/Resources/.focusbar-build"
for notice in LICENSE UPSTREAM.txt; do
    if [[ -f "$workspace/$notice" && ! -L "$workspace/$notice" ]]; then
        /bin/cp "$workspace/$notice" "$app/Contents/Resources/$notice"
    elif [[ -f "$source_root/$notice" && ! -L "$source_root/$notice" ]]; then
        /bin/cp "$source_root/$notice" "$app/Contents/Resources/$notice"
    fi
done
sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
arch="$(/usr/bin/uname -m)"
case "$arch" in arm64|x86_64) ;; *) fail "Unsupported architecture: $arch" ;; esac
flags=(-O)
if ((debug)); then flags=(-Onone -g -D DEBUG); fi
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 5 -parse-as-library -sdk "$sdk" \
    -target "$arch-apple-macosx13.0" -module-name FocusBar \
    -module-cache-path "$staging/module-cache" \
    -framework AppKit -framework SwiftUI -framework Charts -framework ServiceManagement \
    "${flags[@]}" "${sources[@]}" -o "$app/Contents/MacOS/FocusBar"
/usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"
check_destination
/bin/ln -s "${staging##*/}/FocusBar.app" "$staging/publish-link"
# BSD mv -h replaces the destination symlink, not the app it points to.
/bin/mv -f -h "$staging/publish-link" "$destination"
printf 'Built %s\nVersion directory: %s\n' "$destination" "$staging"
