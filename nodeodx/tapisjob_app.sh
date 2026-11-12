#!/usr/bin/env bash
#
# NodeODX on LS6: Tapis ZIP runtime.
#
# The service is private to the compute node.  TACC TAP allocates a public
# login-node port and this launcher keeps reverse SSH tunnels alive while the
# NodeODX process is serving requests.
#
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: NodeODX launcher must be run with bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/nodeodx-source"

# Shared checkpoint/resume modules (repo-root lib/, packed next to this script in the ZIP).
# NODEODM_LIB_FUNCTIONS_ONLY=1 keeps lib/common.sh from resetting this launcher's variables,
# curl and trap; only the function definitions and checkpoint defaults are loaded.
NODEODM_LIB_FUNCTIONS_ONLY=1
for _lib in common checkpoint task_watch; do
    if [[ ! -f "$SCRIPT_DIR/lib/$_lib.sh" ]]; then
        echo "ERROR: lib/$_lib.sh is missing from the package; rebuild the ZIP with nodeodx/build-zip.sh" >&2
        exit 1
    fi
done
unset _lib
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/checkpoint.sh"
source "$SCRIPT_DIR/lib/task_watch.sh"
verify_modules_loaded || exit 1

# Per-task ODM thread cap (NodeODM max_concurrency). 0 means "all cores Slurm
# allocated to this node"; a small fixed value here starves every parallel stage.
MAX_CONCURRENCY="${1:-${NODEODX_DEFAULT_MAX_CONCURRENCY:-0}}"
if [[ "$MAX_CONCURRENCY" == "0" ]]; then
    MAX_CONCURRENCY="${SLURM_CPUS_ON_NODE:-}"
    if [[ ! "$MAX_CONCURRENCY" =~ ^[0-9]+$ || "$MAX_CONCURRENCY" -lt 1 ]]; then
        MAX_CONCURRENCY="$(nproc 2>/dev/null || echo 12)"
    fi
fi
NODEODX_PARALLEL_QUEUE_PROCESSING="${NODEODX_PARALLEL_QUEUE_PROCESSING:-64}"
NODEODX_SHARED_SUBMODEL_V1="${NODEODX_SHARED_SUBMODEL_V1:-1}"
NODEODX_PORT="${2:-${NODEODX_PORT:-3001}}"
CLUSTER_URL="${3:-${NODEODX_CLUSTER_URL:-https://clusterodm.tacc.utexas.edu}}"

ORIGINAL_ARGS=("$@")
NODEODX_CHILD="${NODEODX_CHILD:-0}"
NODEODX_CHILD_INDEX="${NODEODX_CHILD_INDEX:-}"
NODEODX_HOST_INDEX="${NODEODX_HOST_INDEX:-}"
NODEODX_JOB_INDEX="${NODEODX_JOB_INDEX:-1}"
NODEODX_JOB_COUNT="${NODEODX_JOB_COUNT:-1}"
NODEODX_ROLE="${NODEODX_ROLE:-admin}"
NODEODX_WORKER_ID="${NODEODX_WORKER_ID:-0}"

if [[ ! "$MAX_CONCURRENCY" =~ ^[0-9]+$ || "$MAX_CONCURRENCY" -lt 1 ]]; then
    echo "ERROR: max concurrency must be a positive integer" >&2
    exit 2
fi
if [[ ! "$NODEODX_PARALLEL_QUEUE_PROCESSING" =~ ^[0-9]+$ || "$NODEODX_PARALLEL_QUEUE_PROCESSING" -lt 1 ]]; then
    echo "ERROR: NODEODX_PARALLEL_QUEUE_PROCESSING must be a positive integer" >&2
    exit 2
fi
if [[ ! "$NODEODX_PORT" =~ ^[0-9]+$ || "$NODEODX_PORT" -lt 1 || "$NODEODX_PORT" -gt 65535 ]]; then
    echo "ERROR: NodeODX port must be a valid TCP port" >&2
    exit 2
fi
if [[ "$NODEODX_ROLE" != "admin" && "$NODEODX_ROLE" != "worker" ]]; then
    echo "ERROR: NODEODX_ROLE must be admin or worker" >&2
    exit 2
fi
if [[ "$NODEODX_SHARED_SUBMODEL_V1" != "0" && "$NODEODX_SHARED_SUBMODEL_V1" != "1" ]]; then
    echo "ERROR: NODEODX_SHARED_SUBMODEL_V1 must be 0 or 1" >&2
    exit 2
fi

