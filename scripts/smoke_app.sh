#!/bin/sh

set -u

usage() {
    printf '%s\n' 'Usage: scripts/smoke_app.sh [--help] [--lifecycle-smoke-test]'
    printf '%s\n' 'Build the unsigned Debug app and run its private-pipe sidecar smoke test.'
}

smoke_argument='--sidecar-smoke-test'
case "${1-}" in
    '') ;;
    --help|-h)
        usage
        exit 0
        ;;
    --lifecycle-smoke-test)
        smoke_argument='--lifecycle-smoke-test'
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 64
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data_dir="${TMPDIR:-/tmp}/magic-voice-smoke-derived-data"

xcodebuild \
    -project "$repo_root/magic-voice.xcodeproj" \
    -scheme magic-voice \
    -configuration Debug \
    -derivedDataPath "$derived_data_dir" \
    CODE_SIGNING_ALLOWED=NO \
    build || exit $?

app_binary="$derived_data_dir/Build/Products/Debug/Magic Voice.app/Contents/MacOS/Magic Voice"
if [ ! -x "$app_binary" ]; then
    printf 'Smoke test binary not found: %s\n' "$app_binary" >&2
    exit 66
fi

"$app_binary" "$smoke_argument"
