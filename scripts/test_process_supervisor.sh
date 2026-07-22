#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/magic-voice-supervisor.XXXXXX")"
derived_data_path="$test_directory/DerivedData"
fixture_path="$test_directory/process-tree-worker"

cleanup() {
    while IFS= read -r pid_file; do
        pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done < <(find "$test_directory" -name '*.pid' -type f 2>/dev/null || true)
    rm -rf "$test_directory"
}
trap cleanup EXIT

wait_for_file() {
    local file_path="$1"
    local attempts="${2:-100}"
    for ((attempt = 0; attempt < attempts; attempt++)); do
        [[ -f "$file_path" ]] && return 0
        sleep 0.05
    done
    echo "Timed out waiting for fixture file: $file_path" >&2
    return 1
}

pid_is_live() {
    local pid="$1"
    local state
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

wait_for_pid_exit() {
    local pid="$1"
    local attempts="${2:-80}"
    for ((attempt = 0; attempt < attempts; attempt++)); do
        pid_is_live "$pid" || return 0
        sleep 0.05
    done
    echo "Process $pid remained alive after the bounded timeout" >&2
    return 1
}

read_pid() {
    tr -d '[:space:]' < "$1"
}

echo "Building the unsigned app and native supervisor..."
xcodebuild \
    -project "$repository_root/magic-voice.xcodeproj" \
    -scheme magic-voice \
    -configuration Debug \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

app_binary="$derived_data_path/Build/Products/Debug/Magic Voice.app/Contents/MacOS/Magic Voice"
supervisor="$derived_data_path/Build/Products/Debug/Magic Voice.app/Contents/MacOS/MagicVoiceProcessSupervisor"
[[ -x "$app_binary" ]] || { echo "Built app executable is missing" >&2; exit 1; }
[[ -x "$supervisor" ]] || { echo "Embedded process supervisor is missing" >&2; exit 1; }

xcrun clang \
    -std=c17 \
    -Wall \
    -Wextra \
    -Werror \
    "$repository_root/scripts/fixtures/process_tree_worker.c" \
    -o "$fixture_path"

echo "Checking cooperative JSONLines shutdown..."
cooperative_state="$test_directory/cooperative"
mkdir -p "$cooperative_state"
fifo_path="$cooperative_state/stdin"
mkfifo "$fifo_path"
exec 3<>"$fifo_path"
"$supervisor" \
    --parent-pid "$$" \
    -- "$fixture_path" cooperative "$cooperative_state" \
    <"$fifo_path" &
cooperative_supervisor_pid=$!
printf '%s\n' "$cooperative_supervisor_pid" > "$cooperative_state/supervisor.pid"
wait_for_file "$cooperative_state/ready"
printf '%s\n' '{"type":"shutdown"}' >&3
wait "$cooperative_supervisor_pid"
exec 3>&-
wait_for_file "$cooperative_state/graceful"
[[ ! -e "$cooperative_state/signal.worker" ]] || {
    echo "Cooperative worker received a termination signal" >&2
    exit 1
}

echo "Checking TERM-to-KILL process-group escalation..."
escalation_state="$test_directory/escalation"
mkdir -p "$escalation_state"
"$supervisor" \
    --parent-pid "$$" \
    -- "$fixture_path" ignore-term "$escalation_state" \
    </dev/null &
escalation_supervisor_pid=$!
printf '%s\n' "$escalation_supervisor_pid" > "$escalation_state/supervisor.pid"
wait_for_file "$escalation_state/ready"
wait_for_file "$escalation_state/worker.pid"
wait_for_file "$escalation_state/grandchild.pid"
escalation_worker_pid="$(read_pid "$escalation_state/worker.pid")"
escalation_grandchild_pid="$(read_pid "$escalation_state/grandchild.pid")"
kill -TERM "$escalation_supervisor_pid"
wait "$escalation_supervisor_pid" 2>/dev/null || true
wait_for_file "$escalation_state/signal.worker"
wait_for_file "$escalation_state/signal.grandchild"
wait_for_pid_exit "$escalation_worker_pid"
wait_for_pid_exit "$escalation_grandchild_pid"

echo "Checking rapid generation replacement isolation..."
generation_a_state="$test_directory/generation-a"
generation_b_state="$test_directory/generation-b"
mkdir -p "$generation_a_state" "$generation_b_state"
"$supervisor" --parent-pid "$$" -- "$fixture_path" ignore-term "$generation_a_state" </dev/null &
generation_a_supervisor_pid=$!
printf '%s\n' "$generation_a_supervisor_pid" > "$generation_a_state/supervisor.pid"
wait_for_file "$generation_a_state/ready"
wait_for_file "$generation_a_state/worker.pid"
wait_for_file "$generation_a_state/grandchild.pid"
"$supervisor" --parent-pid "$$" -- "$fixture_path" ignore-term "$generation_b_state" </dev/null &
generation_b_supervisor_pid=$!
printf '%s\n' "$generation_b_supervisor_pid" > "$generation_b_state/supervisor.pid"
wait_for_file "$generation_b_state/ready"
wait_for_file "$generation_b_state/worker.pid"
wait_for_file "$generation_b_state/grandchild.pid"
generation_b_worker_pid="$(read_pid "$generation_b_state/worker.pid")"
generation_b_grandchild_pid="$(read_pid "$generation_b_state/grandchild.pid")"
kill -TERM "$generation_a_supervisor_pid"
wait "$generation_a_supervisor_pid" 2>/dev/null || true
pid_is_live "$generation_b_supervisor_pid"
pid_is_live "$generation_b_worker_pid"
pid_is_live "$generation_b_grandchild_pid"
kill -TERM "$generation_b_supervisor_pid"
wait "$generation_b_supervisor_pid" 2>/dev/null || true
wait_for_pid_exit "$generation_b_worker_pid"
wait_for_pid_exit "$generation_b_grandchild_pid"

echo "Checking real built-app host death..."
host_death_state="$test_directory/host-death"
mkdir -p "$host_death_state"
"$app_binary" \
    --process-supervisor-host-death-smoke \
    "$fixture_path" \
    "$host_death_state" &
app_pid=$!
wait_for_file "$host_death_state/ready"
wait_for_file "$host_death_state/app.pid"
wait_for_file "$host_death_state/supervisor.pid"
wait_for_file "$host_death_state/worker.pid"
wait_for_file "$host_death_state/grandchild.pid"
recorded_app_pid="$(read_pid "$host_death_state/app.pid")"
host_supervisor_pid="$(read_pid "$host_death_state/supervisor.pid")"
host_worker_pid="$(read_pid "$host_death_state/worker.pid")"
host_grandchild_pid="$(read_pid "$host_death_state/grandchild.pid")"
[[ "$recorded_app_pid" == "$app_pid" ]] || {
    echo "Built app recorded unexpected PID $recorded_app_pid (expected $app_pid)" >&2
    exit 1
}
kill -KILL "$app_pid"
wait "$app_pid" 2>/dev/null || true
wait_for_pid_exit "$host_supervisor_pid"
wait_for_pid_exit "$host_worker_pid"
wait_for_pid_exit "$host_grandchild_pid"

echo "PASS: cooperative, escalation, generation isolation, and built-app host-death checks"