launch_multi_node_children() {
    [[ "$NODEODX_CHILD" == "1" ]] && return 1
    [[ -n "${SLURM_NODELIST:-}" ]] || return 1
    command -v scontrol >/dev/null 2>&1 || return 1

    local -a node_hosts=()
    while IFS= read -r host; do
        [[ -n "$host" ]] && node_hosts+=("$host")
    done < <(scontrol show hostnames "$SLURM_NODELIST")
    local host_count=${#node_hosts[@]}
    (( host_count > 1 )) || return 1

    if ! command -v srun >/dev/null 2>&1; then
        echo "ERROR: srun is required for a multi-node NodeODX allocation" >&2
        exit 1
    fi
    if (( NODEODX_PORT + host_count - 1 > 65535 )); then
        echo "ERROR: NodeODX port range ${NODEODX_PORT}-$((NODEODX_PORT + host_count - 1)) exceeds TCP port limits" >&2
        exit 2
    fi

    echo "Multi-node host list (${host_count} hosts): ${node_hosts[*]}"
    echo "Launching one NodeODX instance per LS6 host"

    local -a child_pids=()
    local host_index=0
    local host child_index child_port child_role worker_id
    for host in "${node_hosts[@]}"; do
        host_index=$((host_index + 1))
        child_role="worker"
        if (( host_index == 1 )); then child_role="admin"; fi
        worker_id=$((host_index - 1))
        child_index="${host_index}-${child_role}"
        child_port=$((NODEODX_PORT + host_index - 1))
        echo "[MULTI] Launching NodeODX role=${child_role} child=${child_index} host=${host} port=${child_port}"
        srun --overlap --nodes=1 --ntasks=1 -w "$host" \
            env NODEODX_CHILD=1 \
                NODEODX_CHILD_INDEX="$child_index" \
                NODEODX_HOST_INDEX="$host_index" \
                NODEODX_ROLE="$child_role" \
                NODEODX_WORKER_ID="$worker_id" \
                NODEODX_JOB_INDEX="$NODEODX_JOB_INDEX" \
                NODEODX_JOB_COUNT="$NODEODX_JOB_COUNT" \
                bash "$SCRIPT_DIR/tapisjob_app.sh" \
                "$MAX_CONCURRENCY" "$child_port" "$CLUSTER_URL" &
        child_pids+=("$!")
    done

    local status=0 child_status pid
    for pid in "${child_pids[@]}"; do
        if wait "$pid"; then
            child_status=0
        else
            child_status=$?
        fi
        if (( child_status != 0 && status == 0 )); then
            status=$child_status
        fi
    done
    exit "$status"
}

# A multi-node Tapis allocation must explicitly fan out service processes;
# Slurm's nodeCount alone does not start or register them. Child launchers set
# NODEODX_CHILD=1 and execute only the normal single-node startup path below.
launch_multi_node_children || true

JOB_DIR="${_tapisJobWorkingDir:-$PWD}"
JOB_ID="${SLURM_JOB_ID:-local-$$}"
SCRATCH_ROOT="${SCRATCH:-}"
if [[ -n "${SLURM_JOB_ID:-}" && -z "$SCRATCH_ROOT" && "${NODEODX_ALLOW_NON_SCRATCH:-0}" != "1" ]]; then
    echo "ERROR: SCRATCH is required for an LS6 NodeODX job" >&2
    exit 2
fi

BASE_WORK_ROOT="${NODEODX_WORK_ROOT:-${SCRATCH_ROOT:-/tmp}/nodeodx_${JOB_ID}}"
if [[ "$NODEODX_CHILD" == "1" ]]; then
    CHILD_WORK_SUFFIX="${NODEODX_CHILD_INDEX:-${NODEODX_HOST_INDEX:-child}}"
    WORK_ROOT="${BASE_WORK_ROOT%/}/$CHILD_WORK_SUFFIX"
else
    WORK_ROOT="$BASE_WORK_ROOT"
fi
if [[ -n "${NODEODX_SIF_PATH:-}" ]]; then
    SIF_PATH="$NODEODX_SIF_PATH"
else
    SIF_PATH="$WORK_ROOT/nodeodx.sif"
fi
NODEODX_IMAGE="${NODEODX_IMAGE:-ghcr.io/in-for-disaster-analytics/nodeodx@sha256:ff5194d08ba9c08d6fc14b84338c2172dc1de0b598864dba766ad50e2f08eb19}"
NODEODX_IMPORT_PATH_ROOTS="${NODEODX_IMPORT_PATH_ROOTS:-$JOB_DIR}"
NODE_TOKEN="${NODEODX_NODE_TOKEN:-${_tapisJobOwner:-nodeodx-${USER:-unknown}}}"
REGISTRATION_ACCESS_TOKEN="${TAPIS_ACCESS_TOKEN:-${_tapisAccessToken:-}}"
export NODEODX_REGISTRATION_SECRET="${NODEODX_REGISTRATION_SECRET:-}"
# Select one credential explicitly; expired bearers must not override secret mode.
if [[ -n "$NODEODX_REGISTRATION_SECRET" ]]; then
    REGISTRATION_ACCESS_TOKEN=""
fi

registration_request_payload() {
    python3 -c 'import json, os, sys; p=json.load(sys.stdin); secret=os.environ.get("NODEODX_REGISTRATION_SECRET"); p.update({"registrationSecret": secret} if secret else {}); print(json.dumps(p))'
}

# Registration body read from the NODEODX_REGISTRATION_* environment. schemaVersion 2 and the
# resume fields are what ClusterODX expects from a checkpoint-aware worker; the resume fields
# are present only when this job was submitted to resume a task.
registration_payload() {
    python3 - <<'PY'
import json
import os
p = {
    "hostname": os.environ["NODEODX_REGISTRATION_HOST"],
    "port": int(os.environ["NODEODX_REGISTRATION_PORT"]),
    "token": os.environ["NODEODX_REGISTRATION_TOKEN"],
    "registrationUuid": os.environ["NODEODX_REGISTRATION_UUID"],
    "tapisJobUuid": os.environ["NODEODX_REGISTRATION_JOB_UUID"],
    "tapisJobOwner": os.environ["NODEODX_REGISTRATION_OWNER"],
    "nodeReady": True,
    "schemaVersion": 2,
    "role": os.environ["NODEODX_REGISTRATION_ROLE"],
    "workerId": int(os.environ["NODEODX_REGISTRATION_WORKER_ID"]),
    "replicasPerJob": 1,
    "childIndex": os.environ["NODEODX_REGISTRATION_CHILD_INDEX"],
    "hostId": int(os.environ["NODEODX_REGISTRATION_HOST_INDEX"]),
    "jobIndex": int(os.environ["NODEODX_REGISTRATION_JOB_INDEX"]),
    "jobCount": int(os.environ["NODEODX_REGISTRATION_JOB_COUNT"]),
}
resume_uuid = os.environ.get("NODEODM_RESUME_TASK_UUID", "")
if resume_uuid:
    p.update({
        "checkpointResume": True,
        "resumeTaskUuid": resume_uuid,
        "resumeMode": os.environ.get("NODEODM_RESUME_MODE") or "unknown",
        "resumeFallbackReason": os.environ.get("NODEODM_RESUME_FALLBACK_REASON", ""),
    })
print(json.dumps(p))
PY
}
NODEODX_CLEANUP_TASKS_AFTER="${NODEODX_CLEANUP_TASKS_AFTER:-0}"
# Keep the NodeODX service alive when ClusterODM registration is unavailable so
# the Tapis job can be inspected and the registration path can be retried or
# tested manually. Production deployments that require registration can opt
# back into fail-fast behavior with NODEODX_REQUIRE_REGISTRATION=1.
NODEODX_REQUIRE_REGISTRATION="${NODEODX_REQUIRE_REGISTRATION:-0}"
if [[ ! "$NODEODX_CLEANUP_TASKS_AFTER" =~ ^[0-9]+$ ]]; then
    echo "ERROR: NODEODX_CLEANUP_TASKS_AFTER must be a non-negative integer" >&2
    exit 2
fi
# Scratch is a user-scoped shared filesystem on LS6 and is the default place
# for the existing NodeODM/ODX task trees.  Keep an explicit job-root entry,
# then add Scratch unless the caller already supplied it.  Corral roots remain
# opt-in through NODEODX_IMPORT_PATH_ROOTS.
if [[ -n "$SCRATCH_ROOT" && ":$NODEODX_IMPORT_PATH_ROOTS:" != *":$SCRATCH_ROOT:"* ]]; then
    NODEODX_IMPORT_PATH_ROOTS="${NODEODX_IMPORT_PATH_ROOTS}:$SCRATCH_ROOT"
fi

if [[ ! -f "$SOURCE_DIR/package.json" ]]; then
    echo "ERROR: NodeODX source is missing at $SOURCE_DIR" >&2
    exit 1
fi
if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: Apptainer is required; load the TACC tacc-apptainer module" >&2
    exit 1
fi

mkdir -p "$WORK_ROOT" "$(dirname "$SIF_PATH")"
RUNTIME_DIR="$WORK_ROOT/runtime"
CONFIG_PATH="$WORK_ROOT/nodeodx-config.json"
LOG_FILE="$WORK_ROOT/nodeodx-launch.log"
mkdir -p "$WORK_ROOT/data" "$WORK_ROOT/tmp" "$WORK_ROOT/logs"

# --- Checkpoint/resume variable mapping ---------------------------------------------------
# lib/checkpoint.sh and lib/task_watch.sh are shared with the legacy nodeodm-ls62 launcher and
# read NODEODM_* names. This launcher keeps its NODEODX_* names; map them explicitly here.
export NODEODM_RUNTIME_DIR="$RUNTIME_DIR"           # task data lives in $RUNTIME_DIR/data
export NODEODM_PORT="$NODEODX_PORT"                 # per-child port (status watch, /info)
export NODEODM_IMAGE="$NODEODX_IMAGE"               # digest pin recorded in the manifest
export NODEODM_SIF="$SIF_PATH"                      # engine version fallback before launch
export NODEODM_JOB_COUNT="$NODEODX_JOB_COUNT"
export WORK_DIR="$WORK_ROOT"                        # task_watch done-files
# LOG_FILE is shared by name; checkpoints copy it as logs/nodeodm.log.
# Libs authenticate to the local NodeODX with ${_tapisJobOwner}; NODE_TOKEN is that owner by default.
export _tapisJobOwner="${_tapisJobOwner:-$NODE_TOKEN}"
if [[ "$NODE_TOKEN" != "$_tapisJobOwner" ]]; then
    echo "WARNING: NODEODX_NODE_TOKEN differs from the job owner; checkpoint status polling uses the job owner" >&2
fi
# _tapisJobUUID and _tapisExecSystemOutputDir come from Tapis; OUTPUT_DIR is per child.
OUTPUT_DIR="${_tapisExecSystemOutputDir:-$WORK_ROOT/output}"
if [[ "$NODEODX_CHILD" == "1" ]]; then
    OUTPUT_DIR="${OUTPUT_DIR%/}/node-${NODEODX_CHILD_INDEX:-${NODEODX_HOST_INDEX:-child}}"
fi
export OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
TASK_UUID=""
STATUS_RESPONSE=""
# Resume inputs injected by ClusterODX (empty on a normal job). Only the admin instance
# resumes; workers receive the same environment but must not restore the task themselves.
export NODEODM_RESUME_TASK_UUID="${NODEODM_RESUME_TASK_UUID:-}"
export NODEODM_RESUME_CHECKPOINT_PATH="${NODEODM_RESUME_CHECKPOINT_PATH:-}"
export NODEODM_RESUME_DATA_PATH="${NODEODM_RESUME_DATA_PATH:-}"
export NODEODM_RESUME_RUNTIME_PATH="${NODEODM_RESUME_RUNTIME_PATH:-}"
export NODEODM_RESUME_IMPORT_PATH="${NODEODM_RESUME_IMPORT_PATH:-}"
export NODEODM_RESUME_OPTIONS_JSON="${NODEODM_RESUME_OPTIONS_JSON:-}"
export NODEODM_RESUME_ALLOWED_ROOTS="${NODEODM_RESUME_ALLOWED_ROOTS:-${SCRATCH:-/scratch}:/scratch}"
export NODEODM_RESUME_MODE="${NODEODM_RESUME_MODE:-}"
export NODEODM_RESUME_FALLBACK_REASON="${NODEODM_RESUME_FALLBACK_REASON:-}"
if [[ "$NODEODX_ROLE" != "admin" ]]; then
    NODEODM_RESUME_TASK_UUID=""
fi
# NODEODM_CHECKPOINT_ROOT, NODEODM_CORRAL_MEDIA_ROOT, NODEODM_RESUME_AS_UUID and
# NODEODM_RESUME_ALLOW_COLD_START default in lib/common.sh.

log() {
    printf '[NodeODX] %s\n' "$*" | tee -a "$LOG_FILE"
}

declare -a BIND_ARGS=()
add_bind() {
    local path="$1"
    [[ -n "$path" && -d "$path" ]] || return 0
    BIND_ARGS+=(--bind "${path}:${path}:rw")
}

# Bind the exact host paths that may be submitted as import_path.  Binding the
# whole Scratch tree is deliberate on LS6: Tapis inputs and existing Corral
# task directories can be siblings of the Tapis working directory.
add_bind "$JOB_DIR"
add_bind "$WORK_ROOT"
add_bind "$SCRATCH_ROOT"
IFS=: read -r -a IMPORT_ROOT_ARRAY <<< "$NODEODX_IMPORT_PATH_ROOTS"
for import_root in "${IMPORT_ROOT_ARRAY[@]}"; do
    add_bind "$import_root"
done
# Corral media tree (import_path sources and the checkpoint root) and any resume paths must be
# visible inside the container: restored task directories symlink into them.
add_bind "$NODEODM_CORRAL_MEDIA_ROOT"
add_bind "$NODEODM_RESUME_RUNTIME_PATH"
add_bind "$NODEODM_RESUME_DATA_PATH"

export APPTAINERENV_NODEODX_IMPORT_PATH_ROOTS="$NODEODX_IMPORT_PATH_ROOTS"
export SINGULARITYENV_NODEODX_IMPORT_PATH_ROOTS="$NODEODX_IMPORT_PATH_ROOTS"
export APPTAINERENV__tapisJobWorkingDir="$JOB_DIR"
export SINGULARITYENV__tapisJobWorkingDir="$JOB_DIR"

log "job=$JOB_ID child=${NODEODX_CHILD_INDEX:-primary} host_index=${NODEODX_HOST_INDEX:-1} port=$NODEODX_PORT image=$NODEODX_IMAGE"
log "work root=$WORK_ROOT"
log "import roots=$NODEODX_IMPORT_PATH_ROOTS"

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
cp -a "$SOURCE_DIR"/. "$RUNTIME_DIR"/
mkdir -p "$RUNTIME_DIR/data" "$RUNTIME_DIR/tmp" "$RUNTIME_DIR/logs"
chmod 770 "$RUNTIME_DIR/data" "$RUNTIME_DIR/tmp" "$RUNTIME_DIR/logs"

# NodeODX's official image contains the Node runtime and dependencies.  Keep
# the source overlay from this package so the shared-path implementation is
# the exact revision under test, while reusing the image's node_modules.
if [[ ! -s "$SIF_PATH" ]]; then
    log "pulling NodeODX image into $SIF_PATH"
    apptainer pull "$SIF_PATH" "docker://$NODEODX_IMAGE"
fi
if [[ ! -d "$RUNTIME_DIR/node_modules" ]]; then
    log "extracting NodeODX node_modules from the SIF"
    apptainer exec "$SIF_PATH" bash -lc 'cd /var/www && test -d node_modules && tar -cf - node_modules' \
        | tar -xf - -C "$RUNTIME_DIR"
fi

export NODEODX_CONFIG_PATH="$CONFIG_PATH"
export NODEODX_CONFIG_PORT="$NODEODX_PORT"
export NODEODX_CONFIG_TOKEN="$NODE_TOKEN"
export NODEODX_CONFIG_MAX_CONCURRENCY="$MAX_CONCURRENCY"
export NODEODX_CONFIG_PARALLEL_QUEUE_PROCESSING="$NODEODX_PARALLEL_QUEUE_PROCESSING"
export NODEODX_CONFIG_ROOTS="$NODEODX_IMPORT_PATH_ROOTS"
export NODEODX_CONFIG_CLEANUP="$NODEODX_CLEANUP_TASKS_AFTER"
export NODEODX_CONFIG_SHARED_V1="$NODEODX_SHARED_SUBMODEL_V1"
export NODEODX_CONFIG_SHARED_ROOT="${BASE_WORK_ROOT:-}"
export NODEODX_CONFIG_SHARED_JOB_UUID="${_tapisJobUUID:-}"
export NODEODX_CONFIG_SHARED_IMAGE_ROOTS="${NODEODX_SHARED_IMAGE_ROOTS:-/corral/utexas/BCS26030/webodm/media}"
python3 - "$CONFIG_PATH" <<'PY'
import json
import os
import sys

config = {
    "instance": "NodeODX-LS6",
    "odx_path": "/code",
    "port": int(os.environ["NODEODX_CONFIG_PORT"]),
    "parallelQueueProcessing": int(os.environ["NODEODX_CONFIG_PARALLEL_QUEUE_PROCESSING"]),
    "cleanupTasksAfter": int(os.environ["NODEODX_CONFIG_CLEANUP"]),
    "cleanupUploadsAfter": int(os.environ["NODEODX_CONFIG_CLEANUP"]),
    "maxConcurrency": int(os.environ["NODEODX_CONFIG_MAX_CONCURRENCY"]),
    "token": os.environ["NODEODX_CONFIG_TOKEN"],
    "importPathRoots": [p for p in os.environ["NODEODX_CONFIG_ROOTS"].split(":") if p],
    "sharedSubmodelV1": os.environ["NODEODX_CONFIG_SHARED_V1"] == "1",
    "sharedSubmodelRoot": os.environ["NODEODX_CONFIG_SHARED_ROOT"],
    "sharedSubmodelJobUuid": os.environ["NODEODX_CONFIG_SHARED_JOB_UUID"],
    "sharedSubmodelImageRoots": [p for p in os.environ["NODEODX_CONFIG_SHARED_IMAGE_ROOTS"].split(":") if p],
    "logger": {
        "level": "info",
        "logDirectory": "/var/www/logs",
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
os.chmod(sys.argv[1], 0o600)
PY

declare -a TUNNEL_PIDS=()
REGISTERED_HOST=""
REGISTERED_PORT=""
REGISTERED_NODE_ID=""
REGISTERED_REGISTRATION_UUID=""
NODEODX_PID=""
SAMPLER_PID=""

extract_node_id() {
    python3 - "$1" <<'PY'
import json
import sys
try:
    value = json.loads(sys.argv[1]).get("nodeId", "")
    print(value)
except Exception:
    print("")
PY
}

deregister_node() {
    [[ -n "$REGISTERED_HOST" && -n "$REGISTERED_PORT" ]] || return 0
    local payload
    local -a deregister_curl_args
    export NODEODX_DEREG_HOST="$REGISTERED_HOST"
    export NODEODX_DEREG_PORT="$REGISTERED_PORT"
    export NODEODX_DEREG_ID="$REGISTERED_NODE_ID"
    export NODEODX_DEREG_UUID="$REGISTERED_REGISTRATION_UUID"
    payload="$(python3 - <<'PY'
import json
import os
p = {"hostname": os.environ["NODEODX_DEREG_HOST"], "port": int(os.environ["NODEODX_DEREG_PORT"])}
if os.environ.get("NODEODX_DEREG_ID"):
    p["nodeId"] = int(os.environ["NODEODX_DEREG_ID"])
if os.environ.get("NODEODX_DEREG_UUID"):
    p["registrationUuid"] = os.environ["NODEODX_DEREG_UUID"]
print(json.dumps(p))
PY
)"
    deregister_curl_args=(-fsS --connect-timeout 10 -X POST -H 'Content-Type: application/json')
    if [[ -n "$REGISTRATION_ACCESS_TOKEN" ]]; then
        deregister_curl_args+=(-H "Authorization: Bearer ${REGISTRATION_ACCESS_TOKEN}")
    fi
    registration_request_payload <<< "$payload" | curl "${deregister_curl_args[@]}" --data-binary @- \
        "$CLUSTER_URL/webhook/deregister-node" >/dev/null || true
}

cleanup() {
    local code=$?
    trap - EXIT TERM INT
    # Safety net: the status watch normally wrote the terminal checkpoint already (then this
    # is a no-op). Runs before deregistration so the task is checkpointed while the node is up.
    # Refresh the task status first: a stale "running" STATUS_RESPONSE would make the exit sync
    # mark an already-checkpointed task inconsistent.
    STATUS_RESPONSE=""
    if [[ -n "${TASK_UUID:-}" ]]; then
        STATUS_RESPONSE="$(command curl -fsS --connect-timeout 3 --max-time 5 --get \
            --data-urlencode "token=$NODE_TOKEN" \
            "http://127.0.0.1:${NODEODX_PORT}/task/${TASK_UUID}/info" 2>/dev/null)" || STATUS_RESPONSE=""
    fi
    task_watch_wait "${TASK_UUID:-}" || true
    checkpoint_sync exit "${TASK_UUID:-}" || true
    task_watch_stop
    deregister_node
    if [[ -n "$SAMPLER_PID" ]]; then kill "$SAMPLER_PID" 2>/dev/null || true; fi
    if [[ -n "$NODEODX_PID" ]] && kill -0 "$NODEODX_PID" 2>/dev/null; then
        kill "$NODEODX_PID" 2>/dev/null || true
        wait "$NODEODX_PID" 2>/dev/null || true
    fi
    for pid in "${TUNNEL_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    log "exiting code=$code"
    exit "$code"
}
trap cleanup EXIT TERM INT

NODEODX_BIND_ARGS=(--writable-tmpfs --bind "$RUNTIME_DIR:/var/www:rw" --bind "$CONFIG_PATH:/tmp/nodeodx-config.json:ro")
NODEODX_BIND_ARGS+=("${BIND_ARGS[@]}")

resolve_node_binary() {
    apptainer exec "$SIF_PATH" sh -c '
        for candidate in /usr/local/nvm/versions/node/*/bin/node /usr/bin/node; do
            if [ -x "$candidate" ] && [ ! -L "$candidate" ]; then
                printf "%s\\n" "$candidate"
                exit 0
            fi
        done
        exit 1
    '
}

NODEODX_RUNTIME_NODE="${NODEODX_NODE_BINARY:-$(resolve_node_binary)}"
NODEODX_RUNTIME_NODE_DIR="${NODEODX_RUNTIME_NODE%/*}"
export APPTAINERENV_NODEODX_RUNTIME_NODE="$NODEODX_RUNTIME_NODE"
NODEODX_IMAGE_PATH="$(apptainer exec "$SIF_PATH" sh -c 'printf "%s" "${PATH:-}"')"
export APPTAINERENV_PATH="$NODEODX_RUNTIME_NODE_DIR${NODEODX_IMAGE_PATH:+:$NODEODX_IMAGE_PATH}"
export SINGULARITYENV_PATH="$APPTAINERENV_PATH"

# The ZIP supplies NodeODX source; ODX itself comes from the pinned image.
# Never advertise shared submission against an image with the old upload-only engine.
if [[ "$NODEODX_SHARED_SUBMODEL_V1" == "1" ]]; then
    if [[ -z "${_tapisJobUUID:-}" ]]; then
        log "ERROR: shared submodels require the trusted Tapis job UUID"
        exit 2
    fi
    if ! apptainer exec --pwd /code "${NODEODX_BIND_ARGS[@]}" "$SIF_PATH" python3 -c \
        'from opendm import remote; assert getattr(remote, "SHARED_SUBMODEL_V1", False) is True, "image lacks shared-submodel engine v1"; print("Shared-submodel engine:", remote.__file__)' \
        >>"$LOG_FILE" 2>&1; then
        log "ERROR: pinned image does not provide the shared-submodel engine contract; rebuild the ODX-derived image"
        exit 1
    fi
    export APPTAINERENV_NODEODX_SHARED_SUBMODEL_ENGINE_V1=1
    export SINGULARITYENV_NODEODX_SHARED_SUBMODEL_ENGINE_V1=1
    export APPTAINERENV_ODX_SHARED_SUBMODEL_V1=1
    export SINGULARITYENV_ODX_SHARED_SUBMODEL_V1=1
    export APPTAINERENV_ODX_SHARED_DATA_ROOT="$RUNTIME_DIR/data"
    export SINGULARITYENV_ODX_SHARED_DATA_ROOT="$RUNTIME_DIR/data"
    export APPTAINERENV_ODX_SHARED_CONTAINER_ROOT=/var/www/data
    export SINGULARITYENV_ODX_SHARED_CONTAINER_ROOT=/var/www/data
    export APPTAINERENV_ODX_SHARED_ALLOCATION_ROOT="$BASE_WORK_ROOT"
    export SINGULARITYENV_ODX_SHARED_ALLOCATION_ROOT="$BASE_WORK_ROOT"
    export APPTAINERENV_ODX_SHARED_JOB_UUID="$_tapisJobUUID"
    export SINGULARITYENV_ODX_SHARED_JOB_UUID="$_tapisJobUUID"
else
    # An inherited opt-in must not enable the engine behind a disabled node API.
    export APPTAINERENV_NODEODX_SHARED_SUBMODEL_ENGINE_V1=0
    export SINGULARITYENV_NODEODX_SHARED_SUBMODEL_ENGINE_V1=0
    export APPTAINERENV_ODX_SHARED_SUBMODEL_V1=0
    export SINGULARITYENV_ODX_SHARED_SUBMODEL_V1=0
fi

DEPENDENCY_CHECK_SCRIPT='const p=require("./package.json"); const missing=Object.keys(p.dependencies||{}).filter((name)=>{try{require.resolve(name);return false}catch(_){return true}}); if(missing.length){console.error("missing production dependencies: "+missing.join(", ")); process.exit(1)}'

verify_runtime_dependencies() {
    if apptainer exec --pwd /var/www "${NODEODX_BIND_ARGS[@]}" "$SIF_PATH" \
        "$NODEODX_RUNTIME_NODE" -e "$DEPENDENCY_CHECK_SCRIPT" \
        >>"$LOG_FILE" 2>&1; then
        log "verified NodeODX production dependency tree"
        return 0
    fi

    log "ERROR: NodeODX runtime image does not provide the complete production dependency tree"
    log "ERROR: rebuild and republish $NODEODX_IMAGE with production dependencies before submitting another job"
    return 1
}

if ! verify_runtime_dependencies; then
    exit 1
fi

# Remove expired/oversized checkpoints (best effort), then restore a requested checkpoint
# BEFORE NodeODX starts: it reads data/tasks.json at startup.
checkpoint_prune || true
RESUME_RESTORE_FAILED=0
if ! checkpoint_restore_if_requested; then
    RESUME_RESTORE_FAILED=1
    log "checkpoint resume failed: reason=${NODEODM_RESUME_FALLBACK_REASON:-unknown}; will register and exit without starting a task"
    printf '{"resumeTaskUuid":"%s","resumeMode":"failed","resumeFallbackReason":"%s"}\n' \
        "${NODEODM_RESUME_TASK_UUID:-}" "${NODEODM_RESUME_FALLBACK_REASON:-}" \
        > "$OUTPUT_DIR/resume-failure.json" 2>/dev/null || true
fi

# Periodic host resource sampler. Writes one block per interval to
# $WORK_ROOT/logs/resource-sampler.log so slow stages (e.g. the Entwine merge)
# can be attributed to CPU, I/O wait, memory, or Lustre traffic after the fact.
# Set NODEODX_SAMPLER_INTERVAL=0 to disable. Reads /proc only; failures are ignored.
resource_sampler() {
    local interval=$1 out=$2
    local u n s i w idle_prev=0 total_prev=0 iow_prev=0
    while sleep "$interval"; do
        {
            echo "=== $(date -u +%FT%TZ) host=$(hostname -s) load=$(cut -d' ' -f1-3 /proc/loadavg)"
            read -r _ u n s i w _ < <(grep '^cpu ' /proc/stat)
            local total=$((u + n + s + i + w))
            local dt=$((total - total_prev))
            if (( total_prev > 0 && dt > 0 )); then
                echo "cpu: busy=$(( 100 * (dt - (i - idle_prev)) / dt ))% iowait=$(( 100 * (w - iow_prev) / dt ))%"
            fi
            total_prev=$total; idle_prev=$i; iow_prev=$w
            grep -E '^(MemAvailable|Dirty|Writeback):' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo
            for f in /proc/pressure/io /proc/pressure/cpu /proc/pressure/memory; do
                [[ -r $f ]] && echo "psi $(basename "$f"): $(head -1 "$f")"
            done
            echo "procs_in_D_state=$(ps -eo state= | grep -c '^D')"
            ps -eo pcpu=,nlwp=,state=,comm= --sort=-pcpu 2>/dev/null | head -5 | sed 's/^/top: /'
            # Cumulative Lustre client bytes (diff consecutive samples to get rates)
            for f in /proc/fs/lustre/llite/*/stats; do
                [[ -r $f ]] && echo "lustre $(basename "$(dirname "$f")"): $(grep -E '^(read_bytes|write_bytes) ' "$f" | tr -s ' ' | tr '\n' ';')"
            done
            echo "df: $(df -Pk "$WORK_ROOT" | awk 'NR==2 {print $4 " KB free on " $6}')"
        } >>"$out" 2>/dev/null || true
    done
}

SAMPLER_INTERVAL="${NODEODX_SAMPLER_INTERVAL:-60}"
if [[ "$SAMPLER_INTERVAL" =~ ^[0-9]+$ && "$SAMPLER_INTERVAL" -gt 0 ]]; then
    resource_sampler "$SAMPLER_INTERVAL" "$WORK_ROOT/logs/resource-sampler.log" &
    SAMPLER_PID=$!
    log "resource sampler started (every ${SAMPLER_INTERVAL}s) -> $WORK_ROOT/logs/resource-sampler.log"
fi

if (( RESUME_RESTORE_FAILED == 0 )); then
    log "starting NodeODX"
    apptainer exec --pwd /var/www "${NODEODX_BIND_ARGS[@]}" "$SIF_PATH" \
        "$NODEODX_RUNTIME_NODE" index.js --config /tmp/nodeodx-config.json \
        >>"$LOG_FILE" 2>&1 &
    NODEODX_PID=$!

    NODEODX_INFO=""
    for attempt in {1..30}; do
        if NODEODX_INFO="$(curl -fsS --connect-timeout 5 --get \
            --data-urlencode "token=$NODE_TOKEN" \
            "http://127.0.0.1:${NODEODX_PORT}/info" 2>/dev/null)"; then
            break
        fi
        if ! kill -0 "$NODEODX_PID" 2>/dev/null; then
            log "ERROR: NodeODX exited during startup"
            tail -n 100 "$LOG_FILE" >&2 || true
            exit 1
        fi
        sleep 2
    done
    if [[ -z "$NODEODX_INFO" ]]; then
        log "ERROR: NodeODX did not answer /info"
        tail -n 100 "$LOG_FILE" >&2 || true
        exit 1
    fi
    log "NodeODX /info responded"
    printf '%s\n' "$NODEODX_INFO" > "$WORK_ROOT/nodeodx-info.json"
    # Engine version / image identity for manifests (NodeODX answers /info now)
    checkpoint_load_worker_identity
else
    log "skipping NodeODX launch (failed checkpoint resume)"
fi

TAP_TOKEN=""
LOGIN_PORT=""
EXTERNAL_HOST="ls6.tacc.utexas.edu"
if [[ -n "${SLURM_JOB_ID:-}" && -f /share/doc/slurm/tap_functions ]]; then
    # shellcheck disable=SC1091
    source /share/doc/slurm/tap_functions
    TAP_TOKEN="$(tap_get_token)"
    LOGIN_PORT="$(tap_get_port)"
    HOSTNAME_VALUE="$(hostname)"
    for login_node in login1 login2; do
        ssh -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
            -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
            -q -g -N -R "${LOGIN_PORT}:${HOSTNAME_VALUE}:${NODEODX_PORT}" "$login_node" \
            >>"$LOG_FILE" 2>&1 &
        TUNNEL_PIDS+=("$!")
    done
    sleep 3
    for pid in "${TUNNEL_PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log "ERROR: reverse tunnel process failed"
            exit 1
        fi
    done
    REGISTERED_HOST="$EXTERNAL_HOST"
    REGISTERED_PORT="$LOGIN_PORT"
    log "TAP reverse tunnels established at ${EXTERNAL_HOST}:${LOGIN_PORT}"
else
    log "TAP functions unavailable; no public reverse proxy was created"
fi

if [[ -n "$REGISTERED_HOST" ]]; then
    REGISTRATION_UUID="${_tapisJobUUID:-$JOB_ID}"
    REGISTRATION_UUID="${REGISTRATION_UUID%-*}"
    if [[ "$NODEODX_ROLE" == "worker" ]]; then
        REGISTRATION_UUID="${REGISTRATION_UUID}-worker-${NODEODX_WORKER_ID}"
    fi
    REGISTERED_REGISTRATION_UUID="$REGISTRATION_UUID"
    export NODEODX_REGISTRATION_HOST="$REGISTERED_HOST"
    export NODEODX_REGISTRATION_PORT="$REGISTERED_PORT"
    export NODEODX_REGISTRATION_UUID="$REGISTRATION_UUID"
    export NODEODX_REGISTRATION_CHILD_INDEX="${NODEODX_CHILD_INDEX:-primary}"
    export NODEODX_REGISTRATION_HOST_INDEX="${NODEODX_HOST_INDEX:-1}"
    export NODEODX_REGISTRATION_JOB_INDEX="$NODEODX_JOB_INDEX"
    export NODEODX_REGISTRATION_JOB_COUNT="$NODEODX_JOB_COUNT"
    export NODEODX_REGISTRATION_ROLE="$NODEODX_ROLE"
    export NODEODX_REGISTRATION_WORKER_ID="$NODEODX_WORKER_ID"
    export NODEODX_REGISTRATION_OWNER="${_tapisJobOwner:-$USER}"
    export NODEODX_REGISTRATION_TOKEN="$NODE_TOKEN"
    export NODEODX_REGISTRATION_JOB_UUID="${_tapisJobUUID:-$JOB_ID}"
    REGISTRATION_PAYLOAD="$(registration_payload)"
    REGISTRATION_RESPONSE_FILE="$WORK_ROOT/registration-response.txt"
    REGISTRATION_HEADERS_FILE="$WORK_ROOT/registration-headers.txt"
    CURL_ARGS=(-sS --connect-timeout 15 --max-time 60 -X POST -H 'Content-Type: application/json')
    if [[ -n "$REGISTRATION_ACCESS_TOKEN" ]]; then
        CURL_ARGS+=(-H "Authorization: Bearer ${REGISTRATION_ACCESS_TOKEN}")
    fi
    REGISTRATION_HTTP_CODE=""
    REGISTRATION_CURL_STATUS=0
    REGISTRATION_HTTP_CODE="$(registration_request_payload <<< "$REGISTRATION_PAYLOAD" | curl "${CURL_ARGS[@]}" \
        -D "$REGISTRATION_HEADERS_FILE" \
        -o "$REGISTRATION_RESPONSE_FILE" \
        -w '%{http_code}' \
        --data-binary @- \
        "$CLUSTER_URL/webhook/register-node" 2>/dev/null)" || REGISTRATION_CURL_STATUS=$?
    REGISTRATION_RESPONSE="$(cat "$REGISTRATION_RESPONSE_FILE" 2>/dev/null || true)"
    if [[ "$REGISTRATION_RESPONSE" == *'"success":true'* ]]; then
        REGISTERED_NODE_ID="$(extract_node_id "$REGISTRATION_RESPONSE")"
        log "registered NodeODX with ClusterODX at ${REGISTERED_HOST}:${REGISTERED_PORT}"
    else
        REGISTRATION_PAYLOAD_FILE="$WORK_ROOT/registration-payload.json"
        printf '%s\n' "$REGISTRATION_PAYLOAD" > "$REGISTRATION_PAYLOAD_FILE"
        chmod 600 "$REGISTRATION_PAYLOAD_FILE"
        MANUAL_REGISTRATION_CURL="curl --noproxy '*' -sS -i --connect-timeout 15 --max-time 60 -X POST -H 'Content-Type: application/json' -H \"Authorization: Bearer \$TAPIS_ACCESS_TOKEN\" --data-binary @$REGISTRATION_PAYLOAD_FILE \"$CLUSTER_URL/webhook/register-node\""
        if [[ -n "$NODEODX_REGISTRATION_SECRET" ]]; then
            MANUAL_REGISTRATION_CURL="python3 -c 'import json,os,sys; p=json.load(sys.stdin); p[\"registrationSecret\"]=os.environ[\"NODEODX_REGISTRATION_SECRET\"]; print(json.dumps(p))' < $REGISTRATION_PAYLOAD_FILE | curl --noproxy '*' -sS -i --connect-timeout 15 --max-time 60 -X POST -H 'Content-Type: application/json' --data-binary @- \"$CLUSTER_URL/webhook/register-node\""
        fi
        log "WARNING: ClusterODX registration did not succeed (http_status=${REGISTRATION_HTTP_CODE:-unknown}, curl_status=$REGISTRATION_CURL_STATUS, endpoint=$CLUSTER_URL/webhook/register-node)"
        log "manual registration curl (export the selected credential first): $MANUAL_REGISTRATION_CURL"
        if [[ -n "$REGISTRATION_RESPONSE" ]]; then
            REGISTRATION_RESPONSE_SUMMARY="$(python3 - "$REGISTRATION_RESPONSE_FILE" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
        body = handle.read()
except OSError:
    body = ""

try:
    value = json.loads(body)
    sensitive = re.compile(r"token|secret|password|authorization|access_token|refresh_token", re.I)

    def redact(item):
        if isinstance(item, dict):
            return {key: "[REDACTED]" if sensitive.search(key) else redact(val) for key, val in item.items()}
        if isinstance(item, list):
            return [redact(entry) for entry in item]
        return item

    summary = json.dumps(redact(value), separators=(",", ":"))
except (json.JSONDecodeError, TypeError):
    summary = re.sub(r"(?i)(bearer\s+)[^\s\"']+", r"\1[REDACTED]", body)

print(summary[:2000])
PY
)"
            log "registration response: $REGISTRATION_RESPONSE_SUMMARY"
        fi
        if [[ "${NODEODX_REQUIRE_REGISTRATION}" == "1" ]]; then
            exit 1
        else
            log "continuing with NodeODX alive; registration is optional (set NODEODX_REQUIRE_REGISTRATION=1 to fail fast)"
        fi
    fi
