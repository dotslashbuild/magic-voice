#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: package_macos_release.sh [options] APP_PATH

Creates a compressed DMG with a fixed top-level layout: one signed Magic Voice
app plus an Applications symlink. The DMG is then Developer ID signed.

Options:
  --output PATH  Output DMG path (required).
  --identity ID  Developer ID Application identity. Defaults to
                 DEVELOPER_ID_APPLICATION.
  --dry-run      Print the intended packaging operations only.
  -h, --help     Show this help.
EOF
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
identity="${DEVELOPER_ID_APPLICATION:-}"
output_path=""
dry_run=false

# shellcheck source=scripts/release_common.sh
source "$script_directory/release_common.sh"

while (($# > 0)); do
    case "$1" in
        --output)
            (($# >= 2)) || release_fail "--output requires a value"
            output_path="$2"
            shift 2
            ;;
        --identity)
            (($# >= 2)) || release_fail "--identity requires a value"
            identity="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            release_fail "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

(($# == 1)) || {
    usage >&2
    exit 2
}
[[ -n "$output_path" ]] || release_fail "--output is required"
app_path="$1"

if [[ "$dry_run" == true ]]; then
    echo "Would verify and package: $app_path"
    echo "Would create fixed layout: Magic Voice.app + Applications symlink"
    echo "Would Developer ID sign DMG: $output_path"
    exit 0
fi

[[ -n "$identity" ]] || \
    release_fail "set DEVELOPER_ID_APPLICATION or pass --identity"
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || \
    release_fail "not a macOS app bundle: $app_path"

case "$output_path" in
    /*) ;;
    *) output_path="$(pwd -P)/$output_path" ;;
esac
[[ "$output_path" == *.dmg ]] || release_fail "--output must end in .dmg"
[[ ! -e "$output_path" ]] || release_fail "refusing to overwrite existing DMG: $output_path"

release_require_command codesign
release_require_command ditto
release_require_command hdiutil

"$script_directory/verify_macos_release.sh" "$app_path"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/magic-voice-dmg.XXXXXX")"
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

staging_path="$temporary_directory/staging"
mkdir -p "$staging_path"
ditto "$app_path" "$staging_path/Magic Voice.app"
ln -s /Applications "$staging_path/Applications"

# Normalize staging timestamps and ordering inputs. The secure signature and DMG
# filesystem metadata prevent byte-for-byte reproducibility, but identical app
# inputs always produce the same names and top-level layout.
while IFS= read -r -d '' staged_path; do
    touch -h -t 202001010000 "$staged_path"
done < <(find "$staging_path" -depth -print0)

mkdir -p "$(dirname "$output_path")"
hdiutil create \
    -srcfolder "$staging_path" \
    -volname "Magic Voice" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$output_path"

codesign --force --sign "$identity" --timestamp "$output_path"
"$script_directory/verify_macos_release.sh" "$output_path"
echo "Packaged signed DMG: $output_path"
