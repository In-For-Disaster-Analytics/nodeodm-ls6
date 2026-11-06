#!/bin/bash
#
# lib/checkpoint.sh - Terminal checkpoint (atomic copy + manifest schema 2), resume rule, restore, prune
# Source SIXTH - needs TASK_UUID from task_monitor.sh, RUNTIME_DIR from common.sh
#
# Design: docs/design/2026-11-06-task-versions-and-resumable-reruns.md (part A).
#
# Checkpoint layout under $NODEODM_CHECKPOINT_ROOT/<uuid>/:
#   manifest.json    schema 2 manifest (always written atomically: temp file + rename)
#   data/            <uuid>/ (task directory minus excludes), tasks.json, .complete
#   data.tmp/        in-progress copy; becomes data/ by rename only after .complete is written
#   lock             {writerJobUuid, createdAt, pid, host} while a job is writing
#   logs/            nodeodm.log, task_output.txt (best effort)
#

[[ -n "${_LIB_CHECKPOINT_SH:-}" ]] && return 0
readonly _LIB_CHECKPOINT_SH=1

# Cross-function results (kept as globals; bash functions cannot return strings)
CHECKPOINT_RESTORE_REASON=""
CHECKPOINT_RESUMED_UUID=""

# =============================================================================
# SMALL HELPERS
# =============================================================================
# Print a top-level scalar from a JSON file ("" when absent/unreadable; booleans as true/false)
checkpoint_json_get() {
    CKPT_JSON_FILE="$1" CKPT_JSON_KEY="$2" python3 - <<'PY' 2>/dev/null
import json
import os

try:
    with open(os.environ["CKPT_JSON_FILE"]) as f:
        value = json.load(f).get(os.environ["CKPT_JSON_KEY"])
except Exception:
    value = None
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

# Maximum job run time in seconds, from SLURM_TIMELIMIT (minutes, HH:MM:SS or D-HH:MM:SS)
checkpoint_job_max_seconds() {
    local limit="${SLURM_TIMELIMIT:-}"
    local secs=21600
    if [[ "$limit" =~ ^[0-9]+$ ]]; then
        secs=$((10#$limit * 60))
    elif [[ "$limit" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        secs=$((10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]}))
    elif [[ "$limit" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        secs=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
    fi
    echo "$secs"
}

# "<bytes> <files>" of every non-directory entry under $1 (symlinks counted, not followed;
# the top-level .complete marker is excluded so the marker can carry the counts)
checkpoint_dir_stats() {
    CKPT_STATS_DIR="$1" python3 - <<'PY'
import os

root = os.environ["CKPT_STATS_DIR"]
total = 0
count = 0
for current, dirs, files in os.walk(root):
    names = list(files) + [d for d in dirs if os.path.islink(os.path.join(current, d))]
    for name in names:
        if current == root and name == ".complete":
            continue
        try:
            total += os.lstat(os.path.join(current, name)).st_size
        except OSError:
            continue
        count += 1
print(total, count)
PY
}

# NodeODM status code of task $1: from STATUS_RESPONSE when it describes the task, else tasks.json
checkpoint_task_status_code() {
    CKPT_UUID="$1" CKPT_STATUS_JSON="${STATUS_RESPONSE:-}" CKPT_TASKS_JSON="$NODEODM_RUNTIME_DIR/data/tasks.json" python3 - <<'PY' 2>/dev/null
import json
import os

uuid = os.environ["CKPT_UUID"]

def code_of(info):
    status = info.get("status")
    if isinstance(status, dict):
        return status.get("code")
    if isinstance(status, int):
        return status
    return None

code = None
try:
    info = json.loads(os.environ.get("CKPT_STATUS_JSON") or "null")
    if isinstance(info, dict) and info.get("uuid") in (None, uuid):
        code = code_of(info)
except Exception:
    pass
if code is None:
    try:
        with open(os.environ["CKPT_TASKS_JSON"]) as f:
            for task in json.load(f):
                if task.get("uuid") == uuid:
                    code = code_of(task)
                    break
    except Exception:
        pass
print("" if code is None else code)
PY
}

# =============================================================================
# WORKER IDENTITY (engine version, image digest) for the manifest and the resume rule
# =============================================================================
checkpoint_detect_engine_version() {
    local version=""
    if [ -n "${NODEODM_ENGINE_VERSION:-}" ]; then
        printf '%s\n' "$NODEODM_ENGINE_VERSION"
        return 0
    fi
    # A running NodeODM reports its engine version on /info (engineVersion).
    local info
    info=$(command curl -s --connect-timeout 2 --max-time 5 "http://localhost:${NODEODM_PORT:-3001}/info?token=${_tapisJobOwner:-}" 2>/dev/null || true)
    if [ -n "$info" ]; then
        version=$(CKPT_INFO="$info" python3 - <<'PY' 2>/dev/null
import json
import os

try:
    print(json.loads(os.environ["CKPT_INFO"]).get("engineVersion") or "")
except Exception:
    print("")
PY
)
    fi
    # Before NodeODM is launched (resume restore), read /code/VERSION from the SIF.
    if [ -z "$version" ] && [ -n "${NODEODM_SIF:-}" ] && [ -f "${NODEODM_SIF:-}" ] && command -v apptainer >/dev/null 2>&1; then
        version=$(apptainer exec "$NODEODM_SIF" cat /code/VERSION 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
    fi
    printf '%s\n' "$version"
}

# Sets CHECKPOINT_ENGINE, CHECKPOINT_ENGINE_VERSION, CHECKPOINT_IMAGE_DIGEST and
# CHECKPOINT_IMAGE_DIGEST_KIND ("digest" when pinned by @sha256: or NODEODM_IMAGE_DIGEST,
# otherwise "reference": the image reference string, e.g. ...:latest).
checkpoint_load_worker_identity() {
    CHECKPOINT_ENGINE="${CHECKPOINT_ENGINE:-odm}"
    if [ -z "${CHECKPOINT_ENGINE_VERSION:-}" ]; then
        CHECKPOINT_ENGINE_VERSION=$(checkpoint_detect_engine_version)
    fi
    if [ -z "${CHECKPOINT_IMAGE_DIGEST:-}" ]; then
        if [ -n "${NODEODM_IMAGE_DIGEST:-}" ]; then
            CHECKPOINT_IMAGE_DIGEST="$NODEODM_IMAGE_DIGEST"
            CHECKPOINT_IMAGE_DIGEST_KIND="digest"
        elif [[ "${NODEODM_IMAGE:-}" == *@sha256:* ]]; then
            CHECKPOINT_IMAGE_DIGEST="sha256:${NODEODM_IMAGE##*@sha256:}"
            CHECKPOINT_IMAGE_DIGEST_KIND="digest"
        else
            CHECKPOINT_IMAGE_DIGEST="${NODEODM_IMAGE:-}"
            CHECKPOINT_IMAGE_DIGEST_KIND="reference"
        fi
    fi
    export CHECKPOINT_ENGINE CHECKPOINT_ENGINE_VERSION CHECKPOINT_IMAGE_DIGEST CHECKPOINT_IMAGE_DIGEST_KIND
}

# =============================================================================
# LOCK (A.8)
# =============================================================================
# A lock is stale when it is unreadable for over a minute, older than the job's max run time
# (+10 min), or names a process on this host that no longer exists. The design also allows
# "the Tapis job it names is terminal"; the worker has no Tapis token to check that, so the
# max-run-time rule stands in for it.
checkpoint_lock_is_stale() {
    local lock="$1"
    local created pid host now max
    created=$(checkpoint_json_get "$lock" createdAt)
    pid=$(checkpoint_json_get "$lock" pid)
    host=$(checkpoint_json_get "$lock" host)
    if ! [[ "$created" =~ ^[0-9]+$ ]]; then
        [ -n "$(find "$lock" -mmin +1 2>/dev/null)" ]
        return $?
    fi
    now=$(date +%s)
    max=$(checkpoint_job_max_seconds)
    if [ $((now - created)) -gt $((max + 600)) ]; then
        return 0
    fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$host" = "$(hostname)" ] && ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

checkpoint_lock_acquire() {
    local dir="$1"
    local lock="$dir/lock"
    local attempt
    for attempt in 1 2; do
        if ( set -o noclobber; printf '{"writerJobUuid":"%s","createdAt":%s,"pid":%s,"host":"%s"}\n' \
                "${_tapisJobUUID:-}" "$(date +%s)" "${BASHPID:-$$}" "$(hostname)" > "$lock" ) 2>/dev/null; then
            return 0
        fi
        if [ -e "$lock" ] && checkpoint_lock_is_stale "$lock"; then
            echo "Removing stale checkpoint lock: $lock"
            rm -f "$lock" 2>/dev/null || return 1
            continue
        fi
        return 1
    done
    return 1
}

checkpoint_lock_release() {
    rm -f "$1/lock" 2>/dev/null || true
}

# True when the manifest in $1 is a synced checkpoint of task $2 written by this job
checkpoint_is_synced() {
    local dir="$1" uuid="$2" manifest="$1/manifest.json"
    [ -f "$manifest" ] || return 1
    [ "$(checkpoint_json_get "$manifest" state)" = "synced" ] || return 1
    [ "$(checkpoint_json_get "$manifest" uuid)" = "$uuid" ] || return 1
    [ "$(checkpoint_json_get "$manifest" writerJobUuid)" = "${_tapisJobUUID:-}" ] || return 1
    [ -f "$dir/data/.complete" ]
}

# =============================================================================
# CHECKPOINT WRITE MANIFEST (schema 2)
# =============================================================================
# checkpoint_write_manifest <checkpoint_dir> <uuid> <reason> [state] [bytes] [files] [manifest_path]
#   state: synced | partial | write_failed | manifest_only (default) | inconsistent
#   manifest_path overrides the destination (used for the write_failed fallback manifest)
checkpoint_write_manifest() {
    local checkpoint_dir="$1"
    local uuid="$2"
    local reason="${3:-periodic}"
    local state="${4:-manifest_only}"
    local bytes="${5:-}"
    local files="${6:-}"
    local manifest_path="${7:-$checkpoint_dir/manifest.json}"
    local status_json="${STATUS_RESPONSE:-}"
    local import_path=""
    local task_dir="$NODEODM_RUNTIME_DIR/data/$uuid"
    local scratch_runtime_dir scratch_data_dir scratch_task_dir

    scratch_runtime_dir=$(checkpoint_resolve_path "$NODEODM_RUNTIME_DIR")
    scratch_data_dir=$(checkpoint_resolve_path "$NODEODM_RUNTIME_DIR/data")
    scratch_task_dir=$(checkpoint_resolve_path "$task_dir")

    if [ -L "$task_dir/images" ]; then
        import_path=$(readlink "$task_dir/images" 2>/dev/null || true)
    fi
    checkpoint_load_worker_identity

    if command -v python3 >/dev/null 2>&1; then
        CHECKPOINT_DIR="$checkpoint_dir" \
        CHECKPOINT_MANIFEST_PATH="$manifest_path" \
        CHECKPOINT_UUID="$uuid" \
        CHECKPOINT_REASON="$reason" \
        CHECKPOINT_STATE="$state" \
        CHECKPOINT_BYTES="$bytes" \
        CHECKPOINT_FILES="$files" \
        CHECKPOINT_JOB_UUID="${_tapisJobUUID:-}" \
        CHECKPOINT_JOB_OWNER="${_tapisJobOwner:-}" \
        CHECKPOINT_IMPORT_PATH="$import_path" \
        CHECKPOINT_RESUME_IMPORT_PATH="${NODEODM_RESUME_IMPORT_PATH:-}" \
        CHECKPOINT_SCRATCH_RUNTIME_DIR="$scratch_runtime_dir" \
        CHECKPOINT_SCRATCH_DATA_DIR="$scratch_data_dir" \
        CHECKPOINT_SCRATCH_TASK_DIR="$scratch_task_dir" \
        CHECKPOINT_NODE_COUNT="${SLURM_JOB_NUM_NODES:-${NODEODM_JOB_COUNT:-1}}" \
        CHECKPOINT_RESUME_MODE="${NODEODM_RESUME_MODE:-}" \
        CHECKPOINT_RESUME_FALLBACK_REASON="${NODEODM_RESUME_FALLBACK_REASON:-}" \
        CHECKPOINT_RETENTION_SECONDS="${NODEODM_CHECKPOINT_RETENTION_SECONDS:-604800}" \
        CHECKPOINT_STATUS_JSON="$status_json" \
        CHECKPOINT_TASKS_JSON="$NODEODM_RUNTIME_DIR/data/tasks.json" \
        CHECKPOINT_TASK_DIR="$task_dir" \
        CHECKPOINT_IMAGES_DIR="$task_dir/images" \
        python3 <<'PY'
import hashlib
import json
import os
import time

env = os.environ.get
uuid = env("CHECKPOINT_UUID")
task_dir = env("CHECKPOINT_TASK_DIR", "")
tasks_json = env("CHECKPOINT_TASKS_JSON", "")
manifest_path = env("CHECKPOINT_MANIFEST_PATH")

status_info = {}
try:
    candidate = json.loads(env("CHECKPOINT_STATUS_JSON", "") or "null")
    if isinstance(candidate, dict) and candidate.get("uuid") in (None, uuid):
        status_info = candidate
except Exception:
    status_info = {}

tasks_entry = {}
if os.path.exists(tasks_json):
    try:
        with open(tasks_json) as f:
            for task in json.load(f):
                if task.get("uuid") == uuid:
                    tasks_entry = task
                    break
    except Exception:
        tasks_entry = {}

task_info = status_info or tasks_entry

status = task_info.get("status")
if isinstance(status, dict):
    task_status = status.get("code")
elif isinstance(status, int):
    task_status = status
else:
    task_status = None

# optionsHash / optimizeDiskSpace come from the task options in tasks.json
options = tasks_entry.get("options")
if options is None:
    options = task_info.get("options")
options_hash = None
if isinstance(options, list):
    canonical = json.dumps(options, sort_keys=True, separators=(",", ":"))
    options_hash = hashlib.sha1(canonical.encode()).hexdigest()

def truthy(value):
    return value is True or str(value).lower() in ("true", "1", "yes")

optimize = any(
    isinstance(o, dict) and o.get("name") in ("optimize-disk-space", "optimize_disk_space") and truthy(o.get("value"))
    for o in (options if isinstance(options, list) else [])
)

# stagesCompleted: stage ids in the task's log.json. A stage counts as completed when it has an
# endTime; if no stage records endTime at all, every listed stage is taken as completed.
stages_completed = []
try:
    with open(os.path.join(task_dir, "log.json")) as f:
        stages = [s for s in (json.load(f).get("stages") or []) if isinstance(s, dict)]
    ids = [(s.get("id") or s.get("name")) for s in stages]
    if any("endTime" in s for s in stages):
        stages_completed = [(s.get("id") or s.get("name")) for s in stages if s.get("endTime")]
    else:
        stages_completed = ids
except Exception:
    stages_completed = []

submodels_dir = os.path.join(task_dir, "submodels")
split = os.path.isdir(submodels_dir)
submodel_clouds = None
submodel_clouds_present = None
if split:
    submodel_clouds = {}
    for name in sorted(os.listdir(submodels_dir)):
        if name.startswith("submodel_") and os.path.isdir(os.path.join(submodels_dir, name)):
            submodel_clouds[name] = os.path.isfile(
                os.path.join(submodels_dir, name, "odm_filterpoints", "point_cloud.ply"))
    submodel_clouds_present = bool(submodel_clouds) and all(submodel_clouds.values())

images_path = env("CHECKPOINT_IMAGES_DIR", "")
if os.path.islink(images_path):
    images_kind = "symlink"
elif os.path.isdir(images_path):
    images_kind = "dir"
else:
    images_kind = None

def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

state = env("CHECKPOINT_STATE") or "manifest_only"
bytes_ = as_int(env("CHECKPOINT_BYTES"))
files = as_int(env("CHECKPOINT_FILES"))
now = int(time.time())

manifest = {
    "schemaVersion": 2,
    "uuid": uuid,
    "name": task_info.get("name"),
    "status": task_info.get("status"),
    "taskStatus": task_status,
    "progress": task_info.get("progress", 0),
    "options": task_info.get("options", []),
    "optionsHash": options_hash,
    "optimizeDiskSpace": optimize,
    "imagesCount": task_info.get("imagesCount"),
    "imagesKind": images_kind,
    "importPath": env("CHECKPOINT_IMPORT_PATH") or env("CHECKPOINT_RESUME_IMPORT_PATH") or None,
    "split": split,
    "nodeCount": as_int(env("CHECKPOINT_NODE_COUNT")) or 1,
    "submodelCloudsPresent": submodel_clouds_present,
    "submodelClouds": submodel_clouds,
    "stagesCompleted": stages_completed,
    "engine": env("CHECKPOINT_ENGINE") or None,
    "engineVersion": env("CHECKPOINT_ENGINE_VERSION") or None,
    "imageDigest": env("CHECKPOINT_IMAGE_DIGEST") or None,
    "imageDigestKind": env("CHECKPOINT_IMAGE_DIGEST_KIND") or None,
    "writerJobUuid": env("CHECKPOINT_JOB_UUID") or None,
    "tapisJobUuid": env("CHECKPOINT_JOB_UUID") or None,
    "tapisJobOwner": env("CHECKPOINT_JOB_OWNER") or None,
    "reason": env("CHECKPOINT_REASON") or "periodic",
    "state": state,
    "dataComplete": state == "synced",
    "checkpointStorage": "copy" if state in ("synced", "partial") else "manifest",
    "checkpointBytes": bytes_,
    "fileCount": files,
    "scratchRuntimeDir": env("CHECKPOINT_SCRATCH_RUNTIME_DIR") or None,
    "scratchDataDir": env("CHECKPOINT_SCRATCH_DATA_DIR") or None,
    "scratchTaskDir": env("CHECKPOINT_SCRATCH_TASK_DIR") or None,
    "resumeMode": env("CHECKPOINT_RESUME_MODE") or None,
    "resumeFallbackReason": env("CHECKPOINT_RESUME_FALLBACK_REASON") or None,
    "updatedAt": now,
}

retention = as_int(env("CHECKPOINT_RETENTION_SECONDS")) or 604800
if retention > 0:
    manifest["expiresAt"] = now + retention

if manifest["imagesCount"] is None and images_kind == "dir":
    exts = (".jpg", ".jpeg", ".png", ".tif", ".tiff")
    count = 0
    for _root, _dirs, names in os.walk(images_path):
        count += sum(1 for name in names if name.lower().endswith(exts))
    manifest["imagesCount"] = count or None

os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
tmp_path = "%s.tmp.%d" % (manifest_path, os.getpid())
try:
    with open(tmp_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp_path, manifest_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PY
    else
        mkdir -p "$(dirname "$manifest_path")" || return 1
        cat > "$manifest_path.tmp.$$" <<EOF
{"schemaVersion":2,"uuid":"$uuid","reason":"$reason","state":"$state","dataComplete":false,"updatedAt":$(date +%s)}
EOF
        mv "$manifest_path.tmp.$$" "$manifest_path"
    fi
}

# Record that the checkpoint root cannot be created/written: state=write_failed manifest in the
# job's own output directory (A.10). The task itself is unaffected.
checkpoint_record_write_failure() {
    local checkpoint_dir="$1" uuid="$2" reason="$3" detail="${4:-}"
    echo "WARNING: checkpoint write failed for $uuid ($reason): ${detail:-cannot write to $checkpoint_dir}"
    if [ -n "${OUTPUT_DIR:-}" ]; then
        checkpoint_write_manifest "$checkpoint_dir" "$uuid" "$reason" write_failed "" "" \
            "$OUTPUT_DIR/checkpoint-manifest.$uuid.json" \
            || echo "WARNING: could not write fallback manifest under $OUTPUT_DIR"
    fi
}

# =============================================================================
# ATOMIC TERMINAL COPY (A.2)
# =============================================================================
# Fills the global array CHECKPOINT_RSYNC_ARGS (never empty).
checkpoint_build_rsync_args() {
    local src="$1"
    local pattern
    local -a patterns
    CHECKPOINT_RSYNC_ARGS=(-a)
    # 3d_tiles/ must survive the *_tiles/ exclude (3D tiles need it); rsync filters are first-match.
    CHECKPOINT_RSYNC_ARGS+=(--include=3d_tiles/)
    if [ -L "$src/images" ]; then
        # Import-path symlink: recreated from the manifest's importPath on resume.
        CHECKPOINT_RSYNC_ARGS+=(--exclude=/images)
    fi
    # Whitespace-separated patterns; globbing disabled while splitting.
    set -f
    patterns=(${NODEODM_CHECKPOINT_EXCLUDE:-})
    set +f
    for pattern in "${patterns[@]+"${patterns[@]}"}"; do
        CHECKPOINT_RSYNC_ARGS+=("--exclude=$pattern")
    done
}

# checkpoint_copy_terminal <checkpoint_dir> <uuid> <reason>
# Writes data.tmp/, .complete, renames to data/, then the manifest. Always returns 0; the
# outcome is in the manifest (synced | partial | write_failed).
checkpoint_copy_terminal() {
    local dir="$1" uuid="$2" reason="$3"
    local src="$NODEODM_RUNTIME_DIR/data/$uuid"
    local tmp="$dir/data.tmp"
    local final="$dir/data"
    local old="$dir/data.old.$$"
    local errfile stats bytes files rc

    if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "cannot create or write $dir"
        return 0
    fi
    if ! checkpoint_lock_acquire "$dir"; then
        echo "Checkpoint for $uuid is locked by another writer ($dir/lock); skipping copy"
        return 0
    fi

    rm -rf "$tmp" 2>/dev/null
    if ! mkdir -p "$tmp/$uuid" 2>/dev/null; then
        checkpoint_lock_release "$dir"
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "cannot create $tmp"
        return 0
    fi

    if ! command -v rsync >/dev/null 2>&1; then
        checkpoint_lock_release "$dir"
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "rsync not available"
        return 0
    fi

    checkpoint_build_rsync_args "$src"
    errfile=$(mktemp "${TMPDIR:-/tmp}/ckpt-rsync.XXXXXX" 2>/dev/null || echo "/dev/null")
    echo "Copying task directory to checkpoint: $src -> $tmp/$uuid"
    rsync "${CHECKPOINT_RSYNC_ARGS[@]}" "$src/" "$tmp/$uuid/" 2>"$errfile"
    rc=$?
    # 24 = source files vanished during transfer; tolerated for a finished task.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        head -n 20 "$errfile" 2>/dev/null
        local state="partial"
        if grep -qiE "permission denied|no space left|disk quota|read-only file system" "$errfile" 2>/dev/null; then
            state="write_failed"
        fi
        rm -f "$errfile" 2>/dev/null
        echo "Checkpoint copy failed (rsync exit $rc) -> state=$state; data.tmp left for prune"
        checkpoint_finish_failed "$dir" "$uuid" "$reason" "$state"
        return 0
    fi
    rm -f "$errfile" 2>/dev/null

    if [ -f "$NODEODM_RUNTIME_DIR/data/tasks.json" ] && ! cp "$NODEODM_RUNTIME_DIR/data/tasks.json" "$tmp/tasks.json" 2>/dev/null; then
        checkpoint_finish_failed "$dir" "$uuid" "$reason" partial
        return 0
    fi

    stats=$(checkpoint_dir_stats "$tmp")
    bytes="${stats% *}"
    files="${stats#* }"
    if ! printf '{"uuid":"%s","bytes":%s,"files":%s,"completedAt":%s,"writerJobUuid":"%s"}\n' \
            "$uuid" "$bytes" "$files" "$(date +%s)" "${_tapisJobUUID:-}" > "$tmp/.complete" 2>/dev/null; then
        checkpoint_finish_failed "$dir" "$uuid" "$reason" write_failed
        return 0
    fi

    # Publish: previous data/ is renamed away, data.tmp/ becomes data/, previous removed last.
    if [ -e "$final" ] && ! mv "$final" "$old" 2>/dev/null; then
        checkpoint_finish_failed "$dir" "$uuid" "$reason" partial
        return 0
    fi
    if ! mv "$tmp" "$final" 2>/dev/null; then
        [ -e "$old" ] && mv "$old" "$final" 2>/dev/null
        checkpoint_finish_failed "$dir" "$uuid" "$reason" partial
        return 0
    fi
    rm -rf "$old" 2>/dev/null

    mkdir -p "$dir/logs" 2>/dev/null
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        cp "$LOG_FILE" "$dir/logs/nodeodm.log" 2>/dev/null || true
    fi
    if [ -n "${OUTPUT_DIR:-}" ] && [ -f "$OUTPUT_DIR/task_output.txt" ]; then
        cp "$OUTPUT_DIR/task_output.txt" "$dir/logs/task_output.txt" 2>/dev/null || true
    fi

    if checkpoint_write_manifest "$dir" "$uuid" "$reason" synced "$bytes" "$files"; then
        echo "Checkpoint synced for $uuid ($reason): $dir ($files files, $bytes bytes)"
    else
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "cannot write $dir/manifest.json"
    fi
    checkpoint_lock_release "$dir"
    return 0
}

# Record a failed copy (partial | write_failed) and release the lock.
checkpoint_finish_failed() {
    local dir="$1" uuid="$2" reason="$3" state="$4"
    if [ "$state" = "write_failed" ]; then
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "copy failed (EACCES or no space)"
    elif ! checkpoint_write_manifest "$dir" "$uuid" "$reason" partial; then
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "cannot write $dir/manifest.json"
    fi
    checkpoint_lock_release "$dir"
}

# =============================================================================
# CHECKPOINT SYNC
# =============================================================================
# reason: periodic | task-start | terminal | exit (anything else is treated as manifest-only)
#  - terminal, or exit without a prior synced manifest: atomic data copy when
#    NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL=1 (exit copies only when the task is terminal)
#  - everything else: manifest only, never overwriting a synced manifest
checkpoint_sync() {
    local reason="${1:-periodic}"
    local uuid="${2:-${TASK_UUID:-}}"
    if [ -z "$uuid" ] || [ -z "${NODEODM_CHECKPOINT_ROOT:-}" ]; then
        return 0
    fi
    # A resume that failed never touches the source checkpoint.
    if [ "${NODEODM_RESUME_MODE:-}" = "failed" ]; then
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

    if checkpoint_is_synced "$checkpoint_dir" "$uuid"; then
        echo "Checkpoint for $uuid already synced by this job; nothing to do ($reason)"
    elif [ -e "$checkpoint_dir/lock" ] && ! checkpoint_lock_is_stale "$checkpoint_dir/lock" \
            && [ "$reason" != "terminal" ] && [ "$reason" != "exit" ]; then
        echo "Checkpoint for $uuid is being written; skipping $reason manifest"
    elif [ "$reason" = "terminal" ] || [ "$reason" = "exit" ]; then
        local code
        code=$(checkpoint_task_status_code "$uuid")
        if [ "${NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL:-0}" = "1" ] && [ -d "$NODEODM_RUNTIME_DIR/data/$uuid" ] \
                && { [ "$reason" = "terminal" ] || [ "$code" = "30" ] || [ "$code" = "40" ] || [ "$code" = "50" ]; }; then
            checkpoint_copy_terminal "$checkpoint_dir" "$uuid" "$reason"
        else
            # No copy: either disabled, or the task never reached a terminal state (exit).
            local state="manifest_only"
            if [ "$reason" = "exit" ] && [ "$code" != "30" ] && [ "$code" != "40" ] && [ "$code" != "50" ]; then
                state="inconsistent"
            fi
            checkpoint_sync_manifest_only "$checkpoint_dir" "$uuid" "$reason" "$state"
        fi
    else
        checkpoint_sync_manifest_only "$checkpoint_dir" "$uuid" "$reason" manifest_only
    fi

    CHECKPOINT_LAST_SYNC=$(date +%s)
    CHECKPOINT_SYNCING=0
    if [ "$had_errexit" = "1" ]; then set -e; fi
    return 0
}

checkpoint_sync_manifest_only() {
    local dir="$1" uuid="$2" reason="$3" state="$4"
    # Never downgrade a synced manifest written by an earlier terminal checkpoint.
    if [ "$(checkpoint_json_get "$dir/manifest.json" state)" = "synced" ] \
            && [ "$(checkpoint_json_get "$dir/manifest.json" writerJobUuid)" != "${_tapisJobUUID:-}" ]; then
        echo "Existing synced checkpoint for $uuid belongs to another job; not overwriting ($reason)"
        return 0
    fi
    if [ "$(checkpoint_json_get "$dir/manifest.json" state)" = "synced" ] && [ "$reason" != "terminal" ] && [ "$reason" != "exit" ]; then
        return 0
    fi
    if ! mkdir -p "$dir" 2>/dev/null || ! checkpoint_write_manifest "$dir" "$uuid" "$reason" "$state"; then
        checkpoint_record_write_failure "$dir" "$uuid" "$reason" "cannot write manifest under $dir"
        return 0
    fi
    echo "Checkpoint manifest updated for $uuid ($reason, $state): $dir"
}

# =============================================================================
# MAYBE CHECKPOINT SYNC (interval-based)
# =============================================================================
maybe_checkpoint_sync() {
    local uuid="${TASK_UUID:-}"
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
# PRUNE (A.9)
# =============================================================================
# At job start: remove checkpoint directories whose manifest expiresAt has passed, remove
# data.tmp older than one day (and orphan directories left empty by that), then enforce
# NODEODM_CHECKPOINT_MAX_BYTES oldest-first. Directories with a live lock and the resume
# source of this job are never touched. Anything the job's user cannot delete is skipped.
checkpoint_prune() {
    local root="${NODEODM_CHECKPOINT_ROOT:-}"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        return 0
    fi
    local protect=""
    if [ -n "${NODEODM_RESUME_TASK_UUID:-}" ]; then
        protect=$(checkpoint_dir_for_task "$NODEODM_RESUME_TASK_UUID")
    fi
    CKPT_ROOT="$root" \
    CKPT_MAX_BYTES="${NODEODM_CHECKPOINT_MAX_BYTES:-0}" \
    CKPT_LOCK_MAX_AGE="$(( $(checkpoint_job_max_seconds) + 600 ))" \
    CKPT_PROTECT="$protect" \
    python3 <<'PY' || echo "WARNING: checkpoint prune failed"
import json
import os
import shutil
import socket
import time

root = os.environ["CKPT_ROOT"]
try:
    max_bytes = int(os.environ.get("CKPT_MAX_BYTES") or 0)
except ValueError:
    max_bytes = 0
lock_max_age = int(os.environ["CKPT_LOCK_MAX_AGE"])
protect = os.path.realpath(os.environ["CKPT_PROTECT"]) if os.environ.get("CKPT_PROTECT") else None
now = int(time.time())

def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception:
        return None

def lock_is_live(path):
    lock = os.path.join(path, "lock")
    if not os.path.exists(lock):
        return False
    data = load(lock)
    if data is None:
        return now - os.path.getmtime(lock) <= 60
    created = data.get("createdAt")
    if not isinstance(created, int) or now - created > lock_max_age:
        return False
    pid = data.get("pid")
    if isinstance(pid, int) and data.get("host") == socket.gethostname():
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass
    return True

def tree_size(path):
    total = 0
    for current, dirs, files in os.walk(path):
        for name in files + [d for d in dirs if os.path.islink(os.path.join(current, d))]:
            try:
                total += os.lstat(os.path.join(current, name)).st_size
            except OSError:
                pass
    return total

def remove(path, why):
    try:
        shutil.rmtree(path)
        print("checkpoint prune: removed %s (%s)" % (path, why))
        return True
    except OSError as exc:
        print("checkpoint prune: cannot remove %s (%s): %s" % (path, why, exc))
        return False

entries = []
total = 0
for name in sorted(os.listdir(root)):
    path = os.path.join(root, name)
    if name.startswith(".") or os.path.islink(path) or not os.path.isdir(path):
        continue
    manifest = load(os.path.join(path, "manifest.json"))
    protected = protect is not None and os.path.realpath(path) == protect
    locked = lock_is_live(path)
    if protected or locked:
        size = (manifest or {}).get("checkpointBytes")
        total += size if isinstance(size, int) else tree_size(path)
        continue

    tmp = os.path.join(path, "data.tmp")
    if os.path.isdir(tmp) and now - os.path.getmtime(tmp) > 86400:
        remove(tmp, "stale data.tmp")

    expires = (manifest or {}).get("expiresAt")
    if isinstance(expires, int) and expires < now:
        remove(path, "expired")
        continue
    if manifest is None and not os.path.exists(os.path.join(path, "data")) \
            and not os.path.exists(tmp) and now - os.path.getmtime(path) > 86400:
        remove(path, "orphan without manifest or data")
        continue

    size = (manifest or {}).get("checkpointBytes")
    if not isinstance(size, int):
        size = tree_size(path)
    updated = (manifest or {}).get("updatedAt")
    if not isinstance(updated, int):
        updated = int(os.path.getmtime(path))
    entries.append((updated, size, path))
    total += size

if max_bytes > 0 and total > max_bytes:
    for _updated, size, path in sorted(entries):
        if total <= max_bytes:
            break
        if remove(path, "size cap %d bytes" % max_bytes):
            total -= size
print("checkpoint prune: %d bytes in %s after prune (cap %s)" % (total, root, max_bytes or "none"))
PY
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
    RESUME_PATH="$resume_path" RESUME_ALLOWED_ROOTS="${ALLOWED_ROOTS_OVERRIDE:-$NODEODM_RESUME_ALLOWED_ROOTS}" python3 <<'PY'
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
# RESUMABILITY RULE (A.5)
# =============================================================================
# checkpoint_evaluate_resumable <manifest|""> <task_dir> <tasks_file|""> <complete_marker|"">
# Prints "ok" or a reason code. With a manifest: state == synced && dataComplete && .complete
# marker && !expired && !optimizeDiskSpace && engineVersion == worker's && imageDigest ==
# worker's. Without one (scratch resume): optimize-disk-space is read from tasks_file.
# Always: every stage directory required by the requested rerun-from (from
# NODEODM_RESUME_OPTIONS_JSON) must exist under task_dir.
checkpoint_evaluate_resumable() {
    checkpoint_load_worker_identity
    RESUME_MANIFEST="$1" \
    RESUME_TASK_DIR="$2" \
    RESUME_TASKS_FILE="${3:-}" \
    RESUME_COMPLETE_MARKER="${4:-}" \
    RESUME_UUID="${NODEODM_RESUME_TASK_UUID:-}" \
    RESUME_OPTIONS_JSON="${NODEODM_RESUME_OPTIONS_JSON:-}" \
    WORKER_ENGINE_VERSION="${CHECKPOINT_ENGINE_VERSION:-}" \
    WORKER_IMAGE_DIGEST="${CHECKPOINT_IMAGE_DIGEST:-}" \
    python3 <<'PY'
import glob
import json
import os
import re
import sys
import time

env = os.environ.get

# Stage-prerequisite table: directories (globs) that must exist in the checkpointed task
# directory before ODM may start at the given stage (rerun-from).
STAGE_PREREQS = {
    "odm_meshing": ["odm_filterpoints"],
    "odm_dem": ["odm_filterpoints", "odm_georeferencing"],
    "odm_orthophoto": ["odm_texturing*"],
    "merge": ["submodels"],
}

def verdict(reason):
    print(reason)
    sys.exit(0)

def truthy(value):
    return value is True or str(value).lower() in ("true", "1", "yes")

def load_options(raw):
    try:
        options = json.loads(raw) if raw.strip() else []
    except Exception:
        return []
    return options if isinstance(options, list) else []

manifest_path = env("RESUME_MANIFEST")
if manifest_path:
    if not os.path.isfile(manifest_path):
        verdict("manifest_missing")
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
        assert isinstance(manifest, dict)
    except Exception:
        verdict("manifest_unreadable")
    try:
        schema = int(manifest.get("schemaVersion") or 0)
    except (TypeError, ValueError):
        schema = 0
    if schema < 2:
        verdict("schema_unsupported")
    state = manifest.get("state")
    if state == "write_failed":
        verdict("checkpoint_write_failed")
    if state == "partial":
        verdict("partial")
    if state != "synced":
        verdict("state_" + re.sub(r"[^a-z0-9_]", "_", str(state).lower()))
    marker = env("RESUME_COMPLETE_MARKER")
    if manifest.get("dataComplete") is not True or (marker and not os.path.isfile(marker)):
        verdict("data_incomplete")
    expires = manifest.get("expiresAt")
    if isinstance(expires, (int, float)) and time.time() >= expires:
        verdict("expired")
    if manifest.get("optimizeDiskSpace"):
        verdict("optimize_disk_space")
    worker_version = env("WORKER_ENGINE_VERSION")
    if not manifest.get("engineVersion") or not worker_version:
        verdict("engine_version_unknown")
    if manifest.get("engineVersion") != worker_version:
        verdict("engine_version_mismatch")
    worker_digest = env("WORKER_IMAGE_DIGEST")
    if not manifest.get("imageDigest") or not worker_digest:
        verdict("image_digest_unknown")
    if manifest.get("imageDigest") != worker_digest:
        verdict("image_digest_mismatch")
else:
    tasks_file = env("RESUME_TASKS_FILE")
    if tasks_file and os.path.isfile(tasks_file):
        try:
            with open(tasks_file) as f:
                for task in json.load(f):
                    if task.get("uuid") == env("RESUME_UUID") and any(
                            isinstance(o, dict) and o.get("name") in ("optimize-disk-space", "optimize_disk_space")
                            and truthy(o.get("value")) for o in (task.get("options") or [])):
                        verdict("optimize_disk_space")
        except Exception:
            pass

requested = []
for option in load_options(env("RESUME_OPTIONS_JSON", "")):
    if isinstance(option, dict) and option.get("name") == "rerun-from":
        value = option.get("value")
        values = value if isinstance(value, list) else str(value).split(",")
        requested.extend(v.strip() for v in values if str(v).strip())

task_dir = env("RESUME_TASK_DIR")
for stage in requested:
    for pattern in STAGE_PREREQS.get(stage, []):
        if not any(os.path.isdir(p) for p in glob.glob(os.path.join(task_dir, pattern))):
            verdict("missing_stage_dir:" + pattern.replace("*", ""))
print("ok")
PY
}

# =============================================================================
# RESUME HELPERS
# =============================================================================
# UUIDs end up in paths; accept NodeODM-style ids only.
checkpoint_valid_uuid() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

# Rename data/<old> -> data/<new> and rewrite the uuid in tasks.json (nothing else) (A.7).
checkpoint_rename_restored_task() {
    local old="$1" new="$2"
    local data="$NODEODM_RUNTIME_DIR/data"
    if ! checkpoint_valid_uuid "$new"; then
        CHECKPOINT_RESTORE_REASON="resume_as_uuid_invalid"
        return 1
    fi
    if [ -e "$data/$new" ] || [ -L "$data/$new" ]; then
        CHECKPOINT_RESTORE_REASON="resume_as_uuid_exists"
        return 1
    fi
    mv "$data/$old" "$data/$new" || { CHECKPOINT_RESTORE_REASON="resume_rename_failed"; return 1; }
    if ! OLD_UUID="$old" NEW_UUID="$new" TASKS_FILE="$data/tasks.json" python3 <<'PY'
import json
import os

tasks_file = os.environ["TASKS_FILE"]
with open(tasks_file) as f:
    tasks = json.load(f)
found = False
for task in tasks:
    if task.get("uuid") == os.environ["OLD_UUID"]:
        task["uuid"] = os.environ["NEW_UUID"]
        found = True
if not found:
    raise SystemExit("task %s not found in %s" % (os.environ["OLD_UUID"], tasks_file))
tmp_path = tasks_file + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(tasks, f, indent=2)
    f.write("\n")
os.replace(tmp_path, tasks_file)
PY
    then
        CHECKPOINT_RESTORE_REASON="resume_rename_failed"
        return 1
    fi
    echo "Resuming checkpoint $old as task $new (NODEODM_RESUME_AS_UUID)"
}

# Recreate the import-path images symlink (imagesKind == symlink); the target must exist and
# sit under an allowed root.
checkpoint_recreate_images_link() {
    local uuid="$1" manifest="$2"
    local target
    target=$(checkpoint_json_get "$manifest" importPath)
    [ -n "$target" ] || target="${NODEODM_RESUME_IMPORT_PATH:-}"
    if [ -z "$target" ]; then
        CHECKPOINT_RESTORE_REASON="import_path_missing"
        return 1
    fi
    if ! ALLOWED_ROOTS_OVERRIDE="${NODEODM_RESUME_ALLOWED_ROOTS:-}:${NODEODM_CORRAL_MEDIA_ROOT:-}:${_tapisJobWorkingDir:-}" \
            checkpoint_path_allowed_for_resume "$target"; then
        CHECKPOINT_RESTORE_REASON="import_path_not_allowed"
        return 1
    fi
    if [ ! -d "$target" ]; then
        CHECKPOINT_RESTORE_REASON="import_path_missing"
        return 1
    fi
    rm -rf "$NODEODM_RUNTIME_DIR/data/$uuid/images"
    ln -s "$target" "$NODEODM_RUNTIME_DIR/data/$uuid/images"
}

# =============================================================================
# CHECKPOINT PREPARE COLD START
# =============================================================================
# Cold start is disabled by default (NODEODM_RESUME_ALLOW_COLD_START=0): a failed restore
# sets NODEODM_RESUME_MODE=failed and NODEODM_RESUME_FALLBACK_REASON=<code>, returns 1, and
# the entry script registers (so ClusterODX learns the reason) and exits without a task.
# It never writes to the source checkpoint.
checkpoint_prepare_cold_start() {
    local uuid="$1"
    local reason="${2:-resume-unusable}"

    NODEODM_RESUME_FALLBACK_REASON="$reason"
    if [ "${NODEODM_RESUME_ALLOW_COLD_START:-0}" = "1" ] && [ -n "${NODEODM_RESUME_IMPORT_PATH:-}" ]; then
        NODEODM_RESUME_MODE="cold-start"
        echo "Checkpoint resume unavailable for $uuid ($reason); falling back to cold start from import_path"
        return 0
    fi

    NODEODM_RESUME_MODE="failed"
    echo "ERROR: checkpoint resume failed for $uuid ($reason); cold start is disabled"
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
    local verdict

    CHECKPOINT_RESTORE_REASON=""
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

    # Scratch resumes have no manifest: apply only the stage-prerequisite and
    # optimize-disk-space parts of the rule.
    verdict=$(checkpoint_evaluate_resumable "" "$resume_task_dir" "$tasks_src" "")
    if [ "$verdict" != "ok" ]; then
        CHECKPOINT_RESTORE_REASON="$verdict"
        echo "Scratch checkpoint is not resumable: $verdict"
        return 1
    fi

    mkdir -p "$NODEODM_RUNTIME_DIR/data"
    rm -rf "$NODEODM_RUNTIME_DIR/data/$uuid"
    ln -s "$resume_task_dir" "$NODEODM_RUNTIME_DIR/data/$uuid"
    cp "$tasks_src" "$NODEODM_RUNTIME_DIR/data/tasks.json"

    CHECKPOINT_RESUMED_UUID="$uuid"
    if [ -n "${NODEODM_RESUME_AS_UUID:-}" ]; then
        checkpoint_rename_restored_task "$uuid" "$NODEODM_RESUME_AS_UUID" || return 1
        CHECKPOINT_RESUMED_UUID="$NODEODM_RESUME_AS_UUID"
    fi
    checkpoint_apply_resume_state "$CHECKPOINT_RESUMED_UUID"
    NODEODM_RESUME_MODE="scratch"
    NODEODM_RESUME_FALLBACK_REASON=""
    echo "Scratch checkpoint restore complete for $uuid from $resume_task_dir"
}

# =============================================================================
# CHECKPOINT RESTORE FROM CHECKPOINT COPY (Corral)
# =============================================================================
# The checkpoint is only ever read. data/ is rsynced (no --delete) into the job's runtime
# data directory, then optionally renamed to NODEODM_RESUME_AS_UUID.
checkpoint_restore_from_checkpoint() {
    local uuid="$1"
    local checkpoint_dir manifest verdict images_kind
    checkpoint_dir=$(checkpoint_dir_for_task "$uuid")
    manifest="$checkpoint_dir/manifest.json"
    CHECKPOINT_RESTORE_REASON=""

    if [ ! -d "$checkpoint_dir" ]; then
        CHECKPOINT_RESTORE_REASON="checkpoint_missing"
        return 1
    fi
    verdict=$(checkpoint_evaluate_resumable "$manifest" "$checkpoint_dir/data/$uuid" "" "$checkpoint_dir/data/.complete")
    if [ "$verdict" != "ok" ]; then
        CHECKPOINT_RESTORE_REASON="$verdict"
        echo "Checkpoint for $uuid is not resumable: $verdict"
        return 1
    fi

    echo "Restoring checkpoint for task $uuid from $checkpoint_dir"
    mkdir -p "$NODEODM_RUNTIME_DIR/data" "$NODEODM_RUNTIME_DIR/logs"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude=/.complete "$checkpoint_dir/data/" "$NODEODM_RUNTIME_DIR/data/" || {
            CHECKPOINT_RESTORE_REASON="restore_copy_failed"
            rm -rf "$NODEODM_RUNTIME_DIR/data/$uuid"
            return 1
        }
    else
        cp -a "$checkpoint_dir/data"/. "$NODEODM_RUNTIME_DIR/data/" && rm -f "$NODEODM_RUNTIME_DIR/data/.complete" || {
            CHECKPOINT_RESTORE_REASON="restore_copy_failed"
            rm -rf "$NODEODM_RUNTIME_DIR/data/$uuid"
            return 1
        }
    fi
    if [ -d "$checkpoint_dir/logs" ]; then
        cp -a "$checkpoint_dir/logs"/. "$NODEODM_RUNTIME_DIR/logs/" 2>/dev/null || true
    fi

    CHECKPOINT_RESUMED_UUID="$uuid"
    if [ -n "${NODEODM_RESUME_AS_UUID:-}" ]; then
        checkpoint_rename_restored_task "$uuid" "$NODEODM_RESUME_AS_UUID" || return 1
        CHECKPOINT_RESUMED_UUID="$NODEODM_RESUME_AS_UUID"
    fi

    images_kind=$(checkpoint_json_get "$manifest" imagesKind)
    if [ "$images_kind" = "symlink" ]; then
        checkpoint_recreate_images_link "$CHECKPOINT_RESUMED_UUID" "$manifest" || return 1
    fi

    checkpoint_apply_resume_state "$CHECKPOINT_RESUMED_UUID" || {
        CHECKPOINT_RESTORE_REASON="resume_state_failed"
        return 1
    }
    NODEODM_RESUME_MODE="checkpoint"
    NODEODM_RESUME_FALLBACK_REASON=""
    echo "Checkpoint restore complete for $uuid (task id $CHECKPOINT_RESUMED_UUID)"
}

# =============================================================================
# CHECKPOINT RESTORE IF REQUESTED
# =============================================================================
# Returns 0 when nothing was requested or the restore worked (or a permitted cold start was
# chosen); returns 1 with NODEODM_RESUME_MODE=failed and NODEODM_RESUME_FALLBACK_REASON set
# when the restore failed and cold start is disabled.
checkpoint_restore_if_requested() {
    local uuid="${NODEODM_RESUME_TASK_UUID:-}"
    if [ -z "$uuid" ]; then
        return 0
    fi
    if ! checkpoint_valid_uuid "$uuid"; then
        checkpoint_prepare_cold_start "$uuid" "invalid_uuid"
        return $?
    fi

    if [ -n "${NODEODM_RESUME_DATA_PATH:-}" ]; then
        echo "Attempting scratch checkpoint restore for task $uuid from $NODEODM_RESUME_DATA_PATH"
        if checkpoint_restore_from_scratch "$uuid"; then
            return 0
        fi
        checkpoint_prepare_cold_start "$uuid" "${CHECKPOINT_RESTORE_REASON:-scratch-missing}"
        return $?
    fi

    if checkpoint_restore_from_checkpoint "$uuid"; then
        return 0
    fi
    checkpoint_prepare_cold_start "$uuid" "${CHECKPOINT_RESTORE_REASON:-resume-unusable}"
}