elif [[ "${NODEODX_REQUIRE_REGISTRATION}" == "1" ]]; then
    log "ERROR: registration required but TAP reverse proxy is unavailable"
    exit 1
else
    log "continuing with NodeODX alive; TAP reverse proxy or registration is unavailable"
fi

if (( RESUME_RESTORE_FAILED == 1 )); then
    # Registration carried resumeMode=failed + resumeFallbackReason so ClusterODX can fail the
    # task with a reason. Give it a moment to read the registration before the trap deregisters.
    log "checkpoint resume failed (${NODEODM_RESUME_FALLBACK_REASON:-unknown}); exiting after registration"
    sleep "${NODEODM_RESUME_FAILED_GRACE_SECONDS:-30}"
    exit 0
fi

cat > "$WORK_ROOT/connection_info.txt" <<EOF
NodeODX LS6 connection
======================
Local service: http://127.0.0.1:${NODEODX_PORT}
Public endpoint: ${REGISTERED_HOST:-unavailable}:${REGISTERED_PORT:-unavailable}
NodeODX image: ${NODEODX_IMAGE}
Scratch work root: ${WORK_ROOT}
Shared import roots: ${NODEODX_IMPORT_PATH_ROOTS}
The NodeODX authentication token is intentionally not written here.
EOF

