#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: verify_macos_release.sh [options] APP_OR_DMG

Verifies Developer ID signatures, secure timestamps, Hardened Runtime, bundled
runtime resources, and production entitlements. A DMG must contain exactly one
top-level app.

Options:
  --dry-run   Describe the checks without reading the target.
  -h, --help  Show this help.
EOF
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
dry_run=false

# shellcheck source=scripts/release_common.sh
source "$script_directory/release_common.sh"

while (($# > 0)); do
    case "$1" in
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

target_path="$1"
if [[ "$dry_run" == true ]]; then
    echo "Would verify Developer ID signatures, timestamps, Hardened Runtime,"
    echo "production entitlements, bundled runtime resources, and the signed"
    echo "arm64 MagicVoiceProcessSupervisor in: $target_path"
    exit 0
fi

release_require_command codesign
release_require_command file

temporary_directory=""
mounted=false
dmg_team_identifier=""
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$temporary_directory/mount" -quiet || true
    fi
    if [[ -n "$temporary_directory" ]]; then
        rm -rf "$temporary_directory"
    fi
}
trap cleanup EXIT

if [[ -f "$target_path" && "$target_path" == *.dmg ]]; then
    release_require_command hdiutil
    codesign --verify --strict --verbose=2 "$target_path"
    dmg_signature="$(codesign -dvvv "$target_path" 2>&1)"
    [[ "$dmg_signature" == *"Authority=Developer ID Application:"* ]] || \
        release_fail "DMG is not signed with Developer ID Application"
    [[ "$dmg_signature" == *"Timestamp="* ]] || \
        release_fail "DMG signature has no secure timestamp"
    dmg_team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$dmg_signature" | head -n 1)"
    [[ -n "$dmg_team_identifier" && "$dmg_team_identifier" != "not set" ]] || \
        release_fail "DMG signature has no Team ID"

    temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/magic-voice-verify.XXXXXX")"
    mkdir -p "$temporary_directory/mount"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$temporary_directory/mount" "$target_path"
    mounted=true
    app_paths=()
    while IFS= read -r -d '' candidate; do
        app_paths+=("$candidate")
    done < <(find "$temporary_directory/mount" -maxdepth 1 -type d -name '*.app' -print0)
    ((${#app_paths[@]} == 1)) || \
        release_fail "DMG must contain exactly one top-level app bundle"
    app_path="${app_paths[0]}"
else
    app_path="$target_path"
fi

[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || \
    release_fail "not a macOS app bundle: $app_path"

release_validate_app_resources "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

app_signature="$(codesign -dvvv "$app_path" 2>&1)"
[[ "$app_signature" == *"Authority=Developer ID Application:"* ]] || \
    release_fail "app is not signed with Developer ID Application"
[[ "$app_signature" == *"Timestamp="* ]] || \
    release_fail "app signature has no secure timestamp"
[[ "$app_signature" == *"runtime"* ]] || \
    release_fail "app signature does not enable Hardened Runtime"
team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$app_signature" | head -n 1)"
[[ -n "$team_identifier" && "$team_identifier" != "not set" ]] || \
    release_fail "app signature has no Team ID"
if [[ -n "$dmg_team_identifier" && "$dmg_team_identifier" != "$team_identifier" ]]; then
    release_fail "DMG and contained app have different Team IDs"
fi

native_code_count=0
supervisor_path="$app_path/Contents/MacOS/MagicVoiceProcessSupervisor"
supervisor_signature_verified=false
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    [[ "$file_type" == Mach-O* ]] || continue

    codesign --verify --strict "$candidate"
    candidate_signature="$(codesign -dvvv "$candidate" 2>&1)"
    [[ "$candidate_signature" == *"Authority=Developer ID Application:"* ]] || \
        release_fail "native code is not Developer ID signed: $candidate"
    [[ "$candidate_signature" == *"TeamIdentifier=$team_identifier"* ]] || \
        release_fail "native code has a different Team ID: $candidate"
    [[ "$candidate_signature" == *"runtime"* ]] || \
        release_fail "native code lacks Hardened Runtime: $candidate"
    [[ "$candidate_signature" == *"Timestamp="* ]] || \
        release_fail "native code has no secure timestamp: $candidate"
    if [[ "$candidate" -ef "$supervisor_path" ]]; then
        supervisor_signature_verified=true
    fi
    native_code_count=$((native_code_count + 1))
done < <(find "$app_path" -type f -print0)
((native_code_count > 0)) || release_fail "app contains no Mach-O code"
[[ "$supervisor_signature_verified" == true ]] || \
    release_fail "process supervisor did not pass Developer ID signature verification"

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
[[ "$app_entitlements" != *"com.apple.security.get-task-allow"* ]] || \
    release_fail "production app contains com.apple.security.get-task-allow"
[[ "$app_entitlements" == *"com.apple.security.cs.disable-library-validation"* ]] || \
    release_fail "app is missing the managed-runtime library-validation entitlement"

echo "Verified $native_code_count Developer ID-signed Mach-O files."
echo "Release signature preflight passed: $target_path"
