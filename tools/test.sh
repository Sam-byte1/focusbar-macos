#!/bin/bash
# Compile and run the standalone @main model tests, without an app bundle.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
fail() { printf 'test: %s\n' "$*" >&2; exit 1; }
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(CDPATH= cd -- "$script_dir/.." && pwd -P)"
source_root="$workspace/TomatoBar"
output="$workspace/build"
while (($#)); do
    case "$1" in
        --source|--output)
            (($# >= 2)) || fail "Missing value for $1"
            [[ "$2" == /* ]] || fail "$1 requires an absolute path"
            case "$1" in --source) source_root="$2" ;; --output) output="$2" ;; esac
            shift 2 ;;
        --help|-h)
            printf 'Usage: %s [--source /absolute/upstream-root] [--output /absolute/build-directory]\n' "$0"
            exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -d "$source_root" ]] || fail "Source root not found: $source_root"
source_root="$(CDPATH= cd -- "$source_root" && pwd -P)"
cwd="$(pwd -P)"
case "$cwd/" in
    "$source_root/"*|"$workspace/TomatoBar/"*|"$workspace"/download-*)
        fail 'Refusing to run from downloaded content; invoke tools/test.sh from the workspace.' ;;
esac
[[ ! -L "$output" ]] || fail 'Output directory must not be a symlink'
/bin/mkdir -p -- "$output"
output="$(CDPATH= cd -- "$output" && pwd -P)"
case "$output/" in
    "$source_root/"*|"$workspace/TomatoBar/"*|"$script_dir/"*|"$workspace"/download-*)
        fail 'Output must be outside downloaded source and tools directories' ;;
esac
[[ "$output" != / && "$output" != "$workspace" ]] || fail 'Choose a dedicated build directory'
sources=("$source_root/TomatoBar/State.swift" "$source_root/TomatoBar/FocusData.swift" "$source_root/TomatoBar/FocusStore.swift" "$source_root/TomatoBar/Statistics.swift" "$workspace/tests/TimerModelTests.swift" "$workspace/tests/StatisticsTests.swift" "$workspace/tests/StorageTests.swift")
for source_file in "${sources[@]}"; do
    [[ -f "$source_file" && ! -L "$source_file" ]] || fail "Missing or symlinked input: $source_file"
done
[[ ! -L "$output/tests" ]] || fail 'Test output directory must not be a symlink'
/bin/mkdir -p "$output/tests"
binary="$output/tests/timer-tests"
[[ ! -L "$binary" && ! -d "$binary" ]] || fail 'Refusing to replace a symlink or directory at timer-tests'
staging="$(/usr/bin/mktemp -d "$output/tests/.timer-tests.XXXXXX")"
/bin/mkdir "$staging/module-cache"
sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
arch="$(/usr/bin/uname -m)"
case "$arch" in arm64|x86_64) ;; *) fail "Unsupported architecture: $arch" ;; esac
/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 5 -parse-as-library -sdk "$sdk" \
    -target "$arch-apple-macosx13.0" -D DEBUG -Onone -g \
    -module-cache-path "$staging/module-cache" \
    "${sources[@]}" -o "$staging/timer-tests"
/bin/mv -f "$staging/timer-tests" "$binary"
printf 'Running %s\n' "$binary"
"$binary"
coordinator_sources=(
    "$workspace/tests/CoordinatorTests.swift"
    "$source_root/TomatoBar/State.swift"
    "$source_root/TomatoBar/FocusData.swift"
    "$source_root/TomatoBar/FocusStore.swift"
    "$source_root/TomatoBar/Timer.swift"
    "$source_root/TomatoBar/Notifications.swift"
    "$source_root/TomatoBar/Player.swift"
)
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -sdk "$sdk" \
    -target "$arch-apple-macosx13.0" -module-cache-path "$staging/module-cache" \
    "${coordinator_sources[@]}" -o "$staging/coordinator-tests"
"$staging/coordinator-tests"