# Find a queued/running task on the local NodeODX. On a new one, set TASK_UUID, write the
# task-start manifest and start the status watch (terminal checkpoint as soon as it finishes).
discover_active_task() {
    local list uuid info code
    list="$(command curl -fsS --connect-timeout 5 --max-time 15 --get \
        --data-urlencode "token=$NODE_TOKEN" \
        "http://127.0.0.1:${NODEODX_PORT}/task/list" 2>/dev/null)" || return 0
    for uuid in $(printf '%s' "$list" | python3 -c '
import json, sys
try:
    for t in json.load(sys.stdin):
        if isinstance(t, dict) and t.get("uuid"):
            print(t["uuid"])
except Exception:
    pass
' 2>/dev/null); do
        [[ "$uuid" == "$TASK_UUID" ]] && continue
        info="$(command curl -fsS --connect-timeout 5 --max-time 15 --get \
            --data-urlencode "token=$NODE_TOKEN" \
            "http://127.0.0.1:${NODEODX_PORT}/task/${uuid}/info" 2>/dev/null)" || continue
        code="$(printf '%s' "$info" | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin).get("status")
    print(s.get("code") if isinstance(s, dict) else s)
except Exception:
    print("")
' 2>/dev/null)"
        if [[ "$code" == "10" || "$code" == "20" ]]; then
            TASK_UUID="$uuid"
            STATUS_RESPONSE="$info"
            log "found task $TASK_UUID (status code $code)"
            checkpoint_sync "task-start" "$TASK_UUID" || true
            task_watch_start "$TASK_UUID"
            return 0
        fi
    done
}

log "NodeODX is ready; waiting for ClusterODM tasks"
# sleep + wait keeps the loop interruptible so the TERM/INT trap runs promptly.
while kill -0 "$NODEODX_PID" 2>/dev/null; do
    discover_active_task || true
    sleep "${NODEODM_TASK_WATCH_INTERVAL_SECONDS:-5}" &
    wait $! || true
done
wait "$NODEODX_PID"
