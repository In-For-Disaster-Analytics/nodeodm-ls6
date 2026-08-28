#!/bin/bash
#
# lib/checkpoint.sh - Checkpoint sync, resume, manifest, restore
# Source SIXTH - needs TASK_UUID from task_monitor.sh, RUNTIME_DIR from common.sh
#

[[ -n "${_LIB_CHECKPOINT_SH:-}" ]] && return 0
readonly _LIB_CHECKPOINT_SH=1

# =============================================================================
# CHECKPOINT WRITE MANIFEST
# =============================================================================
checkpoint_write_manifest() {
    local checkpoint_dir="$1"
    local uuid="$2"
    local reason="${3:-periodic}"
    local status_json="${STATUS_RESPONSE:-}"
    local import_path=""
    local task_dir="$NODEODM_RUNTIME_DIR/data/$uuid"
    local scratch_runtime_dir
    local scratch_data_dir
    local scratch_task_dir

    scratch_runtime_dir=$(checkpoint_resolve_path "$NODEODM_RUNTIME_DIR")
    scratch_data_dir=$(checkpoint_resolve_path "$NODEODM_RUNTIME_DIR/data")
    scratch_task_dir=$(checkpoint_resolve_path "$task_dir")

    if [ -L "$NODEODM_RUNTIME_DIR/data/$uuid/images" ]; then
        import_path=$(readlink "$NODEODM_RUNTIME_DIR/data/$uuid/images" 2>/dev/null || true)
    fi

    if command -v python3 >/dev/null 2>&1; then
        CHECKPOINT_DIR="$checkpoint_dir" \
        CHECKPOINT_UUID="$uuid" \
        CHECKPOINT_REASON="$reason" \
        CHECKPOINT_JOB_UUID="${_tapisJobUUID:-}" \
        CHECKPOINT_JOB_OWNER="${_tapisJobOwner:-}" \
        CHECKPOINT_IMPORT_PATH="$import_path" \
        CHECKPOINT_RESUME_IMPORT_PATH="${NODEODM_RESUME_IMPORT_PATH:-}" \
        CHECKPOINT_SCRATCH_RUNTIME_DIR="$scratch_runtime_dir" \
        CHECKPOINT_SCRATCH_DATA_DIR="$scratch_data_dir" \
        CHECKPOINT_SCRATCH_TASK_DIR="$scratch_task_dir" \
        CHECKPOINT_RESUME_MODE="${NODEODM_RESUME_MODE:-}" \
        CHECKPOINT_RESUME_FALLBACK_REASON="${NODEODM_RESUME_FALLBACK_REASON:-}" \
        CHECKPOINT_RETENTION_SECONDS="${NODEODM_CHECKPOINT_RETENTION_SECONDS:-604800}" \
        CHECKPOINT_COPY_DATA="${NODEODM_CHECKPOINT_COPY_DATA:-0}" \
        CHECKPOINT_STATUS_JSON="$status_json" \
        CHECKPOINT_TASKS_JSON="$NODEODM_RUNTIME_DIR/data/tasks.json" \
        CHECKPOINT_IMAGES_DIR="$NODEODM_RUNTIME_DIR/data/$uuid/images" \
        python3 <<'PY'
import json
import os
import time

checkpoint_dir = os.environ["CHECKPOINT_DIR"]
uuid = os.environ["CHECKPOINT_UUID"]
status_json = os.environ.get("CHECKPOINT_STATUS_JSON", "")
tasks_json = os.environ.get("CHECKPOINT_TASKS_JSON", "")

task_info = {}
try:
    if status_json.strip():
        task_info = json.loads(status_json)
except Exception:
    task_info = {}

if not task_info and os.path.exists(tasks_json):
    try:
        with open(tasks_json) as f:
            for task in json.load(f):
                if task.get("uuid") == uuid:
                    task_info = task
                    break
    except Exception:
        task_info = {}

manifest = {
    "uuid": uuid,
    "name": task_info.get("name"),
    "status": task_info.get("status"),
    "progress": task_info.get("progress", 0),
    "options": task_info.get("options", []),
    "imagesCount": task_info.get("imagesCount"),
    "importPath": os.environ.get("CHECKPOINT_IMPORT_PATH") or os.environ.get("CHECKPOINT_RESUME_IMPORT_PATH") or None,
    "tapisJobUuid": os.environ.get("CHECKPOINT_JOB_UUID") or None,
    "tapisJobOwner": os.environ.get("CHECKPOINT_JOB_OWNER") or None,
    "reason": os.environ.get("CHECKPOINT_REASON") or "periodic",
    "state": "active",
    "checkpointStorage": "copy" if os.environ.get("CHECKPOINT_COPY_DATA") == "1" else "manifest",
    "scratchRuntimeDir": os.environ.get("CHECKPOINT_SCRATCH_RUNTIME_DIR") or None,
    "scratchDataDir": os.environ.get("CHECKPOINT_SCRATCH_DATA_DIR") or None,
    "scratchTaskDir": os.environ.get("CHECKPOINT_SCRATCH_TASK_DIR") or None,
    "resumeMode": os.environ.get("CHECKPOINT_RESUME_MODE") or None,
    "resumeFallbackReason": os.environ.get("CHECKPOINT_RESUME_FALLBACK_REASON") or None,
    "updatedAt": int(time.time()),
}

reason = manifest["reason"]
if reason in ("completed",):
    manifest["state"] = "completed"
elif reason in ("failed", "canceled"):
    manifest["state"] = reason
elif reason in ("scratch-missing", "scratch-unreadable", "resume-unusable", "expired"):
    manifest["state"] = "expired"
elif reason in ("exit",):
    manifest["state"] = "resumable"

try:
    retention = int(os.environ.get("CHECKPOINT_RETENTION_SECONDS") or "604800")
except Exception:
    retention = 604800
if retention > 0:
    manifest["expiresAt"] = manifest["updatedAt"] + retention

if manifest["imagesCount"] is None:
    image_dir = os.environ.get("CHECKPOINT_IMAGES_DIR", "")
    exts = (".jpg", ".jpeg", ".png", ".tif", ".tiff")
    count = 0
    if image_dir and os.path.isdir(image_dir):
        for root, _dirs, files in os.walk(image_dir):
            count += sum(1 for name in files if name.lower().endswith(exts))
    manifest["imagesCount"] = count or None

os.makedirs(checkpoint_dir, exist_ok=True)
tmp_path = os.path.join(checkpoint_dir, "manifest.json.tmp")
final_path = os.path.join(checkpoint_dir, "manifest.json")
with open(tmp_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp_path, final_path)
PY
    else
        cat > "$checkpoint_dir/manifest.json.tmp" <<EOF
{"uuid":"$uuid","reason":"$reason","updatedAt":$(date +%s)}
EOF
        mv "$checkpoint_dir/manifest.json.tmp" "$checkpoint_dir/manifest.json"
    fi
}

