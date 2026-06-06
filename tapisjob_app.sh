#!/bin/bash

# NodeODM processing script for Tapis
# Based on the working nodeodm.sh configuration - using ZIP runtime to access TACC modules
# ZIP runtime means we run directly on compute node and can use module load tacc-apptainer

if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
    # Keep going during debug even if a command fails (don't auto-shutdown)
    set +e
fi

if [[ -n "$1" ]]; then
    MAX_CONCURRENCY=$1
    MAX_CONCURRENCY_USER_SET=1
else
    MAX_CONCURRENCY=${NODEODM_DEFAULT_MAX_CONCURRENCY:-12}
    MAX_CONCURRENCY_USER_SET=0
fi
NODEODM_PORT=${2:-3001}
CLUSTERODM_URL=${3:-"https://clusterodm.tacc.utexas.edu"}  # ClusterODM endpoint URL
CLUSTERODM_CLI_HOST=${4:-"clusterodm.tacc.utexas.edu"}  # ClusterODM CLI host
CLUSTERODM_CLI_PORT=${5:-443}  # ClusterODM CLI port
NODEODM_LOG_LEVEL=silly
# Detect GPU availability so we pick the matching NodeODM image and only pass
# --nv (host NVIDIA driver injection, supplies libcuda.so.1) when a GPU exists.
# A CPU node running the :gpu image would fail densify with exit 127, and --nv
# on a CPU node only emits a harmless warning, so we branch on both.
if nvidia-smi >/dev/null 2>&1; then
    HAS_GPU=1
elif [[ "${SLURM_JOB_PARTITION:-}" == *gpu* ]]; then
    HAS_GPU=1
else
    HAS_GPU=0
fi

# Default NodeODM image (override with NODEODM_IMAGE to pin a forked build)
if [ "$HAS_GPU" = "1" ]; then
    NV_FLAG="--nv"
    NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:gpu}
else
    NV_FLAG=""
    NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:latest}
fi
echo "GPU detected: $HAS_GPU (partition='${SLURM_JOB_PARTITION:-}', NV_FLAG='$NV_FLAG')"
# If set to 1, run directly from the container image code (no source overlay bind)
NODEODM_USE_IMAGE_SOURCE=${NODEODM_USE_IMAGE_SOURCE:-0}
# If set to 1, skip launching NodeODM (leave the job alive for debugging)
NODEODM_SKIP_START=${NODEODM_SKIP_START:-0}
# Default to normal run; set NODEODM_DEBUG_SHELL=1 to pause and attach for debugging.
NODEODM_DEBUG_SHELL=${NODEODM_DEBUG_SHELL:-0}
NODEODM_DEBUG_SLEEP=${NODEODM_DEBUG_SLEEP:-43200}
ORIGINAL_ARGS=("$@")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NODEODM_CHECKPOINT_ROOT=${NODEODM_CHECKPOINT_ROOT:-/corral-repl/tacc/aci/PT2050/projects/PTDATAX-263/webodm/media/.nodeodm-checkpoints}
NODEODM_CHECKPOINT_INTERVAL_SECONDS=${NODEODM_CHECKPOINT_INTERVAL_SECONDS:-900}
NODEODM_CHECKPOINT_RETENTION_SECONDS=${NODEODM_CHECKPOINT_RETENTION_SECONDS:-604800}
NODEODM_CHECKPOINT_COPY_DATA=${NODEODM_CHECKPOINT_COPY_DATA:-0}
NODEODM_RESUME_TASK_UUID=${NODEODM_RESUME_TASK_UUID:-}
NODEODM_RESUME_CHECKPOINT_PATH=${NODEODM_RESUME_CHECKPOINT_PATH:-}
NODEODM_RESUME_DATA_PATH=${NODEODM_RESUME_DATA_PATH:-}
NODEODM_RESUME_RUNTIME_PATH=${NODEODM_RESUME_RUNTIME_PATH:-}
NODEODM_RESUME_IMPORT_PATH=${NODEODM_RESUME_IMPORT_PATH:-}
NODEODM_RESUME_ALLOW_COLD_START=${NODEODM_RESUME_ALLOW_COLD_START:-1}
NODEODM_RESUME_ALLOWED_ROOTS=${NODEODM_RESUME_ALLOWED_ROOTS:-${SCRATCH:-/scratch}:/scratch}
NODEODM_RESUME_OPTIONS_JSON=${NODEODM_RESUME_OPTIONS_JSON:-}
NODEODM_RESUME_MODE=${NODEODM_RESUME_MODE:-}
NODEODM_RESUME_FALLBACK_REASON=${NODEODM_RESUME_FALLBACK_REASON:-}
CHECKPOINT_LAST_SYNC=0
CHECKPOINT_SYNCING=0

# Use Tapis environment variables for input/output directories  
INPUT_DIR="${_tapisExecSystemInputDir}"
OUTPUT_DIR="${_tapisExecSystemOutputDir}"

