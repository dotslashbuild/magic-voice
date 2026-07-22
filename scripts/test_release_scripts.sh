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
sign_dry_run_output="$(
    "$script_directory/sign_macos_release.sh" --dry-run /tmp/MagicVoice.app
)"
[[ "$sign_dry_run_output" == *"MagicVoiceProcessSupervisor (arm64 Mach-O)"* ]]
verify_dry_run_output="$(
    "$script_directory/verify_macos_release.sh" --dry-run /tmp/MagicVoice.app
)"
[[ "$verify_dry_run_output" == *"arm64 MagicVoiceProcessSupervisor"* ]]
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

release_test_directory="$(mktemp -d "${TMPDIR:-/tmp}/magic-voice-release-tests.XXXXXX")"
trap 'rm -rf "$release_test_directory"' EXIT
fixture_app="$release_test_directory/Magic Voice.app"
fixture_tools="$release_test_directory/tools"
mkdir -p "$fixture_app/Contents/Resources" "$fixture_app/Contents/MacOS" "$fixture_tools"
touch "$fixture_app/Contents/Info.plist"
touch "$fixture_app/Contents/Resources/sidecar.py"
touch "$fixture_app/Contents/Resources/pyproject.toml"
touch "$fixture_app/Contents/Resources/uv.lock"
touch "$fixture_app/Contents/Resources/uv"
touch "$fixture_app/Contents/MacOS/MagicVoiceProcessSupervisor"
chmod +x "$fixture_app/Contents/Resources/uv"
chmod +x "$fixture_app/Contents/MacOS/MagicVoiceProcessSupervisor"

printf '%s\n' '#!/bin/bash' 'echo "Mach-O 64-bit executable arm64"' > "$fixture_tools/file"
printf '%s\n' '#!/bin/bash' 'echo "arm64"' > "$fixture_tools/lipo"
chmod +x "$fixture_tools/file" "$fixture_tools/lipo"

PATH="$fixture_tools:$PATH" bash -c \
    'source "$1"; release_validate_app_resources "$2"' \
    release-resource-test "$script_directory/release_common.sh" "$fixture_app"

rm "$fixture_app/Contents/MacOS/MagicVoiceProcessSupervisor"
set +e
missing_supervisor_output="$(
    PATH="$fixture_tools:$PATH" bash -c \
        'source "$1"; release_validate_app_resources "$2"' \
        release-resource-test "$script_directory/release_common.sh" "$fixture_app" 2>&1
)"
missing_supervisor_status=$?
set -e
[[ "$missing_supervisor_status" -ne 0 ]]
[[ "$missing_supervisor_output" == *"required process supervisor is missing"* ]]

touch "$fixture_app/Contents/MacOS/MagicVoiceProcessSupervisor"
chmod +x "$fixture_app/Contents/MacOS/MagicVoiceProcessSupervisor"
printf '%s\n' \
    '#!/bin/bash' \
    'if [[ "$*" == *MagicVoiceProcessSupervisor* ]]; then echo "x86_64"; else echo "arm64"; fi' \
    > "$fixture_tools/lipo"
set +e
wrong_architecture_output="$(
    PATH="$fixture_tools:$PATH" bash -c \
        'source "$1"; release_validate_app_resources "$2"' \
        release-resource-test "$script_directory/release_common.sh" "$fixture_app" 2>&1
)"
wrong_architecture_status=$?
set -e
[[ "$wrong_architecture_status" -ne 0 ]]
[[ "$wrong_architecture_output" == *"process supervisor does not contain arm64 code"* ]]

printf '%s\n' '#!/bin/bash' 'echo "ASCII text"' > "$fixture_tools/file"
printf '%s\n' '#!/bin/bash' 'echo "arm64"' > "$fixture_tools/lipo"
set +e
non_macho_output="$(
    PATH="$fixture_tools:$PATH" bash -c \
        'source "$1"; release_validate_app_resources "$2"' \
        release-resource-test "$script_directory/release_common.sh" "$fixture_app" 2>&1
)"
non_macho_status=$?
set -e
[[ "$non_macho_status" -ne 0 ]]
[[ "$non_macho_output" == *"process supervisor is not a Mach-O executable"* ]]

echo "Release script syntax, dry runs, and required supervisor validation passed."