# =============================================================================
# CHECKPOINT SYNC
# =============================================================================
checkpoint_sync() {
    local reason="${1:-periodic}"
    local uuid="${2:-${TASK_UUID:-${NODEODM_RESUME_TASK_UUID:-}}}"
    if [ -z "$uuid" ] || [ -z "${NODEODM_CHECKPOINT_ROOT:-}" ]; then
        return 0
    fi
    if [ "$CHECKPOINT_SYNCING" = "1" ]; then
        return 0
    fi

    local had_errexit=0
    case "$-" in *e*) had_errexit=1; set +e ;; esac
    CHECKPOINT_SYNCING=1

    local checkpoint_dir
    checkpoint_dir=$(checkpoint_dir_for_task "$uuid")
    mkdir -p "$checkpoint_dir"

    if [ "${NODEODM_CHECKPOINT_COPY_DATA:-0}" = "1" ]; then
        mkdir -p "$checkpoint_dir/data" "$checkpoint_dir/logs"

        if [ -d "$NODEODM_RUNTIME_DIR/data/$uuid" ]; then
            mkdir -p "$checkpoint_dir/data/$uuid"
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --delete "$NODEODM_RUNTIME_DIR/data/$uuid/" "$checkpoint_dir/data/$uuid/"
            else
                rm -rf "$checkpoint_dir/data/$uuid"
                mkdir -p "$checkpoint_dir/data"
                cp -a "$NODEODM_RUNTIME_DIR/data/$uuid" "$checkpoint_dir/data/"
            fi
        fi

        if [ -f "$NODEODM_RUNTIME_DIR/data/tasks.json" ]; then
            cp "$NODEODM_RUNTIME_DIR/data/tasks.json" "$checkpoint_dir/data/tasks.json"
        fi

        if [ -f "$LOG_FILE" ]; then
            cp "$LOG_FILE" "$checkpoint_dir/logs/nodeodm.log"
        fi
        if [ -n "$OUTPUT_DIR" ] && [ -f "$OUTPUT_DIR/task_output.txt" ]; then
            cp "$OUTPUT_DIR/task_output.txt" "$checkpoint_dir/logs/task_output.txt"
        fi
    fi

    checkpoint_write_manifest "$checkpoint_dir" "$uuid" "$reason"
    CHECKPOINT_LAST_SYNC=$(date +%s)
    CHECKPOINT_SYNCING=0
    if [ "${NODEODM_CHECKPOINT_COPY_DATA:-0}" = "1" ]; then
        echo "Checkpoint sync complete for $uuid ($reason): $checkpoint_dir"
    else
        echo "Checkpoint manifest updated for $uuid ($reason): $checkpoint_dir"
    fi

    if [ "$had_errexit" = "1" ]; then set -e; fi
    return 0
}