# Launch helper when multiple LS6 nodes are allocated
function launch_multi_node_workers() {
    if [[ "$NODEODM_CHILD" == "1" || -z "$SLURM_NODELIST" ]]; then
        return 1
    fi

    if ! command -v scontrol >/dev/null 2>&1; then
        echo "scontrol not available; cannot fan out across nodes."
        return 1
    fi

    mapfile -t NODE_HOSTS < <(scontrol show hostnames "$SLURM_NODELIST")
    local host_count=${#NODE_HOSTS[@]}
    if [[ "$host_count" -eq 0 ]]; then
        echo "No hosts reported by SLURM_NODELIST ($SLURM_NODELIST); skipping multi-node launch."
        return 1
    fi
    echo "Multi-node host list (${host_count} hosts): ${NODE_HOSTS[*]}"

    local replay_args=""
    if [[ "${#ORIGINAL_ARGS[@]}" -gt 0 ]]; then
        for arg in "${ORIGINAL_ARGS[@]}"; do
            replay_args+=" $(printf '%q' "$arg")"
        done
    fi

    local working_dir
    working_dir=$(pwd)
    echo "Launching one NodeODM instance per LS6 node..."
    local child_pids=()

    local host_idx=0
    for host in "${NODE_HOSTS[@]}"; do
        host_idx=$((host_idx + 1))
        local child_index="${host_idx}-admin"
        echo "[MULTI] Launching admin on $host (index $child_index)"
        srun --overlap --nodes=1 --ntasks=1 -w "$host" bash -lc \
            "cd \"$working_dir\" && NODEODM_CHILD=1 NODEODM_CHILD_INDEX=$child_index NODEODM_CHILD_ROLE=admin NODEODM_HOST_ID=$host_idx \"$SCRIPT_DIR/tapisjob_app.sh\"$replay_args" &
        child_pids+=($!)
    done

    local status=0
    for pid in "${child_pids[@]}"; do
        wait "$pid"
        local child_status=$?
        if [[ "$child_status" -ne 0 && "$status" -eq 0 ]]; then
            status=$child_status
        fi
    done

    exit $status
}

launch_multi_node_workers || true

NODEODM_ROLE_DEFAULT="${NODEODM_ROLE:-admin}"
if [[ "$NODEODM_CHILD" == "1" && -n "$NODEODM_CHILD_ROLE" ]]; then
    NODEODM_ROLE="$NODEODM_CHILD_ROLE"
else
    NODEODM_ROLE="$NODEODM_ROLE_DEFAULT"
fi
echo "[ROLE] NODEODM_CHILD=${NODEODM_CHILD:-0} CHILD_INDEX=${NODEODM_CHILD_INDEX:-primary} ROLE=$NODEODM_ROLE"

if [[ "$NODEODM_ROLE" == "worker" ]]; then
    if [[ "${NODEODM_DISABLE_IMPORT_PATH:-}" != "0" ]]; then
        export NODEODM_DISABLE_IMPORT_PATH=1
    fi
    if [[ "$MAX_CONCURRENCY_USER_SET" -eq 0 ]]; then
        MAX_CONCURRENCY=${NODEODM_WORKER_MAX_CONCURRENCY:-64}
    fi
else
    NODEODM_ROLE="admin"
    if [[ "$MAX_CONCURRENCY_USER_SET" -eq 0 ]]; then
        MAX_CONCURRENCY=${NODEODM_ADMIN_MAX_CONCURRENCY:-16}
    fi
    if [[ -z "${NODEODM_DISABLE_IMPORT_PATH:-}" ]]; then
        export NODEODM_DISABLE_IMPORT_PATH=0
    fi
fi

if [[ "$NODEODM_ROLE" == "worker" && -n "$NODEODM_WORKER_ID" ]]; then
    NODEODM_PORT=$((NODEODM_PORT + NODEODM_WORKER_ID))
fi
echo "[ROLE] Final role=$NODEODM_ROLE worker_id=${NODEODM_WORKER_ID:-0} host_id=${NODEODM_HOST_ID:-0} port=$NODEODM_PORT"

echo "NodeODM role: $NODEODM_ROLE (max concurrency $MAX_CONCURRENCY)"
if [[ -n "$NODEODM_CHILD_INDEX" ]]; then
    echo "Running on LS6 host: $(hostname) (child index $NODEODM_CHILD_INDEX, role=$NODEODM_ROLE, worker_id=${NODEODM_WORKER_ID:-0}, port=$NODEODM_PORT)"
else
    echo "Running on LS6 host: $(hostname) (primary instance)"
fi

echo "=== NodeODM Tapis Processing (ZIP Runtime) ==="
echo "Processing started by: ${_tapisJobOwner}"
echo "Job UUID: ${_tapisJobUUID}"
echo "Input directory: $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "Max concurrency: $MAX_CONCURRENCY"
echo "Port: $NODEODM_PORT"
echo "NodeODM image: $NODEODM_IMAGE"
echo ""
echo "🔐 Authentication Debug Info:"
echo "  Tapis Job Owner: ${_tapisJobOwner}"
echo "  Tapis Job UUID: ${_tapisJobUUID}"
echo "  Environment variables containing 'tapis' or 'access':"
env | grep -i -E "(tapis|access|token)" || echo "  No tapis/access/token env vars found"
echo ""
echo "  Checking _tapisAccessToken specifically:"
if [ -n "${_tapisAccessToken}" ]; then
    echo "  _tapisAccessToken is SET"
    echo "  First 30 chars: ${_tapisAccessToken:0:30}..."
    echo "  Token length: ${#_tapisAccessToken} characters"
    echo "  Token starts with: ${_tapisAccessToken:0:10}"
else
    echo "  _tapisAccessToken is NOT SET or is empty"
fi
echo ""

# Create output directory (namespace per LS6 node when fan-out is used)
if [[ "$NODEODM_CHILD" == "1" && -n "$NODEODM_CHILD_INDEX" ]]; then
    OUTPUT_DIR="${OUTPUT_DIR}/node-${NODEODM_CHILD_INDEX}"
fi
mkdir -p "$OUTPUT_DIR"
# Write logs inside the output tree so they're easy to find per node/child
LOG_DIR="$OUTPUT_DIR/logs"
mkdir -p "$LOG_DIR"
if [[ -n "$NODEODM_CHILD_INDEX" ]]; then
    LOG_FILE="${LOG_DIR}/${NODEODM_CHILD_INDEX}_nodeodm.log"
else
    LOG_FILE="${LOG_DIR}/nodeodm.log"
fi
# Mirror output to stdout and log, and wrap curl for verbose tracing
exec > >(tee -a "$LOG_FILE") 2>&1
curl() {
    echo ""
    echo ">>> curl $*"
    command curl -v "$@"
}

# Start log file early so we always have something to tail
echo "Starting NodeODM job (role=${NODEODM_ROLE:-admin} child=${NODEODM_CHILD_INDEX:-primary})" > "$LOG_FILE" || true

# Load required modules (from working nodeodm.sh)
echo "Loading required modules..."
module load tacc-apptainer

# Remora profiling (system-level). Keep it opt-in while debugging startup.
REMORA_ENABLE=${REMORA_ENABLE:-0}
REMORA_PERIOD=${REMORA_PERIOD:-10}
REMORA_MODE=${REMORA_MODE:-BASIC}
export REMORA_PERIOD REMORA_MODE
if [[ "$REMORA_ENABLE" == "1" ]]; then
    module load remora || echo "Remora module not available; continuing without it."
else
    echo "Remora profiling disabled (REMORA_ENABLE=${REMORA_ENABLE})"
fi

echo "Working directory: $(pwd)"
echo "Environment:"
echo "  User: $(whoami)"
echo "  Hostname: $(hostname)"
echo "  SLURM_JOB_ID: ${SLURM_JOB_ID}"

# Check if input directory exists, but don't require images yet
if [ -d "$INPUT_DIR" ]; then
    IMAGE_COUNT=$(find $INPUT_DIR -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o -name "*.png" -o -name "*.PNG" -o -name "*.tif" -o -name "*.tiff" -o -name "*.TIF" -o -name "*.TIFF" | wc -l)
    echo "Found $IMAGE_COUNT images in input directory"
else
    echo "No input directory found yet - NodeODM will wait for data from ClusterODM"
    IMAGE_COUNT=0
fi

# Set up working directory structure with local NodeODM source (or just data/logs when using image code)
WORK_DIR_BASE="$(pwd)/nodeodm_workdir"
if [[ -n "$NODEODM_CHILD_INDEX" ]]; then
    WORK_DIR_SUFFIX="host${NODEODM_HOST_ID:-0}_${NODEODM_CHILD_INDEX}"
    if [[ "$NODEODM_ROLE" == "worker" && -n "$NODEODM_WORKER_ID" ]]; then
        WORK_DIR_SUFFIX="${WORK_DIR_SUFFIX}_w${NODEODM_WORKER_ID}"
    elif [[ "$NODEODM_ROLE" == "admin" ]]; then
        WORK_DIR_SUFFIX="${WORK_DIR_SUFFIX}_admin"
    fi
    WORK_DIR="${WORK_DIR_BASE}_${WORK_DIR_SUFFIX}"
else
    WORK_DIR="${WORK_DIR_BASE}"
fi

# Completion signal (ClusterODM -> NodeODM job) settings
NODEODM_COMPLETE_ENABLE=${NODEODM_COMPLETE_ENABLE:-1}
NODEODM_COMPLETE_PORT=${NODEODM_COMPLETE_PORT:-3010}
COMPLETE_FLAG="$WORK_DIR/nodeodm_complete.flag"
mkdir -p "$WORK_DIR"

# Ensure we have a local SIF image for NodeODM to avoid repeated remote pulls
NODEODM_SIF="$WORK_DIR/nodeodm.sif"
echo "Ensuring local SIF image at: $NODEODM_SIF"
if [ ! -f "$NODEODM_SIF" ]; then
    echo "Pulling NodeODM image into local SIF..."
    apptainer pull "$NODEODM_SIF" "docker://$NODEODM_IMAGE" || {
        echo "ERROR: Failed to pull NodeODM image to $NODEODM_SIF"
        exit 1
    }
else
    echo "Using existing NodeODM SIF image at $NODEODM_SIF"
fi
if [[ "${NODEODM_FORCE_PULL:-0}" == "1" ]]; then
    echo "NODEODM_FORCE_PULL=1; cleaning cache and forcing image pull..."
    apptainer cache clean -f || true
    apptainer pull --force "$NODEODM_SIF" "docker://$NODEODM_IMAGE" || {
        echo "ERROR: Forced pull failed for $NODEODM_IMAGE"
        exit 1
    }
fi

NODEODM_SOURCE_DIR="${SCRIPT_DIR}/nodeodm-source"
# Optional: auto-sync NodeODM source from git when not bundled in the ZIP
NODEODM_SOURCE_REPO=${NODEODM_SOURCE_REPO:-"https://github.com/wmobley/nodeodm.git"}
NODEODM_SOURCE_REF=${NODEODM_SOURCE_REF:-"master"}

# If nodeodm-source is missing, try to fetch it automatically (only when overlaying source)
if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    if [ ! -d "$NODEODM_SOURCE_DIR" ] || [ ! -f "$NODEODM_SOURCE_DIR/package.json" ]; then
        echo "NodeODM source not found locally; attempting git clone from $NODEODM_SOURCE_REPO (ref: $NODEODM_SOURCE_REF)..."
        if command -v git >/dev/null 2>&1; then
            git clone "$NODEODM_SOURCE_REPO" "$NODEODM_SOURCE_DIR" && \
                (cd "$NODEODM_SOURCE_DIR" && git checkout "$NODEODM_SOURCE_REF") || true
        else
            echo "git not available; cannot auto-fetch NodeODM source."
        fi
    fi
else
    echo "NODEODM_USE_IMAGE_SOURCE=1; will use container image code (no source overlay)."
fi

NODEODM_RUNTIME_DIR=$WORK_DIR/runtime

if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    if [ ! -d "$NODEODM_SOURCE_DIR" ] || [ ! -f "$NODEODM_SOURCE_DIR/package.json" ]; then
        echo "ERROR: NodeODM source not found at $NODEODM_SOURCE_DIR"
        echo "Please populate nodeodm-source/ with the NodeODM repository (package.json expected), or set NODEODM_USE_IMAGE_SOURCE=1 to run from the container image code."
        exit 1
    fi
fi

echo "Preparing NodeODM runtime (use_image_source=$NODEODM_USE_IMAGE_SOURCE)"
rm -rf "$NODEODM_RUNTIME_DIR"
mkdir -p "$NODEODM_RUNTIME_DIR"

if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$NODEODM_SOURCE_DIR"/ "$NODEODM_RUNTIME_DIR"/
    else
        cp -a "$NODEODM_SOURCE_DIR"/. "$NODEODM_RUNTIME_DIR"/
    fi
fi

# Always provide writable dirs for data/tmp/logs
mkdir -p "$NODEODM_RUNTIME_DIR/data" "$NODEODM_RUNTIME_DIR/tmp" "$NODEODM_RUNTIME_DIR/logs"
chmod 777 "$NODEODM_RUNTIME_DIR/data" "$NODEODM_RUNTIME_DIR/tmp" "$NODEODM_RUNTIME_DIR/logs"

# ODM stores downloaded AI models outside of task projects. Keep that cache in
# the writable NodeODM data bind instead of the read-only /code install tree.
ODM_AI_MODELS_PATH=${ODM_AI_MODELS_PATH:-/var/www/data/.odm/models}
ODM_CODE_STORAGE_HOST_DIR="$NODEODM_RUNTIME_DIR/data/.odm/code_storage"
mkdir -p "$NODEODM_RUNTIME_DIR/data/.odm/models" "$ODM_CODE_STORAGE_HOST_DIR"
chmod 777 "$NODEODM_RUNTIME_DIR/data/.odm" "$NODEODM_RUNTIME_DIR/data/.odm/models" "$ODM_CODE_STORAGE_HOST_DIR"
export ODM_AI_MODELS_PATH
echo "ODM AI model cache: $ODM_AI_MODELS_PATH"

# Existing ODM images still derive the model cache from /code/storage. Bind that
# path to writable scratch storage so older images do not fail before rebuild.
ODM_CODE_STORAGE_BIND_ARGS=""
if [[ "${ODM_BIND_CODE_STORAGE:-1}" == "1" ]]; then
    ODM_CODE_STORAGE_BIND_ARGS="--bind $ODM_CODE_STORAGE_HOST_DIR:/code/storage:rw"
    echo "ODM legacy /code/storage bind: $ODM_CODE_STORAGE_HOST_DIR"
fi

# The NodeODM ZIP overlays /var/www, but ODM itself lives in /code inside the
# container. Bind the patched split-merge remote implementation until the GPU
# image is rebuilt with the same code.
ODM_REMOTE_PATCH_BIND_ARGS=""
ODM_REMOTE_PATCH_SOURCE="${SCRIPT_DIR}/odm-patches/remote.py"
if [[ "${ODM_BIND_REMOTE_PATCH:-1}" == "1" && -f "$ODM_REMOTE_PATCH_SOURCE" ]]; then
    ODM_REMOTE_PATCH_BIND_ARGS="--bind $ODM_REMOTE_PATCH_SOURCE:/code/opendm/remote.py:ro"
    echo "ODM remote.py patch bind: $ODM_REMOTE_PATCH_SOURCE -> /code/opendm/remote.py"
else
    echo "ODM remote.py patch bind disabled or missing: $ODM_REMOTE_PATCH_SOURCE"
fi

# Determine bind args for apptainer (overlay source vs. image code)
# Always bind the job working dir (e.g., $SCRATCH job path) so import_path can reference it directly inside the container
SCRATCH_BIND=""
if [[ -n "${_tapisJobWorkingDir:-}" ]]; then
    SCRATCH_BIND="--bind ${_tapisJobWorkingDir}:${_tapisJobWorkingDir}:rw"
fi

RESUME_BIND=""
function add_resume_bind() {
    local bind_path="$1"
    if [[ -z "$bind_path" || ! -d "$bind_path" ]]; then
        return 0
    fi
    case " $RESUME_BIND " in
        *" --bind ${bind_path}:${bind_path}:rw "*) return 0 ;;
    esac
    RESUME_BIND="${RESUME_BIND} --bind ${bind_path}:${bind_path}:rw"
}
add_resume_bind "$NODEODM_RESUME_RUNTIME_PATH"
add_resume_bind "$NODEODM_RESUME_DATA_PATH"

