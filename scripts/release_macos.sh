#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: release_macos.sh [options]

Builds an unsigned arm64 Release archive, injects the checksum-verified bundled
uv executable, signs the app inside-out, creates a signed DMG, notarizes it,
staples it, and runs Gatekeeper verification.

Required for a real release (option or environment):
  --marketing-version VERSION  MARKETING_VERSION (for example 1.0.0)
  --build-number NUMBER        BUILD_NUMBER (positive integer)
  --identity ID                DEVELOPER_ID_APPLICATION
  --keychain-profile NAME      NOTARYTOOL_PROFILE

Options:
  --output-directory PATH  Defaults to dist/release.
  --archive-path PATH      Defaults to a versioned path under dist/archive.
  --derived-data PATH      Defaults to build/ReleaseDerivedData.
  --notary-timeout VALUE   Defaults to 30m.
  --dry-run                Print the complete plan without network, build,
                           certificates, or Apple credentials.
  -h, --help               Show this help.

The Keychain profile name is not a secret. Store credentials with notarytool;
this script never accepts or prints an Apple password or private API key.
EOF
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
marketing_version="${MARKETING_VERSION:-}"
build_number="${BUILD_NUMBER:-}"
identity="${DEVELOPER_ID_APPLICATION:-}"
keychain_profile="${NOTARYTOOL_PROFILE:-}"
output_directory="$repository_root/dist/release"
archive_path=""
derived_data_path="$repository_root/build/ReleaseDerivedData"
notary_timeout="30m"
dry_run=false

# shellcheck source=scripts/release_common.sh
source "$script_directory/release_common.sh"

while (($# > 0)); do
    case "$1" in
        --marketing-version)
            (($# >= 2)) || release_fail "--marketing-version requires a value"
            marketing_version="$2"
            shift 2
            ;;
        --build-number)
            (($# >= 2)) || release_fail "--build-number requires a value"
            build_number="$2"
            shift 2
            ;;
        --identity)
            (($# >= 2)) || release_fail "--identity requires a value"
            identity="$2"
            shift 2
            ;;
        --keychain-profile)
            (($# >= 2)) || release_fail "--keychain-profile requires a value"
            keychain_profile="$2"
            shift 2
            ;;
        --output-directory)
            (($# >= 2)) || release_fail "--output-directory requires a value"
            output_directory="$2"
            shift 2
            ;;
        --archive-path)
            (($# >= 2)) || release_fail "--archive-path requires a value"
            archive_path="$2"
            shift 2
            ;;
        --derived-data)
            (($# >= 2)) || release_fail "--derived-data requires a value"
            derived_data_path="$2"
            shift 2
            ;;
        --notary-timeout)
            (($# >= 2)) || release_fail "--notary-timeout requires a value"
            notary_timeout="$2"
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
        *)
            release_fail "unknown option: $1"
            ;;
    esac
done

if [[ "$dry_run" == true ]]; then
    marketing_version="${marketing_version:-0.0.0}"
    build_number="${build_number:-1}"
else
    [[ -n "$marketing_version" ]] || \
        release_fail "set MARKETING_VERSION or pass --marketing-version"
    [[ -n "$build_number" ]] || \
        release_fail "set BUILD_NUMBER or pass --build-number"
    [[ -n "$identity" ]] || \
        release_fail "set DEVELOPER_ID_APPLICATION or pass --identity"
    [[ -n "$keychain_profile" ]] || \
        release_fail "set NOTARYTOOL_PROFILE or pass --keychain-profile"
fi

[[ "$marketing_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || \
    release_fail "marketing version must look like 1.0 or 1.0.0"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || \
    release_fail "build number must be a positive integer"

case "$output_directory" in
    /*) ;;
    *) output_directory="$repository_root/$output_directory" ;;
esac
case "$derived_data_path" in
    /*) ;;
    *) derived_data_path="$repository_root/$derived_data_path" ;;
esac
if [[ -z "$archive_path" ]]; then
    archive_path="$repository_root/dist/archive/Magic-Voice-${marketing_version}-${build_number}.xcarchive"
else
    case "$archive_path" in
        /*) ;;
        *) archive_path="$repository_root/$archive_path" ;;
    esac
fi
[[ "$archive_path" == *.xcarchive ]] || release_fail "--archive-path must end in .xcarchive"

app_path="$archive_path/Products/Applications/Magic Voice.app"
dmg_path="$output_directory/Magic-Voice-${marketing_version}-${build_number}.dmg"
uv_path="$app_path/Contents/Resources/uv"

xcodebuild_arguments=(
    -project "$repository_root/magic-voice.xcodeproj"
    -scheme magic-voice
    -configuration Release
    -destination generic/platform=macOS
    -archivePath "$archive_path"
    -derivedDataPath "$derived_data_path"
    archive
    ARCHS=arm64
    ONLY_ACTIVE_ARCH=NO
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    MARKETING_VERSION="$marketing_version"
    CURRENT_PROJECT_VERSION="$build_number"
)

if [[ "$dry_run" == true ]]; then
    echo "Magic Voice release dry run"
    echo "Archive: $archive_path"
    echo "App:     $app_path"
    echo "DMG:     $dmg_path"
    echo "Build command:"
    release_print_command xcodebuild "${xcodebuild_arguments[@]}"
    "$script_directory/fetch_uv.sh" --dry-run --output "$uv_path"
    "$script_directory/sign_macos_release.sh" --dry-run "$app_path"
    "$script_directory/package_macos_release.sh" --dry-run --output "$dmg_path" "$app_path"
    "$script_directory/notarize_macos_release.sh" --dry-run "$dmg_path"
    exit 0
fi

release_require_command xcodebuild
[[ ! -e "$archive_path" ]] || release_fail "refusing to overwrite archive: $archive_path"
[[ ! -e "$dmg_path" ]] || release_fail "refusing to overwrite DMG: $dmg_path"
mkdir -p "$(dirname "$archive_path")" "$output_directory" "$derived_data_path"

echo "Building unsigned arm64 Release archive..."
xcodebuild "${xcodebuild_arguments[@]}"
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || \
    release_fail "archive did not contain the expected app: $app_path"

archived_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
archived_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
[[ "$archived_version" == "$marketing_version" ]] || \
    release_fail "archived version is $archived_version, expected $marketing_version"
[[ "$archived_build" == "$build_number" ]] || \
    release_fail "archived build is $archived_build, expected $build_number"

"$script_directory/fetch_uv.sh" --output "$uv_path"
release_validate_app_resources "$app_path"

"$script_directory/sign_macos_release.sh" --identity "$identity" "$app_path"
"$script_directory/package_macos_release.sh" \
    --identity "$identity" --output "$dmg_path" "$app_path"
"$script_directory/notarize_macos_release.sh" \
    --keychain-profile "$keychain_profile" --timeout "$notary_timeout" "$dmg_path"

echo
echo "Release pipeline completed: $dmg_path"
