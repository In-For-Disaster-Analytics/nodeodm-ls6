#!/usr/bin/env bash
#
# NodeODX on LS6: Tapis ZIP runtime.
#
# The service is private to the compute node.  TACC TAP allocates a public
# login-node port and this launcher keeps reverse SSH tunnels alive while the
# NodeODX process is serving requests.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/nodeodx-source"

MAX_CONCURRENCY="${1:-${NODEODX_DEFAULT_MAX_CONCURRENCY:-12}}"
NODEODX_PORT="${2:-3001}"
CLUSTER_URL="${3:-https://clusterodm.tacc.utexas.edu}"

if [[ ! "$MAX_CONCURRENCY" =~ ^[0-9]+$ || "$MAX_CONCURRENCY" -lt 1 ]]; then
    echo "ERROR: max concurrency must be a positive integer" >&2
    exit 2
fi
if [[ ! "$NODEODX_PORT" =~ ^[0-9]+$ || "$NODEODX_PORT" -lt 1 || "$NODEODX_PORT" -gt 65535 ]]; then
    echo "ERROR: NodeODX port must be a valid TCP port" >&2
    exit 2
fi

JOB_DIR="${_tapisJobWorkingDir:-$PWD}"
JOB_ID="${SLURM_JOB_ID:-local-$$}"
SCRATCH_ROOT="${SCRATCH:-}"
if [[ -n "${SLURM_JOB_ID:-}" && -z "$SCRATCH_ROOT" && "${NODEODX_ALLOW_NON_SCRATCH:-0}" != "1" ]]; then
    echo "ERROR: SCRATCH is required for an LS6 NodeODX job" >&2
    exit 2
fi

WORK_ROOT="${NODEODX_WORK_ROOT:-${SCRATCH_ROOT:-/tmp}/nodeodx_${JOB_ID}}"
SIF_PATH="${NODEODX_SIF_PATH:-$WORK_ROOT/nodeodx.sif}"
NODEODX_IMAGE="${NODEODX_IMAGE:-webodm/nodeodx:latest}"
NODEODX_IMPORT_PATH_ROOTS="${NODEODX_IMPORT_PATH_ROOTS:-$JOB_DIR}"
NODE_TOKEN="${NODEODX_NODE_TOKEN:-${_tapisJobOwner:-nodeodx-${USER:-unknown}}}"
REGISTRATION_ACCESS_TOKEN="${TAPIS_ACCESS_TOKEN:-${_tapisAccessToken:-}}"
NODEODX_CLEANUP_TASKS_AFTER="${NODEODX_CLEANUP_TASKS_AFTER:-0}"
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

log "job=$JOB_ID port=$NODEODX_PORT image=$NODEODX_IMAGE"
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
    apptainer exec "$SIF_PATH" sh -lc 'cd /var/www && tar -cf - node_modules' \
        | tar -xf - -C "$RUNTIME_DIR"
fi

export NODEODX_CONFIG_PATH="$CONFIG_PATH"
export NODEODX_CONFIG_PORT="$NODEODX_PORT"
export NODEODX_CONFIG_TOKEN="$NODE_TOKEN"
export NODEODX_CONFIG_MAX_CONCURRENCY="$MAX_CONCURRENCY"
export NODEODX_CONFIG_ROOTS="$NODEODX_IMPORT_PATH_ROOTS"
export NODEODX_CONFIG_CLEANUP="$NODEODX_CLEANUP_TASKS_AFTER"
python3 - "$CONFIG_PATH" <<'PY'
import json
import os
import sys

config = {
    "instance": "NodeODX-LS6",
    "odx_path": "/code",
    "port": int(os.environ["NODEODX_CONFIG_PORT"]),
    "parallelQueueProcessing": 1,
    "cleanupTasksAfter": int(os.environ["NODEODX_CONFIG_CLEANUP"]),
    "cleanupUploadsAfter": int(os.environ["NODEODX_CONFIG_CLEANUP"]),
    "maxConcurrency": int(os.environ["NODEODX_CONFIG_MAX_CONCURRENCY"]),
    "token": os.environ["NODEODX_CONFIG_TOKEN"],
    "importPathRoots": [p for p in os.environ["NODEODX_CONFIG_ROOTS"].split(":") if p],
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

log "starting NodeODX"
apptainer exec "${NODEODX_BIND_ARGS[@]}" "$SIF_PATH" \
    sh -lc 'cd /var/www && exec node index.js --config /tmp/nodeodx-config.json' \
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
    REGISTERED_REGISTRATION_UUID="$REGISTRATION_UUID"
    export NODEODX_REGISTRATION_HOST="$REGISTERED_HOST"
    export NODEODX_REGISTRATION_PORT="$REGISTERED_PORT"
    export NODEODX_REGISTRATION_UUID="$REGISTRATION_UUID"
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
    "role": "admin",
}
print(json.dumps(p))
PY
)"
    CURL_ARGS=(-fsS --connect-timeout 15 -X POST -H 'Content-Type: application/json')
    if [[ -n "$REGISTRATION_ACCESS_TOKEN" ]]; then
        CURL_ARGS+=(-H "Authorization: Bearer ${REGISTRATION_ACCESS_TOKEN}")
    fi
    REGISTRATION_RESPONSE="$(curl "${CURL_ARGS[@]}" --data "$REGISTRATION_PAYLOAD" \
        "$CLUSTER_URL/webhook/register-node" 2>&1 || true)"
    if [[ "$REGISTRATION_RESPONSE" == *'"success":true'* ]]; then
        REGISTERED_NODE_ID="$(extract_node_id "$REGISTRATION_RESPONSE")"
        log "registered NodeODX with ClusterODM at ${REGISTERED_HOST}:${REGISTERED_PORT}"
    else
        log "WARNING: ClusterODM registration did not succeed"
        printf '%s\n' "$REGISTRATION_RESPONSE" > "$WORK_ROOT/registration-response.txt"
        if [[ "${NODEODX_REQUIRE_REGISTRATION:-0}" == "1" ]]; then
            exit 1
        fi
    fi
elif [[ "${NODEODX_REQUIRE_REGISTRATION:-0}" == "1" ]]; then
    log "ERROR: registration required but TAP reverse proxy is unavailable"
    exit 1
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
