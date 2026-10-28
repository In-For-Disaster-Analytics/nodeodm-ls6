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

MAX_CONCURRENCY="${1:-${NODEODX_DEFAULT_MAX_CONCURRENCY:-12}}"
NODEODX_PARALLEL_QUEUE_PROCESSING="${NODEODX_PARALLEL_QUEUE_PROCESSING:-64}"
NODEODX_SHARED_SUBMODEL_V1="${NODEODX_SHARED_SUBMODEL_V1:-0}"
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
NODEODX_IMAGE="${NODEODX_IMAGE:-ghcr.io/in-for-disaster-analytics/nodeodx:1.0.18}"
NODEODX_IMPORT_PATH_ROOTS="${NODEODX_IMPORT_PATH_ROOTS:-$JOB_DIR}"
NODE_TOKEN="${NODEODX_NODE_TOKEN:-${_tapisJobOwner:-nodeodx-${USER:-unknown}}}"
REGISTRATION_ACCESS_TOKEN="${TAPIS_ACCESS_TOKEN:-${_tapisAccessToken:-}}"
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
export NODEODX_CONFIG_SHARED_IMAGE_ROOTS="${NODEODX_SHARED_IMAGE_ROOTS:-}"
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
    curl "${deregister_curl_args[@]}" --data "$payload" \
        "$CLUSTER_URL/webhook/deregister-node" >/dev/null || true
}

cleanup() {
    local code=$?
    trap - EXIT TERM INT
    deregister_node
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
    REGISTRATION_PAYLOAD="$(python3 - <<'PY'
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
    "role": os.environ["NODEODX_REGISTRATION_ROLE"],
    "workerId": int(os.environ["NODEODX_REGISTRATION_WORKER_ID"]),
    "replicasPerJob": 1,
    "childIndex": os.environ["NODEODX_REGISTRATION_CHILD_INDEX"],
    "hostId": int(os.environ["NODEODX_REGISTRATION_HOST_INDEX"]),
    "jobIndex": int(os.environ["NODEODX_REGISTRATION_JOB_INDEX"]),
    "jobCount": int(os.environ["NODEODX_REGISTRATION_JOB_COUNT"]),
}
print(json.dumps(p))
PY
)"
    REGISTRATION_RESPONSE_FILE="$WORK_ROOT/registration-response.txt"
    REGISTRATION_HEADERS_FILE="$WORK_ROOT/registration-headers.txt"
    CURL_ARGS=(-sS --connect-timeout 15 --max-time 60 -X POST -H 'Content-Type: application/json')
    if [[ -n "$REGISTRATION_ACCESS_TOKEN" ]]; then
        CURL_ARGS+=(-H "Authorization: Bearer ${REGISTRATION_ACCESS_TOKEN}")
    fi
    REGISTRATION_HTTP_CODE=""
    REGISTRATION_CURL_STATUS=0
    REGISTRATION_HTTP_CODE="$(curl "${CURL_ARGS[@]}" \
        -D "$REGISTRATION_HEADERS_FILE" \
        -o "$REGISTRATION_RESPONSE_FILE" \
        -w '%{http_code}' \
        --data "$REGISTRATION_PAYLOAD" \
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
        log "WARNING: ClusterODX registration did not succeed (http_status=${REGISTRATION_HTTP_CODE:-unknown}, curl_status=$REGISTRATION_CURL_STATUS, endpoint=$CLUSTER_URL/webhook/register-node)"
        log "manual registration curl (export TAPIS_ACCESS_TOKEN first): $MANUAL_REGISTRATION_CURL"
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

log "NodeODX is ready; waiting for ClusterODM tasks"
wait "$NODEODX_PID"