if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    NODEODM_BIND_ARGS="--bind $NODEODM_RUNTIME_DIR:/var/www:rw ${SCRATCH_BIND} ${RESUME_BIND} ${ODM_CODE_STORAGE_BIND_ARGS} ${ODM_REMOTE_PATCH_BIND_ARGS}"
else
    NODEODM_BIND_ARGS="--bind $NODEODM_RUNTIME_DIR/data:/var/www/data:rw --bind $NODEODM_RUNTIME_DIR/tmp:/var/www/tmp:rw --bind $NODEODM_RUNTIME_DIR/logs:/var/www/logs:rw ${SCRATCH_BIND} ${RESUME_BIND} ${ODM_CODE_STORAGE_BIND_ARGS} ${ODM_REMOTE_PATCH_BIND_ARGS}"
fi

echo "Runtime directory prepared:"
ls -la "$NODEODM_RUNTIME_DIR"

if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    if [ ! -d "$NODEODM_RUNTIME_DIR/node_modules" ]; then
        echo "Extracting NodeODM node_modules from base container cache..."
        apptainer exec "$NODEODM_SIF" \
            sh -c "cd /var/www && tar -cf - node_modules" | tar -xf - -C "$NODEODM_RUNTIME_DIR"
        if [ ! -d "$NODEODM_RUNTIME_DIR/node_modules" ]; then
            echo "WARNING: node_modules extraction failed; falling back to npm install during container startup."
        fi
    fi
fi

# TAP functions for reverse port forwarding
function get_tap_certificate() {
    mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
    export TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}
    # bail if we cannot create a secure session
    if [ ! -f ${TAP_CERTFILE} ]; then
        echo "TACC: ERROR - could not find TLS cert for secure session"
        echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
        exit 1
    fi
}

function get_tap_token() {
    # bail if we cannot create a token for the session
    TAP_TOKEN=$(tap_get_token)
    if [ -z "${TAP_TOKEN}" ]; then
        echo "TACC: ERROR - could not generate token for odm session"
        echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
        exit 1
    fi
    echo "TACC: using token ${TAP_TOKEN}"
    export TAP_TOKEN
    LOGIN_PORT=$(tap_get_port)
    export LOGIN_PORT
}

function load_tap_functions() {
    TAP_FUNCTIONS="/share/doc/slurm/tap_functions"
    if [ -f ${TAP_FUNCTIONS} ]; then
        . ${TAP_FUNCTIONS}
    else
        echo "TACC:"
        echo "TACC: ERROR - could not find TAP functions file: ${TAP_FUNCTIONS}"
        echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal"
        echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
        echo "TACC:"
        echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
        exit 1
    fi
}

function port_forwarding_tap() {
    LOCAL_PORT=$NODEODM_PORT
    echo "[TAP] (${NODEODM_CHILD_INDEX:-primary}) attempting TAP tunnel on LOGIN_PORT=${LOGIN_PORT:-n/a} for local port $LOCAL_PORT"
    # Disable exit on error so we can check the ssh tunnel status.
    set +e
    for i in $(seq 2); do
        ssh -o StrictHostKeyChecking=no -q -f -g -N -R ${LOGIN_PORT}:${HOSTNAME}:${LOCAL_PORT} login${i}
    done
    if [ $(ps -fu ${USER} | grep ssh | grep login | grep -vc grep) != 2 ]; then
        echo "TACC: ERROR - ssh tunnels failed to launch"
        echo "TACC: ERROR - this is often due to an issue with your ssh keys"
        echo "TACC: ERROR - undo any recent mods in ${HOME}/.ssh"
        echo "TACC: ERROR - or submit a TACC consulting ticket with this error"
        echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
        return 1
    fi
    # Re-enable exit on error.
    set -e
    NODEODM_URL="http://ls6.tacc.utexas.edu:${LOGIN_PORT}/?token=${TAP_TOKEN}"
    echo "TACC: NodeODM should be available at: ${NODEODM_URL}"
    return 0
}

function send_url_to_webhook() {
    # Session-ready webhook back to the interactive service so users know the tunnel URL.
    if [ -z "${_webhook_base_url:-}" ]; then
        echo "Skipping session_ready webhook: _webhook_base_url is not set"
        return
    fi

    local host="ls6.tacc.utexas.edu"
    local scheme="https"
    if [ -n "${_webhook_use_http:-}" ]; then
        scheme="http"
    fi
    NODEODM_URL="${scheme}://${host}:${LOGIN_PORT}/?token=${TAP_TOKEN}"
    INTERACTIVE_WEBHOOK_URL="${_webhook_base_url%/}"

    echo "Sending session_ready webhook to ${INTERACTIVE_WEBHOOK_URL} with address=${NODEODM_URL}"
    (
        sleep 5
        pkill -0 $$ || exit 0
        local resp
        resp=$(curl -k -s -w " HTTP_CODE:%{http_code}" \
            --data "event_type=nodeodm_session_ready&address=${NODEODM_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}&service_type=nodeodm&clusterodm_url=${CLUSTERODM_URL}" \
            "${INTERACTIVE_WEBHOOK_URL}" 2>&1)
        echo "session_ready webhook response: ${resp}"
    ) &

}

# Function to send NodeODM status updates to PTDataX
function send_nodeodm_status_to_ptdatax() {
    # PTDATAX webhook disabled for local/idev testing
    return 0
}

# Start a lightweight completion endpoint for ClusterODM to signal job exit.
# Only run on the primary (non-child) admin to avoid duplicates.
function start_completion_server() {
    if [[ "${NODEODM_COMPLETE_ENABLE:-0}" != "1" ]]; then
        echo "Completion server disabled (NODEODM_COMPLETE_ENABLE=${NODEODM_COMPLETE_ENABLE})"
        return 0
    fi
    if [[ "${NODEODM_CHILD:-0}" == "1" ]]; then
        echo "Skipping completion server on child instance (NODEODM_CHILD=1)"
        return 0
    fi
    if [[ "${NODEODM_ROLE:-admin}" != "admin" ]]; then
        echo "Skipping completion server on non-admin role (${NODEODM_ROLE})"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not available; cannot start completion server"
        return 0
    fi

    export NODEODM_COMPLETE_FLAG="$COMPLETE_FLAG"
    export NODEODM_COMPLETE_TOKEN="${NODEODM_COMPLETE_TOKEN:-$TAP_TOKEN}"
    export NODEODM_COMPLETE_PORT

    echo "Starting completion server on port ${NODEODM_COMPLETE_PORT} (flag: ${COMPLETE_FLAG})"
    python3 - <<'PY' &
import http.server
import os
import urllib.parse

flag = os.environ.get("NODEODM_COMPLETE_FLAG", "/tmp/nodeodm_complete.flag")
token = os.environ.get("NODEODM_COMPLETE_TOKEN", "")
port = int(os.environ.get("NODEODM_COMPLETE_PORT", "3010"))

class Handler(http.server.BaseHTTPRequestHandler):
    def _ok(self, msg):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode("utf-8"))

    def _forbidden(self):
        self.send_response(403)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"forbidden")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/complete":
            self.send_response(404)
            self.end_headers()
            return
        qs = urllib.parse.parse_qs(parsed.query)
        req_token = qs.get("token", [""])[0]
        if token and req_token != token:
            return self._forbidden()
        os.makedirs(os.path.dirname(flag), exist_ok=True)
        with open(flag, "w") as f:
            f.write("complete\\n")
        return self._ok("ok")

    def do_POST(self):
        return self.do_GET()

    def log_message(self, fmt, *args):
        pass

http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
    COMPLETION_SERVER_PID=$!
    echo "Completion server PID: $COMPLETION_SERVER_PID"
}

function wait_for_completion_signal() {
    local wait_sec=${NODEODM_COMPLETE_WAIT_SEC:-1800}
    local waited=0
    if [[ "${NODEODM_COMPLETE_ENABLE:-0}" != "1" ]]; then
        return 0
    fi
    if [ -f "$COMPLETE_FLAG" ]; then
        echo "Completion flag already present: $COMPLETE_FLAG"
        return 0
    fi
    echo "Waiting for completion signal (up to ${wait_sec}s)..."
    while [ "$waited" -lt "$wait_sec" ]; do
        if [ -f "$COMPLETE_FLAG" ]; then
            echo "Completion signal received."
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    echo "Completion signal not received within ${wait_sec}s; continuing."
    return 0
}

# Fetch incremental ODM console output via NodeODM API and append it to nodeodm.log (and output dir)
function stream_task_output() {
    if [ -z "$TASK_UUID" ]; then
        return
    fi

    local start_line=${TASK_OUTPUT_LINE:-0}
    local raw_output
    raw_output=$(curl -s "http://localhost:$NODEODM_PORT/task/$TASK_UUID/output?token=$TAP_TOKEN&line=$start_line" 2>/dev/null || echo "[]")

    local python_result=""
    local parsed_output="$raw_output"
    local new_lines=0

    if command -v python3 >/dev/null 2>&1; then
        python_result=$(
            RAW_OUTPUT="$raw_output" python3 <<'PY'
import json, os, sys

data = os.environ.get("RAW_OUTPUT", "")
if not data.strip():
    print("__COUNT__=0")
    sys.exit(0)
try:
    payload = json.loads(data)
except Exception:
    print("__COUNT__=0")
    print(data.strip())
    sys.exit(0)


def normalize(value):
    if isinstance(value, list):
        return [str(item) for item in value]
    if isinstance(value, dict):
        # Common NodeODM shapes
        for key in ("data", "output", "lines"):
            if key in value:
                nested = value[key]
                if isinstance(nested, list):
                    return [str(item) for item in nested]
                return [str(nested)]
        return [json.dumps(value)]
    return [str(value)]


lines = normalize(payload)
print(f"__COUNT__={len(lines)}")
for line in lines:
    print(line)
PY
        )
        if [ -n "$python_result" ]; then
            new_lines=$(echo "$python_result" | awk -F= '/^__COUNT__/ {print $2; exit}')
            parsed_output=$(echo "$python_result" | sed '1d')
        fi
    fi

    if [ -z "$parsed_output" ] || [ "$parsed_output" = "[]" ]; then
        return
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "===== ODM Task Output ($TASK_UUID) @ $timestamp (lines +${new_lines:-0}, start ${start_line}) ====="
        printf "%s\n" "$parsed_output"
        echo "===== End Task Output ====="
    } >> "$LOG_FILE"

    if [ -n "$OUTPUT_DIR" ]; then
        mkdir -p "$OUTPUT_DIR"
        if printf "%s\n" "$parsed_output" >> "$OUTPUT_DIR/task_output.txt"; then
            :
        else
            echo "⚠️ Failed to write $OUTPUT_DIR/task_output.txt" >> "$LOG_FILE"
        fi
    else
        echo "⚠️ OUTPUT_DIR not set, skipping task_output.txt copy" >> "$LOG_FILE"
    fi

    if [[ "$new_lines" =~ ^[0-9]+$ ]] && [ "$new_lines" -gt 0 ]; then
        TASK_OUTPUT_LINE=$((start_line + new_lines))
    else
        local appended_lines
        appended_lines=$(printf "%s\n" "$parsed_output" | wc -l | tr -d ' ')
        if [[ "$appended_lines" =~ ^[0-9]+$ ]] && [ "$appended_lines" -gt 0 ]; then
            TASK_OUTPUT_LINE=$((start_line + appended_lines))
        fi
    fi
}

