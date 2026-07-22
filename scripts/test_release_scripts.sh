#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"

scripts=(
    fetch_uv.sh
    sign_macos_release.sh
    verify_macos_release.sh
    package_macos_release.sh
    notarize_macos_release.sh
    release_macos.sh
)

for script in "${scripts[@]}"; do
    bash -n "$script_directory/$script"
    "$script_directory/$script" --help >/dev/null
done

"$script_directory/fetch_uv.sh" --dry-run --output /tmp/magic-voice-dry-run/uv >/dev/null
"$script_directory/sign_macos_release.sh" --dry-run /tmp/MagicVoice.app >/dev/null
"$script_directory/verify_macos_release.sh" --dry-run /tmp/MagicVoice.app >/dev/null
"$script_directory/package_macos_release.sh" \
    --dry-run --output /tmp/MagicVoice.dmg /tmp/MagicVoice.app >/dev/null
"$script_directory/notarize_macos_release.sh" --dry-run /tmp/MagicVoice.dmg >/dev/null

dry_run_output="$(
    env -u MARKETING_VERSION -u BUILD_NUMBER -u DEVELOPER_ID_APPLICATION \
        -u NOTARYTOOL_PROFILE "$script_directory/release_macos.sh" --dry-run
)"
[[ "$dry_run_output" == *"Magic Voice release dry run"* ]]
[[ "$dry_run_output" == *"Contents/Resources/uv"* ]]
[[ "$dry_run_output" == *"--options runtime"* ]]

set +e
missing_input_output="$(
    env -u MARKETING_VERSION -u BUILD_NUMBER -u DEVELOPER_ID_APPLICATION \
        -u NOTARYTOOL_PROFILE "$script_directory/release_macos.sh" 2>&1
)"
missing_input_status=$?
set -e
[[ "$missing_input_status" -ne 0 ]]
[[ "$missing_input_output" == *"set MARKETING_VERSION"* ]]

echo "Release script syntax, help, and credential-free dry runs passed."
