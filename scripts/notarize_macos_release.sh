#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: notarize_macos_release.sh [options] DMG_PATH

Runs local signature preflight, submits a signed DMG with notarytool, staples
and validates the accepted ticket, then verifies it with Gatekeeper.

Authentication:
  Store credentials once with `xcrun notarytool store-credentials`, then set
  NOTARYTOOL_PROFILE to that Keychain profile. No Apple password or API key is
  accepted through this script's environment, avoiding accidental secret logs.

Options:
  --keychain-profile NAME  Defaults to NOTARYTOOL_PROFILE.
  --timeout DURATION       notarytool timeout (default: 30m).
  --dry-run                Print the intended notarization operations only.
  -h, --help               Show this help.
EOF
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
keychain_profile="${NOTARYTOOL_PROFILE:-}"
timeout="30m"
dry_run=false

# shellcheck source=scripts/release_common.sh
source "$script_directory/release_common.sh"

while (($# > 0)); do
    case "$1" in
        --keychain-profile)
            (($# >= 2)) || release_fail "--keychain-profile requires a value"
            keychain_profile="$2"
            shift 2
            ;;
        --timeout)
            (($# >= 2)) || release_fail "--timeout requires a value"
            timeout="$2"
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
dmg_path="$1"

if [[ "$dry_run" == true ]]; then
    echo "Would run local signature preflight for: $dmg_path"
    echo "Would submit with a notarytool Keychain profile (profile name not printed)."
    echo "Would staple, validate, and run spctl after acceptance."
    exit 0
fi

[[ -n "$keychain_profile" ]] || \
    release_fail "set NOTARYTOOL_PROFILE or pass --keychain-profile; store credentials with xcrun notarytool store-credentials"
[[ -f "$dmg_path" && "$dmg_path" == *.dmg ]] || \
    release_fail "not a DMG: $dmg_path"

release_require_command plutil
release_require_command spctl
release_require_command xcrun

"$script_directory/verify_macos_release.sh" "$dmg_path"

dmg_directory="$(cd "$(dirname "$dmg_path")" && pwd -P)"
dmg_path="$dmg_directory/$(basename "$dmg_path")"
result_path="$dmg_path.notary-result.json"
log_path="$dmg_path.notary-log.json"

echo "Submitting $(basename "$dmg_path") to Apple's notary service..."
set +e
xcrun notarytool submit \
    --keychain-profile "$keychain_profile" \
    --wait \
    --timeout "$timeout" \
    --no-progress \
    --output-format json \
    "$dmg_path" > "$result_path"
submit_status=$?
set -e

notary_status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"
submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
if [[ "$submit_status" -ne 0 || "$notary_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log \
            --keychain-profile "$keychain_profile" \
            "$submission_id" "$log_path" || true
    fi
    release_fail "notarization was not accepted (status: ${notary_status:-unknown}); see $result_path and $log_path"
fi

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
echo "Notarized, stapled, and Gatekeeper-verified: $dmg_path"
