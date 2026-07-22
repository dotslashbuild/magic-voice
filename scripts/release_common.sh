#!/bin/bash

# Shared helpers for the macOS direct-distribution scripts. This file is meant
# to be sourced; entry-point scripts enable strict mode themselves.

release_fail() {
    echo "error: $*" >&2
    exit 1
}

release_require_command() {
    command -v "$1" >/dev/null 2>&1 || release_fail "$1 is required"
}

release_print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

release_validate_app_resources() {
    local app_path="$1"
    local resources_path="$app_path/Contents/Resources"
    local resource

    [[ -f "$app_path/Contents/Info.plist" ]] || \
        release_fail "app Info.plist is missing: $app_path"
    for resource in sidecar.py pyproject.toml uv.lock uv; do
        [[ -f "$resources_path/$resource" ]] || \
            release_fail "required bundled resource is missing: $resources_path/$resource"
    done
    [[ -x "$resources_path/uv" ]] || \
        release_fail "bundled uv is not executable: $resources_path/uv"

    release_require_command lipo
    if ! lipo -archs "$resources_path/uv" | tr ' ' '\n' | grep -qx arm64; then
        release_fail "bundled uv does not contain arm64 code: $resources_path/uv"
    fi
}