# =============================================================================
# MAYBE CHECKPOINT SYNC (interval-based)
# =============================================================================
maybe_checkpoint_sync() {
    local uuid="${TASK_UUID:-${NODEODM_RESUME_TASK_UUID:-}}"
    if [ -z "$uuid" ]; then
        return 0
    fi
    local now
    now=$(date +%s)
    local interval="${NODEODM_CHECKPOINT_INTERVAL_SECONDS:-900}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
        return 0
    fi
    if [ "$CHECKPOINT_LAST_SYNC" -eq 0 ] || [ $((now - CHECKPOINT_LAST_SYNC)) -ge "$interval" ]; then
        checkpoint_sync "periodic" "$uuid"
    fi
}

# =============================================================================
# CHECKPOINT APPLY RESUME STATE
# =============================================================================
checkpoint_apply_resume_state() {
    local uuid="$1"
    local tasks_file="$NODEODM_RUNTIME_DIR/data/tasks.json"
    if [ -z "$uuid" ] || [ ! -f "$tasks_file" ]; then
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 is required to update restored NodeODM task state"
        return 1
    fi

    RESUME_UUID="$uuid" \
    RESUME_OPTIONS_JSON="$NODEODM_RESUME_OPTIONS_JSON" \
    TASKS_FILE="$tasks_file" \
    python3 <<'PY'
import json
import os

tasks_file = os.environ["TASKS_FILE"]
uuid = os.environ["RESUME_UUID"]
options_json = os.environ.get("RESUME_OPTIONS_JSON", "")

with open(tasks_file) as f:
    tasks = json.load(f)

updated = False
for task in tasks:
    if task.get("uuid") != uuid:
        continue
    task["status"] = {"code": 10}
    if options_json.strip():
        try:
            options = json.loads(options_json)
            if isinstance(options, list):
                task["options"] = options
        except Exception:
            pass
    updated = True
    break

if not updated:
    raise SystemExit("task %s not found in %s" % (uuid, tasks_file))

tmp_path = tasks_file + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(tasks, f, indent=2)
    f.write("\n")
os.replace(tmp_path, tasks_file)
PY
}

# =============================================================================
# CHECKPOINT PATH ALLOWED FOR RESUME
# =============================================================================
checkpoint_path_allowed_for_resume() {
    local resume_path="$1"
    if [ -z "$resume_path" ]; then
        return 1
    fi
    RESUME_PATH="$resume_path" RESUME_ALLOWED_ROOTS="$NODEODM_RESUME_ALLOWED_ROOTS" python3 <<'PY'
import os
import sys

raw_path = os.environ.get("RESUME_PATH", "")
roots = [r for r in os.environ.get("RESUME_ALLOWED_ROOTS", "").split(os.pathsep) if r]
if not raw_path.startswith("/") or "\0" in raw_path:
    sys.exit(1)

resume_path = os.path.realpath(raw_path)
for root in roots:
    if not root.startswith("/"):
        continue
    root = os.path.realpath(root)
    if resume_path == root or resume_path.startswith(root.rstrip("/") + "/"):
        sys.exit(0)
sys.exit(1)
PY
}

# =============================================================================
# CHECKPOINT PREPARE COLD START
# =============================================================================
checkpoint_prepare_cold_start() {
    local uuid="$1"
    local reason="${2:-resume-unusable}"

    NODEODM_RESUME_MODE="cold-start"
    NODEODM_RESUME_FALLBACK_REASON="$reason"
    echo "Checkpoint resume unavailable for $uuid ($reason); falling back to cold start from import_path"
    checkpoint_sync "$reason" "$uuid" || true

    if [ "${NODEODM_RESUME_ALLOW_COLD_START:-1}" = "1" ] && [ -n "${NODEODM_RESUME_IMPORT_PATH:-}" ]; then
        return 0
    fi

    echo "ERROR: checkpoint resume failed and cold-start fallback is unavailable"
    return 1
}

