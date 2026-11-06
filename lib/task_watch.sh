#!/bin/bash
#
# lib/task_watch.sh - Status watch: terminal checkpoint as soon as a task finishes
# Source SEVENTH - needs checkpoint_sync (checkpoint.sh), NODEODM_PORT / _tapisJobOwner
#
# While the worker has a task, a background loop polls the local NodeODX
#   http://localhost:$NODEODM_PORT/task/<uuid>/info?token=$_tapisJobOwner
# (the same endpoint the monitor loop uses; the uuid is TASK_UUID as discovered by
# wait_for_task). On the first terminal status (COMPLETED / FAILED / CANCELED) it runs
#   checkpoint_sync terminal <uuid>
# synchronously and then drops a done-file. The monitor loop calls task_watch_wait before it
# reports the task onward, and the EXIT trap calls it before its own (no-op if synced)
# checkpoint_sync "exit".
#
# The loop uses `command curl` rather than the verbose curl wrapper from common.sh so that
# polling every few seconds does not flood the log.
#

[[ -n "${_LIB_TASK_WATCH_SH:-}" ]] && return 0
readonly _LIB_TASK_WATCH_SH=1

TASK_WATCH_PID=""
TASK_WATCH_UUID=""

task_watch_done_file() {
    printf '%s/.task_watch.%s.done\n' "${WORK_DIR:-${TMPDIR:-/tmp}}" "$1"
}

# Terminal NodeODM status name from an /info response on stdin ("" if not terminal)
task_watch_terminal_status() {
    python3 -c '
import json
import sys

names = {30: "FAILED", 40: "COMPLETED", 50: "CANCELED"}
try:
    status = json.loads(sys.stdin.read()).get("status")
    code = status.get("code") if isinstance(status, dict) else status
    print(names.get(int(code), ""))
except Exception:
    print("")
' 2>/dev/null
}

# task_watch_start <uuid>: start (once per task) the background status watch.
task_watch_start() {
    local uuid="${1:-${TASK_UUID:-}}"
    if [ -z "$uuid" ] || [ -z "${NODEODM_CHECKPOINT_ROOT:-}" ]; then
        return 0
    fi
    if [ "$TASK_WATCH_UUID" = "$uuid" ] && [ -n "$TASK_WATCH_PID" ] && kill -0 "$TASK_WATCH_PID" 2>/dev/null; then
        return 0
    fi
    local done_file parent interval
    done_file=$(task_watch_done_file "$uuid")
    rm -f "$done_file" 2>/dev/null
    parent=$$
    interval="${NODEODM_TASK_WATCH_INTERVAL_SECONDS:-5}"
    [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -gt 0 ] || interval=5

    (
        set +e
        while kill -0 "$parent" 2>/dev/null; do
            local resp status
            resp=$(command curl -s --max-time 15 "http://localhost:${NODEODM_PORT:-3001}/task/$uuid/info?token=${_tapisJobOwner:-}" 2>/dev/null)
            status=$(printf '%s' "$resp" | task_watch_terminal_status)
            if [ -n "$status" ]; then
                echo "[task-watch] task $uuid reached $status; writing terminal checkpoint"
                STATUS_RESPONSE="$resp"
                : > "$done_file.working"
                checkpoint_sync "terminal" "$uuid"
                echo "$status" > "$done_file"
                rm -f "$done_file.working"
                echo "[task-watch] terminal checkpoint finished for $uuid"
                exit 0
            fi
            sleep "$interval"
        done
    ) &
    TASK_WATCH_PID=$!
    TASK_WATCH_UUID="$uuid"
    echo "[task-watch] watching task $uuid (pid $TASK_WATCH_PID, every ${interval}s)"
}

# task_watch_wait [uuid]: block (bounded by NODEODM_TASK_WATCH_WAIT_SECONDS) until the watch has
# finished the terminal checkpoint, but only when there is something to wait for: the watcher
# is mid-checkpoint (.working file) or the task's last known status is terminal. A task that is
# still running (EXIT trap during a kill) returns immediately. If the task is terminal and
# there is no live watcher and no done-file, the terminal sync runs inline (idempotent: a
# synced manifest makes it a no-op).
task_watch_wait() {
    local uuid="${1:-}"
    if [ -z "$uuid" ] || [ -z "${NODEODM_CHECKPOINT_ROOT:-}" ]; then
        return 0
    fi
    local done_file waited=0 max code terminal=0
    done_file=$(task_watch_done_file "$uuid")
    max="${NODEODM_TASK_WATCH_WAIT_SECONDS:-3600}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=3600
    code=$(checkpoint_task_status_code "$uuid")
    if [ "$code" = "30" ] || [ "$code" = "40" ] || [ "$code" = "50" ]; then
        terminal=1
    fi

    if [ "$TASK_WATCH_UUID" = "$uuid" ] && [ -n "$TASK_WATCH_PID" ] && { [ "$terminal" = "1" ] || [ -f "$done_file.working" ]; }; then
        while [ ! -f "$done_file" ] && kill -0 "$TASK_WATCH_PID" 2>/dev/null && [ "$waited" -lt "$max" ]; do
            sleep 1
            waited=$((waited + 1))
        done
    fi
    if [ -f "$done_file" ] || [ "$terminal" != "1" ]; then
        return 0
    fi
    if [ "$TASK_WATCH_UUID" = "$uuid" ] && [ -n "$TASK_WATCH_PID" ] && kill -0 "$TASK_WATCH_PID" 2>/dev/null; then
        echo "[task-watch] terminal checkpoint still running after ${max}s; not waiting longer"
        return 0
    fi
    checkpoint_sync "terminal" "$uuid"
    return 0
}

task_watch_stop() {
    if [ -n "${TASK_WATCH_PID:-}" ] && kill -0 "$TASK_WATCH_PID" 2>/dev/null; then
        kill "$TASK_WATCH_PID" 2>/dev/null || true
    fi
    TASK_WATCH_PID=""
    TASK_WATCH_UUID=""
}
