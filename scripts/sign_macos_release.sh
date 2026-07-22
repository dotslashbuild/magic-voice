#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sign_macos_release.sh [options] APP_PATH

Signs an app inside-out with Developer ID Application, a secure timestamp, and
Hardened Runtime. Every Mach-O file is signed first, nested code bundles are
re-sealed depth-first, and the app is signed last with the release entitlements.

Options:
  --identity ID  Developer ID Application identity name or SHA-1 hash.
                 Defaults to DEVELOPER_ID_APPLICATION.
  --dry-run      Print the intended signing policy without requiring a cert.
  -h, --help     Show this help.
EOF
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
entitlements_path="$repository_root/magic-voice/magic-voice.entitlements"
identity="${DEVELOPER_ID_APPLICATION:-}"
dry_run=false

# shellcheck source=scripts/release_common.sh
source "$script_directory/release_common.sh"

while (($# > 0)); do
    case "$1" in
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

app_path="$1"

if [[ "$dry_run" == true ]]; then
    echo "Would sign every nested Mach-O in: $app_path"
    echo "Required helper: Contents/MacOS/MagicVoiceProcessSupervisor (arm64 Mach-O)"
    echo "Would re-sign nested bundles depth-first, then sign the app last."
    echo "Policy: Developer ID Application, --timestamp, --options runtime"
    echo "App entitlements: $entitlements_path"
    exit 0
fi

[[ -n "$identity" ]] || \
    release_fail "set DEVELOPER_ID_APPLICATION or pass --identity"
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || \
    release_fail "not a macOS app bundle: $app_path"
[[ -f "$entitlements_path" ]] || release_fail "release entitlements are missing: $entitlements_path"

release_require_command codesign
release_require_command file
release_require_command security
release_validate_app_resources "$app_path"

identity_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$identity" | head -n 1 || true)"
[[ -n "$identity_line" ]] || release_fail "codesigning identity not found: $identity"
[[ "$identity_line" == *"Developer ID Application:"* ]] || \
    release_fail "release signing requires a Developer ID Application identity"

sign_nested_target() {
    codesign --force --sign "$identity" --options runtime --timestamp "$1"
}

native_files=()
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    if [[ "$file_type" == Mach-O* ]]; then
        native_files+=("$candidate")
    fi
done < <(find "$app_path" -type f -print0)
((${#native_files[@]} > 0)) || release_fail "no Mach-O code found in app"

echo "Signing ${#native_files[@]} Mach-O files inside-out..."
for native_file in "${native_files[@]}"; do
    sign_nested_target "$native_file"
done

# Re-seal containers after their contents. `find -depth` guarantees children
# are visited before their parent bundle, without relying on broad shell globs.
while IFS= read -r -d '' code_bundle; do
    sign_nested_target "$code_bundle"
done < <(
    find "$app_path" -depth -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \
           -o -name '*.bundle' -o -name '*.plugin' -o -name '*.app' \) \
        ! -path "$app_path" -print0
)

codesign \
    --force \
    --sign "$identity" \
    --options runtime \
    --timestamp \
    --entitlements "$entitlements_path" \
    "$app_path"

"$script_directory/verify_macos_release.sh" "$app_path"