# =============================================================================
# CHECKPOINT RESTORE FROM SCRATCH
# =============================================================================
checkpoint_restore_from_scratch() {
    local uuid="$1"
    local resume_task_dir="${NODEODM_RESUME_DATA_PATH%/}"
    local resume_runtime_dir="${NODEODM_RESUME_RUNTIME_PATH%/}"
    local resume_data_dir=""
    local tasks_src=""

    if [ -z "$resume_task_dir" ]; then
        echo "No NODEODM_RESUME_DATA_PATH provided for scratch resume"
        return 1
    fi
    if ! checkpoint_path_allowed_for_resume "$resume_task_dir"; then
        echo "Scratch resume path is outside allowed roots: $resume_task_dir"
        return 1
    fi
    if [ ! -d "$resume_task_dir" ] || [ ! -r "$resume_task_dir" ] || [ ! -x "$resume_task_dir" ]; then
        echo "Scratch resume task directory is missing or unreadable: $resume_task_dir"
        return 1
    fi

    resume_data_dir=$(dirname "$resume_task_dir")
    tasks_src="$resume_data_dir/tasks.json"
    if [ ! -f "$tasks_src" ] && [ -n "$resume_runtime_dir" ]; then
        tasks_src="$resume_runtime_dir/data/tasks.json"
    fi
    if [ ! -f "$tasks_src" ] || [ ! -r "$tasks_src" ]; then
        echo "Scratch resume tasks.json is missing or unreadable for $uuid"
        return 1
    fi

    RESUME_UUID="$uuid" TASKS_FILE="$tasks_src" python3 <<'PY'
import json
import os
import sys

uuid = os.environ["RESUME_UUID"]
tasks_file = os.environ["TASKS_FILE"]
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
except Exception as exc:
    print("Could not read resume tasks.json: %s" % exc)
    sys.exit(1)

if not any(task.get("uuid") == uuid for task in tasks if isinstance(task, dict)):
    print("Resume tasks.json does not contain task %s" % uuid)
    sys.exit(1)
PY
    if [ $? -ne 0 ]; then
        return 1
    fi

    mkdir -p "$NODEODM_RUNTIME_DIR/data"
    rm -rf "$NODEODM_RUNTIME_DIR/data/$uuid"
    ln -s "$resume_task_dir" "$NODEODM_RUNTIME_DIR/data/$uuid"
    cp "$tasks_src" "$NODEODM_RUNTIME_DIR/data/tasks.json"

    checkpoint_apply_resume_state "$uuid"
    NODEODM_RESUME_MODE="scratch"
    NODEODM_RESUME_FALLBACK_REASON=""
    echo "Scratch checkpoint restore complete for $uuid from $resume_task_dir"
}

# =============================================================================
# CHECKPOINT RESTORE IF REQUESTED
# =============================================================================
checkpoint_restore_if_requested() {
    local uuid="${NODEODM_RESUME_TASK_UUID:-}"
    if [ -z "$uuid" ]; then
        return 0
    fi

    if [ -n "${NODEODM_RESUME_DATA_PATH:-}" ]; then
        echo "Attempting scratch checkpoint restore for task $uuid from $NODEODM_RESUME_DATA_PATH"
        if checkpoint_restore_from_scratch "$uuid"; then
            return 0
        fi
        checkpoint_prepare_cold_start "$uuid" "scratch-missing"
        return $?
    fi

    local checkpoint_dir
    checkpoint_dir=$(checkpoint_dir_for_task "$uuid")
    echo "Restoring legacy copied checkpoint for task $uuid from $checkpoint_dir"

    if [ ! -d "$checkpoint_dir" ]; then
        checkpoint_prepare_cold_start "$uuid" "checkpoint-missing"
        return $?
    fi

    mkdir -p "$NODEODM_RUNTIME_DIR/data" "$NODEODM_RUNTIME_DIR/logs"
    if [ -d "$checkpoint_dir/data" ]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$checkpoint_dir/data/" "$NODEODM_RUNTIME_DIR/data/"
        else
            cp -a "$checkpoint_dir/data"/. "$NODEODM_RUNTIME_DIR/data/"
        fi
    fi
    if [ -d "$checkpoint_dir/logs" ]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$checkpoint_dir/logs/" "$NODEODM_RUNTIME_DIR/logs/"
        else
            cp -a "$checkpoint_dir/logs"/. "$NODEODM_RUNTIME_DIR/logs/"
        fi
    fi

    checkpoint_apply_resume_state "$uuid"
    NODEODM_RESUME_MODE="legacy"
    echo "Legacy copied checkpoint restore complete for $uuid"
}