function parse_task_status() {
    local payload="$1"
    if command -v python3 >/dev/null 2>&1; then
        STATUS_PAYLOAD="$payload" python3 <<'PY'
import json
import os

payload = os.environ.get("STATUS_PAYLOAD", "")
code_map = {10: "QUEUED", 20: "RUNNING", 30: "FAILED", 40: "COMPLETED", 50: "CANCELED"}
try:
    data = json.loads(payload)
    status = data.get("status")
    if isinstance(status, dict):
        print(code_map.get(int(status.get("code")), ""))
    elif isinstance(status, str):
        print(status)
    else:
        print("")
except Exception:
    print("")
PY
    else
        echo "$payload" | grep -o '"status":"[^"]*"' | cut -d'"' -f4
    fi
}

function parse_task_progress() {
    local payload="$1"
    if command -v python3 >/dev/null 2>&1; then
        STATUS_PAYLOAD="$payload" python3 <<'PY'
import json
import os

try:
    data = json.loads(os.environ.get("STATUS_PAYLOAD", ""))
    progress = data.get("progress", 0)
    print(int(float(progress)))
except Exception:
    print("0")
PY
    else
        echo "$payload" | grep -o '"progress":[0-9]*' | cut -d':' -f2
    fi
}

function checkpoint_dir_for_task() {
    local uuid="$1"
    if [ -n "$NODEODM_RESUME_CHECKPOINT_PATH" ] && [ "$uuid" = "${NODEODM_RESUME_TASK_UUID:-}" ]; then
        printf "%s\n" "$NODEODM_RESUME_CHECKPOINT_PATH"
    else
        printf "%s/%s\n" "${NODEODM_CHECKPOINT_ROOT%/}" "$uuid"
    fi
}

function checkpoint_resolve_path() {
    local raw_path="$1"
    if [ -z "$raw_path" ]; then
        return 0
    fi
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$raw_path" 2>/dev/null || printf "%s\n" "$raw_path"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$raw_path" 2>/dev/null || printf "%s\n" "$raw_path"
    else
        printf "%s\n" "$raw_path"
    fi
}

function checkpoint_write_manifest() {
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

function checkpoint_sync() {
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

function maybe_checkpoint_sync() {
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

function checkpoint_apply_resume_state() {
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

function checkpoint_path_allowed_for_resume() {
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

function checkpoint_prepare_cold_start() {
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

function checkpoint_restore_from_scratch() {
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

function checkpoint_restore_if_requested() {
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

# Function to notify ClusterODM that NodeODM job is complete
function notify_clusterodm_complete() {
    echo "Notifying ClusterODM that job is complete..."

    # Get node information for removal
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_HOST=$(echo "$EXTERNAL_URL" | sed 's|http[s]*://||' | cut -d: -f1)
        NODEODM_REGISTER_PORT=$(echo "$EXTERNAL_URL" | sed 's|.*:||' | cut -d? -f1 | sed 's|/||g')
    else
        NODEODM_HOST=$(hostname)
        NODEODM_REGISTER_PORT=$NODEODM_PORT
    fi

    # Try to notify ClusterODM via HTTP API about job completion
    if curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/info" > /dev/null 2>&1; then
        echo "Notifying ClusterODM via HTTP API..."

        # Try to get current nodes list to find our node ID
        NODES_INFO=$(curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/nodes" 2>/dev/null || echo "")

        # Send completion notification webhook
        COMPLETION_DATA="hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&job_uuid=${_tapisJobUUID}&status=complete"
        curl -k -s --connect-timeout 10 -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "$COMPLETION_DATA" \
            "$CLUSTERODM_URL/admin/job_complete" >/dev/null 2>&1 || echo "Job completion notification sent"

        # Optionally try to remove/lock the node if it won't be used again
        # This depends on whether you want the node to remain available for other jobs
        # REMOVAL_DATA="hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&action=remove_node"
        # curl -k -s --connect-timeout 10 -X POST \
        #     -H "Content-Type: application/x-www-form-urlencoded" \
        #     -d "$REMOVAL_DATA" \
        #     "$CLUSTERODM_URL/admin/nodes" >/dev/null 2>&1 || echo "Node removal attempted"

        echo "✓ ClusterODM notified of job completion via HTTP"
    else
        echo "WARNING: Could not reach ClusterODM for completion notification"
    fi

    # Also send completion webhook if configured
    if [ -n "${_webhook_base_url}" ]; then
        curl -k --data "event_type=nodeodm_complete&hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&job_uuid=${_tapisJobUUID}&owner=${_tapisJobOwner}&clusterodm_url=$CLUSTERODM_URL" "${_webhook_base_url}/clusterodm" 2>/dev/null || echo "Completion webhook sent"
        echo "✓ Sent completion notification to webhook"
    fi
}

# Function to de-register NodeODM from ClusterODM via webhook
function deregister_from_clusterodm() {
    echo "De-registering NodeODM from ClusterODM..."

    # Get node information for de-registration
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_HOST=$(echo "$EXTERNAL_URL" | sed 's|http[s]*://||' | cut -d: -f1)
        NODEODM_REGISTER_PORT=$(echo "$EXTERNAL_URL" | sed 's|.*:||' | cut -d? -f1 | sed 's|/||g')
    else
        NODEODM_HOST=$(hostname)
        NODEODM_REGISTER_PORT=$NODEODM_PORT
    fi

    # Use webhook de-registration if script is available
    if [ -f "./deregister-node.sh" ]; then
        echo "Using webhook de-registration with Tapis JWT token..."

        # Extract ClusterODM hostname from URL
        CLUSTERODM_HOST=$(echo "$CLUSTERODM_URL" | sed 's|https\?://||' | cut -d/ -f1)

        # Set up environment variables for de-registration
        export CLUSTER_HOST="$CLUSTERODM_HOST"
        export CLUSTER_PORT="443"
        export NODE_HOST="$NODEODM_HOST"
        export NODE_PORT="$NODEODM_REGISTER_PORT"
        export NODE_TOKEN="$TAP_TOKEN"

        # Use the same UUID as registration
        export REGISTRATION_UUID="${_tapisJobUUID%-*}"
        # Clear any JWT tokens to force UUID-based auth
        unset TAPIS_TOKEN

        # Add node ID if we have it
        if [ -n "$REGISTERED_NODE_ID" ]; then
            export NODE_ID="$REGISTERED_NODE_ID"
        fi

        # Use the webhook de-registration script
        ./deregister-node.sh

        if [ $? -eq 0 ]; then
            echo "✅ Successfully de-registered NodeODM from ClusterODM via webhook!"
        else
            echo "⚠️ Webhook de-registration failed, but continuing cleanup..."
        fi
    else
        echo "Webhook de-registration script not found, using legacy approach..."
        # Legacy de-registration notification
        notify_clusterodm_complete
    fi

    # Also send legacy completion notification if configured
    if [ -n "${_webhook_base_url}" ]; then
        curl -k --data "event_type=nodeodm_deregistration&hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&job_uuid=${_tapisJobUUID}&owner=${_tapisJobOwner}&clusterodm_url=$CLUSTERODM_URL" "${_webhook_base_url}/clusterodm" 2>/dev/null || echo "Legacy de-registration webhook sent"
    fi

    echo "🔗 NodeODM de-registration process completed"
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    echo "Cleaning up processes (exit code: $exit_code)..."

    checkpoint_sync "exit" "${TASK_UUID:-${NODEODM_RESUME_TASK_UUID:-}}" || true

    # Always notify PTDataX that NodeODM is shutting down (non-blocking)
    send_nodeodm_status_to_ptdatax "shutdown" "NodeODM instance shutting down - job ${_tapisJobUUID} complete"

    # De-register from ClusterODM before cleanup (make it more resilient)
    echo "De-registering from ClusterODM..."
    set +e  # Don't exit if deregistration fails
    deregister_from_clusterodm
    if [ $? -ne 0 ]; then
        echo "⚠️ ClusterODM deregistration failed, but continuing cleanup..."
    fi
    set -e

    # Kill specific PIDs if available
    if [ -n "$NODEODM_PID" ] && kill -0 $NODEODM_PID 2>/dev/null; then
        echo "Stopping NodeODM (PID: $NODEODM_PID)..."
        kill $NODEODM_PID 2>/dev/null || true
        sleep 3
        kill -9 $NODEODM_PID 2>/dev/null || true
    fi
    if [ -n "$COMPLETION_SERVER_PID" ] && kill -0 $COMPLETION_SERVER_PID 2>/dev/null; then
        echo "Stopping completion server (PID: $COMPLETION_SERVER_PID)..."
        kill $COMPLETION_SERVER_PID 2>/dev/null || true
    fi
    # Fallback cleanup
    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f apptainer 2>/dev/null || true
    # Clean up SSH tunnels
    pkill -f "ssh.*login" 2>/dev/null || true

    echo "Cleanup completed (exit code: $exit_code)"
}
# Trap cleanup on exit
trap cleanup EXIT

if ! checkpoint_restore_if_requested; then
    echo "ERROR: checkpoint restore failed"
    exit 1
fi

# Set up TAP token first (needed for NodeODM authentication)
echo "Setting up TAP authentication..."
if [[ "${SKIP_TAP_SETUP:-0}" == "1" ]]; then
    echo "SKIP_TAP_SETUP=1; skipping TAP setup and generating dummy token"
    TAP_TOKEN=${TAP_TOKEN:-"dummy-$(uuidgen 2>/dev/null || echo token)"}
    LOGIN_PORT=${LOGIN_PORT:-0}
else
    if ! load_tap_functions; then
        echo "WARNING: TAP functions unavailable; using dummy token"
        TAP_TOKEN=${TAP_TOKEN:-"dummy-$(uuidgen 2>/dev/null || echo token)"}
        LOGIN_PORT=${LOGIN_PORT:-0}
    elif ! get_tap_certificate; then
        echo "WARNING: TAP certificate missing; using dummy token"
        TAP_TOKEN=${TAP_TOKEN:-"dummy-$(uuidgen 2>/dev/null || echo token)"}
        LOGIN_PORT=${LOGIN_PORT:-0}
    else
        get_tap_token || TAP_TOKEN=${TAP_TOKEN:-"dummy-$(uuidgen 2>/dev/null || echo token)"}
        send_url_to_webhook || true
    fi
fi
echo "[TAP] Role=$NODEODM_ROLE PORT=$NODEODM_PORT LOGIN_PORT=${LOGIN_PORT:-n/a} TOKEN_PREFIX=${TAP_TOKEN:0:8}"

# Export for downstream tools (e.g., remote.py token auto-append), per-port and default.
export ODM_NODE_TOKEN="$TAP_TOKEN"
if [[ -n "$NODEODM_PORT" ]]; then
    export ODM_NODE_TOKEN_${NODEODM_PORT}="$TAP_TOKEN"
    echo "[TAP] Exported ODM_NODE_TOKEN and ODM_NODE_TOKEN_${NODEODM_PORT} for downstream consumers"
else
    echo "[TAP] Exported ODM_NODE_TOKEN for downstream consumers"
fi

# Start completion server after TAP token is available
start_completion_server

# Create NodeODM configuration file with TAP_TOKEN
PARALLEL_QUEUE=${NODEODM_PARALLEL_QUEUE:-$MAX_CONCURRENCY}
if [ "$PARALLEL_QUEUE" -lt 2 ]; then
    PARALLEL_QUEUE=2
fi

MAX_PARALLEL_TASKS=${NODEODM_MAX_PARALLEL_TASKS:-$MAX_CONCURRENCY}
if [ "$MAX_PARALLEL_TASKS" -lt 1 ]; then
    MAX_PARALLEL_TASKS=1
fi

NODEODM_CLEANUP_MINUTES="${NODEODM_CLEANUP_MINUTES:-0}"
if ! [[ "$NODEODM_CLEANUP_MINUTES" =~ ^-?[0-9]+$ ]]; then
    echo "Invalid NODEODM_CLEANUP_MINUTES=$NODEODM_CLEANUP_MINUTES; defaulting to 0"
    NODEODM_CLEANUP_MINUTES=0
fi
echo "Creating NodeODM configuration (maxConcurrency=$MAX_CONCURRENCY, maxParallelTasks=$MAX_PARALLEL_TASKS, parallelQueueProcessing=$PARALLEL_QUEUE, cleanupTasksAfter=${NODEODM_CLEANUP_MINUTES})..."
cat > $WORK_DIR/nodeodm-config.json << EOF
{
  "port": $NODEODM_PORT,
  "timeout": 0,
  "maxConcurrency": $MAX_CONCURRENCY,
  "maxImages": 0,
  "cleanupTasksAfter": ${NODEODM_CLEANUP_MINUTES},
  "token": "$TAP_TOKEN",
  "parallelQueueProcessing": $PARALLEL_QUEUE,
  "maxParallelTasks": $MAX_PARALLEL_TASKS,
  "odm_path": "/code",
  "logger": {
    "level": "silly",
    "logDirectory": "/var/www/logs"
  }
}
EOF

echo "NodeODM config created:"
cat $WORK_DIR/nodeodm-config.json

# Configure shared filesystem roots for import_path passthrough (can be disabled)
# Prefer the Tapis working dir if provided (so submodels under that tree are allowed)
if [[ -n "${_tapisJobWorkingDir:-}" ]]; then
    SHARED_IMPORT_ROOT="${NODEODM_IMPORT_PATH_ROOT:-${_tapisJobWorkingDir}}"
else
    SHARED_IMPORT_ROOT="${NODEODM_IMPORT_PATH_ROOT:-/corral-repl/tacc/aci/PT2050/projects/PTDATAX-263/webodm/media}"
fi
if [[ "${NODEODM_DISABLE_IMPORT_PATH:-0}" == "1" ]]; then
    unset NODEODM_IMPORT_PATH_ROOTS
    echo "NODEODM import_path passthrough disabled (NODEODM_DISABLE_IMPORT_PATH=1)"
else
    export NODEODM_IMPORT_PATH_ROOTS="$SHARED_IMPORT_ROOT"
    echo "NODEODM import_path roots: ${NODEODM_IMPORT_PATH_ROOTS}"
fi

# Force ODM remote to use import_path (avoid seed.zip fallback)
export ODM_REMOTE_USE_IMPORT_PATH=1
export ODM_IMPORT_PATH_BASE="${ODM_IMPORT_PATH_BASE:-${NODEODM_RUNTIME_DIR}/data}"

# Apptainer normally passes the environment through, but make the critical
# split-merge path variables explicit so GPU queue jobs cannot silently fall
# back to seed.zip uploads.
export APPTAINERENV_ODM_REMOTE_USE_IMPORT_PATH="$ODM_REMOTE_USE_IMPORT_PATH"
export SINGULARITYENV_ODM_REMOTE_USE_IMPORT_PATH="$ODM_REMOTE_USE_IMPORT_PATH"
export APPTAINERENV_ODM_IMPORT_PATH_BASE="$ODM_IMPORT_PATH_BASE"
export SINGULARITYENV_ODM_IMPORT_PATH_BASE="$ODM_IMPORT_PATH_BASE"
if [[ -n "${NODEODM_IMPORT_PATH_ROOTS:-}" ]]; then
    export APPTAINERENV_NODEODM_IMPORT_PATH_ROOTS="$NODEODM_IMPORT_PATH_ROOTS"
    export SINGULARITYENV_NODEODM_IMPORT_PATH_ROOTS="$NODEODM_IMPORT_PATH_ROOTS"
fi
if [[ -n "${_tapisJobWorkingDir:-}" ]]; then
    export APPTAINERENV__tapisJobWorkingDir="$_tapisJobWorkingDir"
    export SINGULARITYENV__tapisJobWorkingDir="$_tapisJobWorkingDir"
fi
echo "ODM split-merge import_path: enabled=${ODM_REMOTE_USE_IMPORT_PATH} base=${ODM_IMPORT_PATH_BASE}"

echo "Using HTTP with TAP_TOKEN authentication (no SSL proxy needed)"

# Preflight curl (will likely fail before startup; logged for diagnostics)
echo "Preflight: curl http://localhost:${NODEODM_PORT}/info?token=${TAP_TOKEN:0:8}... (expected fail before start)" | tee -a "$LOG_FILE"
curl -v --connect-timeout 5 "http://localhost:${NODEODM_PORT}/info?token=${TAP_TOKEN}" >> "$LOG_FILE" 2>&1 || true

echo "SIF image details:"
ls -lh "$NODEODM_SIF" || true
echo "Testing apptainer exec sanity on SIF..."
if ! apptainer exec "$NODEODM_SIF" /bin/true >> "$LOG_FILE" 2>&1; then
    echo "ERROR: apptainer exec sanity check failed for $NODEODM_SIF"
    exit 1
fi

echo "ODM runtime patch preflight:"
echo "  NODEODM_BIND_ARGS=$NODEODM_BIND_ARGS"
echo "  ODM_REMOTE_PATCH_SOURCE=$ODM_REMOTE_PATCH_SOURCE"
if [[ -f "$ODM_REMOTE_PATCH_SOURCE" ]]; then
    echo "  host remote.py sha256: $(sha256sum "$ODM_REMOTE_PATCH_SOURCE" 2>/dev/null | awk '{print $1}')"
    echo "  host remote.py import_path markers:"
    grep -n "ODM_REMOTE_USE_IMPORT_PATH\|Attempting import_path submission\|Using flattened import_path" "$ODM_REMOTE_PATCH_SOURCE" | head -20 || true
fi
apptainer exec \
    $NV_FLAG \
    --writable-tmpfs \
    --bind "$WORK_DIR/nodeodm-config.json:/tmp/nodeodm-config.json" \
    $NODEODM_BIND_ARGS \
    "$NODEODM_SIF" \
    bash -lc 'set +e
        echo "  container remote.py path: /code/opendm/remote.py"
        if command -v sha256sum >/dev/null 2>&1; then sha256sum /code/opendm/remote.py; fi
        echo "  container remote.py markers:"
        grep -n "ODM_REMOTE_USE_IMPORT_PATH\|Attempting import_path submission\|Using flattened import_path" /code/opendm/remote.py | head -20
        echo "  container python import:"
        python3 - <<'"'"'PY'"'"'
import inspect
try:
    import opendm.remote as remote
    print("opendm.remote.__file__=%s" % getattr(remote, "__file__", "unknown"))
    print("opendm.remote sha marker present=%s" % ("ODM_REMOTE_USE_IMPORT_PATH" in inspect.getsource(remote)))
except Exception as e:
    print("opendm.remote import failed=%s" % e)
PY
        echo "  container env import_path vars:"
        env | sort | grep -E "^(ODM_|NODEODM_IMPORT_PATH_ROOTS|_tapisJobWorkingDir|APPTAINERENV_ODM_|SINGULARITYENV_ODM_)" || true
    ' >> "$LOG_FILE" 2>&1 || echo "WARNING: ODM runtime patch preflight failed; continuing so job logs can capture later failure"

# Debug shell mode: keep the job/node alive and skip NodeODM launch so you can attach and run commands manually.
# Attach from login node with: srun --jobid $SLURM_JOB_ID --pty bash
# Then inside the node run the printed apptainer shell command.
if [[ "${NODEODM_DEBUG_SHELL:-0}" == "1" ]]; then
    echo "===================================================="
    echo "NODEODM_DEBUG_SHELL=1: skipping NodeODM start."
    echo "Attach to this node from login with:"
    echo "  srun --jobid ${SLURM_JOB_ID:-<jobid>} --pty bash"
    echo ""
    echo "Inside the node, to enter the container:"
    echo "  apptainer shell $NV_FLAG --writable-tmpfs \\"
    echo "    --bind $WORK_DIR/nodeodm-config.json:/tmp/nodeodm-config.json \\"
    echo "    $NODEODM_BIND_ARGS \\"
    echo "    \"$NODEODM_SIF\""
    echo ""
    echo "This job will stay alive for ${NODEODM_DEBUG_SLEEP:-43200} seconds (NODEODM_DEBUG_SLEEP to change)."
    echo "===================================================="
    sleep "${NODEODM_DEBUG_SLEEP:-43200}"
    exit 0
fi

# Debug skip mode: keep the job/node alive but do not start NodeODM.
if [[ "${NODEODM_SKIP_START:-0}" == "1" ]]; then
    echo "===================================================="
    echo "NODEODM_SKIP_START=1: skipping NodeODM start (debug hold)."
    echo "Attach to this node from login with:"
    echo "  srun --jobid ${SLURM_JOB_ID:-<jobid>} --pty bash"
    echo "You can then enter the container manually if needed."
    echo "This job will stay alive for ${NODEODM_DEBUG_SLEEP:-43200} seconds (NODEODM_DEBUG_SLEEP to change)."
    echo "===================================================="
    sleep "${NODEODM_DEBUG_SLEEP:-43200}"
    exit 0
fi

# Start NodeODM with HTTP and TAP_TOKEN authentication
echo "Starting NodeODM with HTTP and TAP_TOKEN authentication..."
NODEODM_EXIT_CODE_FILE="$WORK_DIR/nodeodm_exit_code"
rm -f "$NODEODM_EXIT_CODE_FILE"
(
    RUN_CMD=(apptainer exec \
        $NV_FLAG \
        --writable-tmpfs \
        --bind $WORK_DIR/nodeodm-config.json:/tmp/nodeodm-config.json \
        $NODEODM_BIND_ARGS \
        "$NODEODM_SIF" \
        bash -lc "set -euo pipefail; export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:\$PATH; \
                if [ \"\${NODEODM_DEBUG_START:-0}\" = \"1\" ]; then \
                    echo '[DEBUG] NODEODM_DEBUG_START=1 set, running container debug payload only'; \
                    env | sort; \
                    echo '--- ls -la / ---'; ls -la /; \
                    echo '--- ls -la /var/www ---'; ls -la /var/www; \
                    echo '--- node discovery ---'; \
                    (node --version && which node) || true; \
                    find / -maxdepth 5 -type f -name node -perm -111 2>/dev/null | head; \
                    echo '--- npm version ---'; npm --version || true; \
                    echo '--- head -n 40 /var/www/index.js ---'; head -n 40 /var/www/index.js || true; \
                    exit 0; \
                fi; \
                cd /var/www || exit 1; \
                echo \"[LAUNCH] pwd=\$(pwd)\"; \
                node --version && npm --version || true; \
                ls -la /var/www | head -40; \
                echo '[LAUNCH] ODM remote.py diagnostics'; \
                (sha256sum /code/opendm/remote.py || true); \
                (grep -n 'ODM_REMOTE_USE_IMPORT_PATH\|Attempting import_path submission\|Using flattened import_path' /code/opendm/remote.py | head -20 || true); \
                env | sort | grep -E '^(ODM_|NODEODM_IMPORT_PATH_ROOTS|_tapisJobWorkingDir)=' || true; \
                mkdir -p tmp data logs; \
                export ODM_AI_MODELS_PATH=\"${ODM_AI_MODELS_PATH}\"; \
                export ODM_REMOTE_USE_IMPORT_PATH=\"${ODM_REMOTE_USE_IMPORT_PATH}\"; \
                export ODM_IMPORT_PATH_BASE=\"${ODM_IMPORT_PATH_BASE}\"; \
                export NODEODM_IMPORT_PATH_ROOTS=\"${NODEODM_IMPORT_PATH_ROOTS:-}\"; \
                export _tapisJobWorkingDir=${_tapisJobWorkingDir}; \
                exec node index.js --config /tmp/nodeodm-config.json --log_level $NODEODM_LOG_LEVEL")
    if [[ "$REMORA_ENABLE" == "1" ]] && command -v remora >/dev/null 2>&1; then
        echo "Starting NodeODM under Remora (mode=$REMORA_MODE period=${REMORA_PERIOD}s)"
        remora "${RUN_CMD[@]}"
    else
        "${RUN_CMD[@]}"
    fi
    echo $? > "$NODEODM_EXIT_CODE_FILE"
) >> "$LOG_FILE" 2>&1 &

NODEODM_PID=$!
echo "NodeODM PID: $NODEODM_PID (HTTP port: $NODEODM_PORT with token: ${TAP_TOKEN:0:8}...)"

# Check if NodeODM process started
sleep 5
if ! kill -0 $NODEODM_PID 2>/dev/null; then
    echo "ERROR: NodeODM process died immediately"
    wait "$NODEODM_PID" 2>/dev/null
    NODEODM_EXIT_STATUS=$?
    if [ -z "$NODEODM_EXIT_STATUS" ] || [ "$NODEODM_EXIT_STATUS" -eq 127 ]; then
        if [ -f "$NODEODM_EXIT_CODE_FILE" ]; then
            NODEODM_EXIT_STATUS=$(cat "$NODEODM_EXIT_CODE_FILE")
        fi
    fi
    echo "Apptainer/NodeODM exit status: ${NODEODM_EXIT_STATUS:-unknown}"
    echo "${NODEODM_EXIT_STATUS:-unknown}" > "$NODEODM_EXIT_CODE_FILE"
    echo "Check startup logs:"
    tail -n 200 "$LOG_FILE"
    # Automatic one-time debug re-run inside container to capture env/layout if not already in debug mode.
    if [ "${NODEODM_DEBUG_START:-0}" != "1" ]; then
        echo "Re-running container once with NODEODM_DEBUG_START=1 for diagnostics..."
        NODEODM_DEBUG_START=1 \
        apptainer exec \
            $NV_FLAG \
            --writable-tmpfs \
            --bind $WORK_DIR/nodeodm-config.json:/tmp/nodeodm-config.json \
            $NODEODM_BIND_ARGS \
            "$NODEODM_SIF" \
            sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:\$PATH; \
                    echo '[DEBUG] NODEODM_DEBUG_START=1 forced after failure'; \
                    env | sort; \
                    echo '--- ls -la / ---'; ls -la /; \
                    echo '--- ls -la /var/www ---'; ls -la /var/www; \
                    echo '--- node discovery ---'; \
                    (node --version && which node) || true; \
                    find / -maxdepth 5 -type f -name node -perm -111 2>/dev/null | head; \
                    echo '--- npm version ---'; npm --version || true; \
                    echo '--- head -n 40 /var/www/index.js ---'; head -n 40 /var/www/index.js || true; \
                    exit 0" >> "$LOG_FILE" 2>&1 || true
        echo "Diagnostic run completed (see log above)."
    fi
    exit 1
fi

# Wait for NodeODM to start
echo "Waiting for NodeODM to initialize..."
sleep 15

# Test NodeODM connectivity with TAP_TOKEN
echo "Testing NodeODM connectivity with TAP_TOKEN authentication..."
for i in {1..10}; do
    # Test HTTP connection with token
    echo "🔧 CURL TEST $i: curl -s 'http://localhost:$NODEODM_PORT/info?token=${TAP_TOKEN:0:10}...'"
    NODEODM_INFO_TEST=$(curl -s "http://localhost:$NODEODM_PORT/info?token=$TAP_TOKEN" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$NODEODM_INFO_TEST" ]; then
        echo "✓ NodeODM is responding with token authentication on port $NODEODM_PORT"
        break
    else
        echo "  Attempt $i/10: NodeODM not ready yet..."
        sleep 10
    fi
done

# Final connectivity test and info gathering (using HTTP with token)
echo "🔧 CURL FINAL TEST: curl -s 'http://localhost:$NODEODM_PORT/info?token=${TAP_TOKEN:0:10}...'"
NODEODM_INFO=$(curl -s "http://localhost:$NODEODM_PORT/info?token=$TAP_TOKEN" 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$NODEODM_INFO" ]; then
    echo "✓ NodeODM connectivity confirmed"
    echo "NodeODM Info:"
    echo "$NODEODM_INFO"
    echo "$NODEODM_INFO" > $OUTPUT_DIR/nodeodm_info.json
    
    # Verify JSON response format
    if echo "$NODEODM_INFO" | grep -q '"version"'; then
        echo "✓ NodeODM API responding correctly"
    else
        echo "WARNING: NodeODM response format unexpected"
        echo "Response: $NODEODM_INFO"
    fi
else
    echo "ERROR: NodeODM failed to start properly"
    echo "Process status:"
    if kill -0 $NODEODM_PID 2>/dev/null; then
        echo "  NodeODM process is still running (PID: $NODEODM_PID)"
    else
        echo "  NodeODM process has died"
        if [ -f "$NODEODM_EXIT_CODE_FILE" ]; then
            echo "  NodeODM exit code: $(cat "$NODEODM_EXIT_CODE_FILE")"
        else
            echo "  NodeODM exit code file not found: $NODEODM_EXIT_CODE_FILE"
        fi
    fi
    
    echo "Port check:"
    if netstat -ln 2>/dev/null | grep :$NODEODM_PORT; then
        echo "  Port $NODEODM_PORT is listening"
    else
        echo "  Port $NODEODM_PORT is not listening"
    fi
    
    echo "Node processes:"
    ps aux | grep -E "node" | grep -v grep || echo "  No node processes found"
    
    echo "Startup logs:"
    if [ -f $LOG_FILE ]; then
        tail -50 $LOG_FILE
    else
        echo "  No log file found at $LOG_FILE"
    fi
    
    echo "Directory permissions:"
    ls -la $WORK_DIR/
    
    exit 1
fi

# Set up TAP external access if running on TACC
if [ -n "$SLURM_JOB_ID" ]; then
    echo "Setting up TAP external access..."
    if port_forwarding_tap; then
        echo "✓ TAP reverse tunneling setup successful"
        echo "External Access URL: http://ls6.tacc.utexas.edu:${LOGIN_PORT}/?token=${TAP_TOKEN}"
        EXTERNAL_URL="http://ls6.tacc.utexas.edu:${LOGIN_PORT}/?token=${TAP_TOKEN}"
    else
        echo "WARNING: TAP reverse tunneling failed"
        EXTERNAL_URL="N/A - use SSH tunnel"
    fi
else
    echo "Not running on TACC (no SLURM_JOB_ID), skipping TAP setup"
    EXTERNAL_URL="N/A - not on TACC"
fi

# Function to register NodeODM with ClusterODM via webhook API using Tapis JWT token
function register_with_clusterodm() {
    echo "[REGISTER] Starting registration flow (role=$NODEODM_ROLE child=${NODEODM_CHILD_INDEX:-primary} host=$(hostname) port=$NODEODM_PORT)"
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        # Extract hostname from external URL for ClusterODM registration
        NODEODM_HOST=$(echo "$EXTERNAL_URL" | sed 's|http[s]*://||' | cut -d: -f1)
        NODEODM_REGISTER_PORT=$(echo "$EXTERNAL_URL" | sed 's|.*:||' | cut -d? -f1 | sed 's|/||g')
    else
        # Use compute node hostname for direct registration
        NODEODM_HOST=$(hostname)
        NODEODM_REGISTER_PORT=$NODEODM_PORT
    fi

    echo "Attempting to register NodeODM with ClusterODM using webhook API..."
    echo "NodeODM Host: $NODEODM_HOST"
    echo "NodeODM Port: $NODEODM_REGISTER_PORT"
    echo "ClusterODM URL: $CLUSTERODM_URL"

    # Use direct curl command for webhook registration
    echo "Using webhook registration with Tapis JWT token..."

    # Prepare registration data
    REGISTRATION_UUID="${_tapisJobUUID%-*}"  # Remove any suffix like -007

    echo "Registration details:"
    echo "  UUID: $REGISTRATION_UUID"
    echo "  Host: $NODEODM_HOST"
    echo "  Port: $NODEODM_REGISTER_PORT"
    echo "  Token: ${TAP_TOKEN:0:10}..."
    echo "  Child index: ${NODEODM_CHILD_INDEX:-primary}"
    echo "  Role: ${NODEODM_ROLE:-admin}"
    echo "  Host ID: ${NODEODM_HOST_ID:-0}"
    echo "  Worker ID: ${NODEODM_WORKER_ID:-0}"
    echo "  Job index/count: ${NODEODM_JOB_INDEX:-1}/${NODEODM_JOB_COUNT:-1}"
    echo "  Replicas per job: ${NODEODM_REPLICAS_PER_JOB:-1}"

    # Direct curl registration call with job UUID mapping
    echo "Sending registration request to: $CLUSTERODM_URL/webhook/register-node"
    echo "Debug: CLUSTERODM_URL='$CLUSTERODM_URL'"
    echo "Debug: Full URL='$CLUSTERODM_URL/webhook/register-node'"

    # Prepare JSON payload with Tapis job owner for user-based authentication
    RESUME_JSON_FIELDS=""
    if [ -n "${NODEODM_RESUME_TASK_UUID:-}" ]; then
        RESUME_JSON_FIELDS=", \"checkpointResume\": true, \"resumeTaskUuid\": \"${NODEODM_RESUME_TASK_UUID}\", \"resumeMode\": \"${NODEODM_RESUME_MODE:-unknown}\", \"resumeFallbackReason\": \"${NODEODM_RESUME_FALLBACK_REASON:-}\""
    fi
    JSON_PAYLOAD="{\"hostname\": \"$NODEODM_HOST\", \"port\": $NODEODM_REGISTER_PORT, \"token\": \"$TAP_TOKEN\", \"uuid\": \"$REGISTRATION_UUID\", \"tapisJobUuid\": \"${_tapisJobUUID}\", \"tapisJobOwner\": \"${_tapisJobOwner}\", \"nodeReady\": true, \"childIndex\": \"${NODEODM_CHILD_INDEX:-primary}\", \"role\": \"${NODEODM_ROLE:-admin}\", \"hostId\": \"${NODEODM_HOST_ID:-0}\", \"workerId\": \"${NODEODM_WORKER_ID:-0}\", \"jobIndex\": \"${NODEODM_JOB_INDEX:-1}\", \"jobCount\": \"${NODEODM_JOB_COUNT:-1}\", \"replicasPerJob\": \"${NODEODM_REPLICAS_PER_JOB:-1}\"${RESUME_JSON_FIELDS}}"
    echo "Debug: JSON payload='$JSON_PAYLOAD'"

    # Show the exact curl command for manual testing
    echo ""
    echo "Manual registration command:"
    echo "curl -X POST '$CLUSTERODM_URL/webhook/register-node' \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -H 'Authorization: Bearer \${TAPIS_ACCESS_TOKEN}' \\"
    echo "  -d '$JSON_PAYLOAD'"
    echo ""

    # Check authentication options - prefer user ID over JWT token
    if [ -n "${TAPIS_ACCESS_TOKEN}" ] && [ "${TAPIS_ACCESS_TOKEN}" != "" ]; then
        echo "✅ Using TAPIS_ACCESS_TOKEN for authentication"
        AUTH_METHOD="jwt-token"
        EFFECTIVE_TOKEN="${TAPIS_ACCESS_TOKEN}"
    elif [ -n "${_tapisJobOwner}" ]; then
        echo "✅ Using Tapis Job Owner for authentication: ${_tapisJobOwner}"
        AUTH_METHOD="user-id"
        EFFECTIVE_TOKEN=""
    else
        echo "❌ WARNING: Neither _tapisJobOwner nor TAPIS_ACCESS_TOKEN is available"
        echo "Available Tapis environment variables:"
        env | grep -E "^_tapis" | sort || echo "No _tapis* variables found"
        echo ""
        echo "Using user ID authentication as fallback..."
        AUTH_METHOD="user-id"
        EFFECTIVE_TOKEN=""
    fi

    # Show the actual curl command being executed
    echo "🔧 EXECUTING CURL COMMAND ($AUTH_METHOD authentication):"
    echo "curl -s -w 'HTTP_CODE:%{http_code}' -X POST '$CLUSTERODM_URL/webhook/register-node' \\"
    echo "  -H 'Content-Type: application/json' \\"
    if [ -n "$EFFECTIVE_TOKEN" ]; then
        echo "  -H 'Authorization: Bearer ${EFFECTIVE_TOKEN:0:20}...' \\"  # Show first 20 chars of token
    else
        echo "  (No Authorization header - using user ID in payload)"
    fi
    echo "  -d '$JSON_PAYLOAD'"
    echo ""

    # Execute curl with or without Authorization header based on auth method
    if [ -n "$EFFECTIVE_TOKEN" ]; then
        REGISTRATION_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$CLUSTERODM_URL/webhook/register-node" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${EFFECTIVE_TOKEN}" \
            -d "$JSON_PAYLOAD")
    else
        REGISTRATION_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$CLUSTERODM_URL/webhook/register-node" \
            -H "Content-Type: application/json" \
            -d "$JSON_PAYLOAD")
    fi

    CURL_EXIT_CODE=$?

    if [ $CURL_EXIT_CODE -ne 0 ]; then
        echo "❌ Curl command failed with exit code: $CURL_EXIT_CODE"
        echo "Registration response: $REGISTRATION_RESPONSE"
        echo "   This may indicate network issues or ClusterODM is unreachable"
        return 7
    fi

    # Extract HTTP code and response body
    HTTP_CODE=$(echo "$REGISTRATION_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$REGISTRATION_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')

    echo "HTTP Code: $HTTP_CODE"
    echo "Response: $RESPONSE_BODY"

    if echo "$RESPONSE_BODY" | grep -q '"success":true'; then
        echo "✅ Successfully registered NodeODM with ClusterODM via webhook!"
        # Extract node ID from response if available
        NODE_ID=$(echo "$RESPONSE_BODY" | grep -o '"nodeId":[0-9]*' | cut -d: -f2)
        if [ -n "$NODE_ID" ]; then
            export REGISTERED_NODE_ID="$NODE_ID"
            echo "Node registration ID: $REGISTERED_NODE_ID"
        fi
    else
        echo "⚠️ Webhook registration failed (HTTP: $HTTP_CODE)"
        echo "Response: $RESPONSE_BODY"
        echo "   Manual registration may be needed: $CLUSTERODM_URL/admin"

        if [ "$HTTP_CODE" = "401" ]; then
            echo "   Authentication failed - check UUID or token"
        elif [ "$HTTP_CODE" = "500" ]; then
            echo "   Server error - check ClusterODM logs"
        fi
    fi

    # Legacy webhook notification for backward compatibility
    if [ -n "${_webhook_base_url}" ]; then
        echo "Sending additional webhook notifications..."
        curl -k --data "event_type=nodeodm_registration&hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&clusterodm_url=$CLUSTERODM_URL&external_url=${EXTERNAL_URL:-N/A}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}" "${_webhook_base_url}/clusterodm" 2>/dev/null || echo "Legacy webhook notification sent"
    fi

    echo "🔗 NodeODM registration process completed"
    echo "📋 Manual verification:"
    echo "   - Check ClusterODM admin: $CLUSTERODM_URL/admin"
    echo "   - Node should appear as: $NODEODM_HOST:$NODEODM_REGISTER_PORT"
}

# Function to notify ClusterODM that NodeODM is ready
function send_nodeodm_webhook() {
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_URL="$EXTERNAL_URL"
    else
        # Fallback to localhost for testing
        NODEODM_URL="http://localhost:$NODEODM_PORT?token=$TAP_TOKEN"
    fi

    echo "NodeODM webhook notification - URL: $NODEODM_URL"
    echo "Webhook base URL configured: ${_webhook_base_url:-'not set'}"

    # Check if webhook URL is configured and valid
    if [ -n "${_webhook_base_url}" ] && [ "${_webhook_base_url}" != "" ]; then
        CLUSTERODM_WEBHOOK_URL="${_webhook_base_url}"
        echo "Sending NodeODM ready notification to webhook: $CLUSTERODM_WEBHOOK_URL"

        # Prepare node info safely (avoid command substitution in curl)
        NODE_INFO_SAFE=$(echo "$NODEODM_INFO" | tr -d '\n' | sed 's/"/\\"/g')

        # Wait a few seconds for NodeODM to be fully ready, then send webhook
        (
            sleep 10 &&
            curl -k -s --data "event_type=nodeodm_ready&address=${NODEODM_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}&max_concurrency=${MAX_CONCURRENCY}&node_info=${NODE_INFO_SAFE}" "${CLUSTERODM_WEBHOOK_URL}" >/dev/null 2>&1 || echo "Legacy webhook notification failed"
        ) &

        echo "Legacy webhook notification scheduled for: $NODEODM_URL"
        echo "Legacy webhook endpoint: $CLUSTERODM_WEBHOOK_URL"
    else
        echo "No legacy webhook URL configured (_webhook_base_url not set or empty)"
        echo "Skipping legacy webhook notification"
        echo "NodeODM URL for manual access: $NODEODM_URL"
    fi
}

# Register with ClusterODM and send webhook notification after NodeODM is confirmed working
echo "=== Starting ClusterODM registration ==="
set +e  # Temporarily disable exit on error to handle registration issues gracefully
register_with_clusterodm
REGISTRATION_EXIT_CODE=$?

if [ $REGISTRATION_EXIT_CODE -ne 0 ]; then
    echo "❌ Registration failed with exit code: $REGISTRATION_EXIT_CODE"
    echo "Continuing without registration - NodeODM will still be accessible"
else
    echo "✅ Registration completed successfully"
fi

send_nodeodm_webhook
set -e  # Re-enable exit on error
echo "=== Registration phase completed ==="

# Send PTDataX webhook notifications
send_nodeodm_status_to_ptdatax "ready" "NodeODM instance ready and registered with ClusterODM"

# NodeODM is now ready - it will wait for tasks from ClusterODM
echo "NodeODM is ready and waiting for tasks from ClusterODM..."
echo "No automatic task processing - ClusterODM will send tasks when ready"

# Monitor for tasks and wait
echo "Monitoring for incoming tasks..."
TASK_UUID=""
TASK_OUTPUT_LINE=0
MONITORING_TIMEOUT=0

# Convert SLURM_TIMELIMIT to seconds (handles HH:MM:SS or minutes)
# Allow override via NODEODM_MONITOR_TIMEOUT_SEC (seconds) or NODEODM_MONITOR_TIMEOUT_HOURS.
DEFAULT_MONITOR_LIMIT=$((6 * 60 * 60))  # fall back to 6 hours
if [[ -n "${NODEODM_MONITOR_TIMEOUT_SEC:-}" ]]; then
    DEFAULT_MONITOR_LIMIT="${NODEODM_MONITOR_TIMEOUT_SEC}"
elif [[ -n "${NODEODM_MONITOR_TIMEOUT_HOURS:-}" ]]; then
    DEFAULT_MONITOR_LIMIT=$((NODEODM_MONITOR_TIMEOUT_HOURS * 3600))
fi
if [[ "$SLURM_TIMELIMIT" =~ ^[0-9]+$ ]]; then
    MAX_MONITORING_TIME=$((SLURM_TIMELIMIT * 60))
elif [[ "$SLURM_TIMELIMIT" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    HOURS=${BASH_REMATCH[1]}
    MINUTES=${BASH_REMATCH[2]}
    SECONDS=${BASH_REMATCH[3]}
    MAX_MONITORING_TIME=$((10#$HOURS * 3600 + 10#$MINUTES * 60 + 10#$SECONDS))
else
    MAX_MONITORING_TIME=$DEFAULT_MONITOR_LIMIT
fi

# Ensure positive integer
if ! [[ "$MAX_MONITORING_TIME" =~ ^[0-9]+$ ]] || [ "$MAX_MONITORING_TIME" -le 0 ]; then
    MAX_MONITORING_TIME=$DEFAULT_MONITOR_LIMIT
fi

while true; do
    # Check if any tasks have been submitted
    echo "🔧 CURL TASK CHECK: curl -s 'http://localhost:$NODEODM_PORT/task/list?token=${TAP_TOKEN:0:10}...'"
    TASK_LIST_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/list?token=$TAP_TOKEN")

    if echo "$TASK_LIST_RESPONSE" | grep -q '"uuid"'; then
        # Extract the first task UUID
        TASK_UUID=$(echo "$TASK_LIST_RESPONSE" | grep -o '"uuid":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Found task: $TASK_UUID"
        TASK_OUTPUT_LINE=0

        # Get task info to check status
        echo "🔧 CURL TASK STATUS: curl -s 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=${TAP_TOKEN:0:10}...'"
        STATUS_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=$TAP_TOKEN")
        STATUS=$(parse_task_status "$STATUS_RESPONSE")

        if [ "$STATUS" = "QUEUED" ] || [ "$STATUS" = "RUNNING" ]; then
            echo "Task $TASK_UUID is processing, monitoring progress..."
            send_nodeodm_status_to_ptdatax "processing" "NodeODM started processing task $TASK_UUID"
            checkpoint_sync "task-start" "$TASK_UUID"
            break
        fi
    fi

    # Check timeout
    MONITORING_TIMEOUT=$((MONITORING_TIMEOUT + 30))
    if [ "$MONITORING_TIMEOUT" -gt "$MAX_MONITORING_TIME" ]; then
        echo "Timeout waiting for tasks from ClusterODM"
        send_nodeodm_status_to_ptdatax "timeout" "NodeODM timed out waiting for tasks"
        exit 0
    fi

    echo "Waiting for task from ClusterODM... (${MONITORING_TIMEOUT}s elapsed)"
    sleep 30
done

# Monitor task progress
echo "Monitoring task progress for $TASK_UUID..."
while true; do
    echo "🔧 CURL PROGRESS CHECK: curl -s 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=${TAP_TOKEN:0:10}...'"
    STATUS_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=$TAP_TOKEN")
    STATUS=$(parse_task_status "$STATUS_RESPONSE")
    PROGRESS=$(parse_task_progress "$STATUS_RESPONSE")

    echo "Task status: $STATUS, Progress: ${PROGRESS:-0}%"
    stream_task_output
    maybe_checkpoint_sync

    case $STATUS in
        "COMPLETED")
            echo "✓ Task completed successfully"
            send_nodeodm_status_to_ptdatax "complete" "NodeODM task $TASK_UUID completed successfully"
            checkpoint_sync "completed" "$TASK_UUID"
            break
            ;;
        "FAILED")
            echo "✗ Task failed"
            echo "Error details:"
            echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4
            send_nodeodm_status_to_ptdatax "error" "NodeODM task $TASK_UUID failed: $(echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)"
            stream_task_output
            checkpoint_sync "failed" "$TASK_UUID"
            exit 1
            ;;
        "CANCELED")
            echo "✗ Task was canceled"
            send_nodeodm_status_to_ptdatax "error" "NodeODM task $TASK_UUID was canceled"
            stream_task_output
            checkpoint_sync "canceled" "$TASK_UUID"
            exit 1
            ;;
        *)
            sleep 30
            ;;
    esac
done

stream_task_output

# Download results
echo "Downloading results..."
echo "🔧 CURL DOWNLOAD: curl -s -o $OUTPUT_DIR/all.zip 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/all.zip?token=${TAP_TOKEN:0:10}...'"
curl -s -o $OUTPUT_DIR/all.zip "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/all.zip?token=$TAP_TOKEN"
echo "🔧 CURL DOWNLOAD: curl -s -o $OUTPUT_DIR/orthophoto.tif 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/orthophoto.tif?token=${TAP_TOKEN:0:10}...'"
curl -s -o $OUTPUT_DIR/orthophoto.tif "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/orthophoto.tif?token=$TAP_TOKEN"
echo "🔧 CURL DOWNLOAD: curl -s -o $OUTPUT_DIR/dsm.tif 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dsm.tif?token=${TAP_TOKEN:0:10}...'"
curl -s -o $OUTPUT_DIR/dsm.tif "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dsm.tif?token=$TAP_TOKEN"
echo "🔧 CURL DOWNLOAD: curl -s -o $OUTPUT_DIR/dtm.tif 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dtm.tif?token=${TAP_TOKEN:0:10}...'"
curl -s -o $OUTPUT_DIR/dtm.tif "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dtm.tif?token=$TAP_TOKEN"

# Wait for ClusterODM to signal that results have been transferred to WebODM
wait_for_completion_signal

# Generate processing report
echo "NodeODM Processing Report" > $OUTPUT_DIR/processing_report.txt
echo "========================" >> $OUTPUT_DIR/processing_report.txt
echo "Job Owner: ${_tapisJobOwner}" >> $OUTPUT_DIR/processing_report.txt
echo "Job UUID: ${_tapisJobUUID}" >> $OUTPUT_DIR/processing_report.txt
echo "Task UUID: $TASK_UUID" >> $OUTPUT_DIR/processing_report.txt
echo "Processing Time: $(date)" >> $OUTPUT_DIR/processing_report.txt
echo "Input Directory: $INPUT_DIR" >> $OUTPUT_DIR/processing_report.txt
echo "Output Directory: $OUTPUT_DIR" >> $OUTPUT_DIR/processing_report.txt
echo "Images Processed: $IMAGE_COUNT" >> $OUTPUT_DIR/processing_report.txt
echo "Max Concurrency: $MAX_CONCURRENCY" >> $OUTPUT_DIR/processing_report.txt
echo "Port: $NODEODM_PORT" >> $OUTPUT_DIR/processing_report.txt
echo "External URL: ${EXTERNAL_URL}" >> $OUTPUT_DIR/processing_report.txt
if [ -n "$LOGIN_PORT" ]; then
    echo "TAP Login Port: $LOGIN_PORT" >> $OUTPUT_DIR/processing_report.txt
fi
echo "" >> $OUTPUT_DIR/processing_report.txt
echo "NodeODM Info:" >> $OUTPUT_DIR/processing_report.txt
echo "$NODEODM_INFO" >> $OUTPUT_DIR/processing_report.txt

# List output files
echo "" >> $OUTPUT_DIR/processing_report.txt
echo "Output Files:" >> $OUTPUT_DIR/processing_report.txt
ls -la $OUTPUT_DIR >> $OUTPUT_DIR/processing_report.txt

echo "NodeODM processing completed successfully!"
echo "Results saved to: $OUTPUT_DIR"

echo ""
echo "========================================="
echo "NodeODM Processing Complete"
echo "========================================="
echo "Task UUID: $TASK_UUID"
echo "Images processed: $IMAGE_COUNT"
if [ -n "$SLURM_JOB_ID" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ]; then
    echo "External access: $EXTERNAL_URL"
    echo "Info endpoint: ${EXTERNAL_URL}info"
else
    echo "SSH tunnel required for external access:"
    echo "ssh -N -L $NODEODM_PORT:$(hostname):$NODEODM_PORT $USER@ls6.tacc.utexas.edu"
fi
echo "Local access: http://localhost:$NODEODM_PORT?token=$TAP_TOKEN"
echo "Output directory: $OUTPUT_DIR"
echo "========================================="
