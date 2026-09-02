#!/bin/bash
#
# NodeODM Tapis ZIP Runtime - Main Entry Point
# Modular refactor: sources lib/*.sh modules
#

# NO set -a — explicit exports only via common.sh global contract
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Source modules in dependency order
source "$SCRIPT_DIR/lib/common.sh"          # 1. Globals, logging, curl wrapper, cleanup() trap
source "$SCRIPT_DIR/lib/tap_auth.sh"        # 2. TAP auth (no deps)
source "$SCRIPT_DIR/lib/nodeodm_launch.sh"  # 3. Needs TAP token, writes NODEODM_URL/PID
source "$SCRIPT_DIR/lib/clusterodm.sh"      # 4. Needs NODEODM_URL
source "$SCRIPT_DIR/lib/task_monitor.sh"    # 5. Needs NODEODM_URL, TASK_UUID
source "$SCRIPT_DIR/lib/checkpoint.sh"      # 6. Needs TASK_UUID, RUNTIME_DIR

# Verify all modules loaded successfully (fail fast)
verify_modules_loaded || exit 1

# Enable EXIT trap now that all modules are loaded
trap cleanup EXIT

# =============================================================================
# INITIALIZATION
# =============================================================================

# Group-writable default: NodeODM writes results back into the shared corral WebODM
# media tree, which is setgid + owned by the allocation group. umask 002 keeps those
# files g+rw so WebODM (and other group members) can manage them; the setgid dirs on
# the media tree supply the correct group.
# See docs/design/2026-07-01-corral-ownership-group-inheritance.md (odm-suite)
umask 002

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

# Detect GPU availability
detect_gpu

# Default NodeODM image (override with NODEODM_IMAGE to pin a forked build)
# NODEODM_IMAGE already set in detect_gpu()

# If set to 1, run directly from the container image code (no source overlay bind)
NODEODM_USE_IMAGE_SOURCE=${NODEODM_USE_IMAGE_SOURCE:-0}
# If set to 1, skip launching NodeODM (leave the job alive for debugging)
NODEODM_SKIP_START=${NODEODM_SKIP_START:-0}
# Default to normal run; set NODEODM_DEBUG_SHELL=1 to pause and attach for debugging.
NODEODM_DEBUG_SHELL=${NODEODM_DEBUG_SHELL:-0}
NODEODM_DEBUG_SLEEP=${NODEODM_DEBUG_SLEEP:-43200}
ORIGINAL_ARGS=("$@")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NODEODM_CHECKPOINT_ROOT=${NODEODM_CHECKPOINT_ROOT:-/corral/utexas/BCS26030/webodm/media/.nodeodm-checkpoints}
# Corral tree containing WebODM's shared media (import_path sources + .nodeodm-checkpoints).
# Apptainer does not auto-bind this, so without an explicit --bind the container cannot see it
# at all, even though the host process (and the allowlist checks in config.js) can.
NODEODM_CORRAL_MEDIA_ROOT=${NODEODM_CORRAL_MEDIA_ROOT:-/corral/utexas/BCS26030/webodm/media}
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

# Default NODEODM_MAX_REMOTE_TASKS to MAX_CONCURRENCY so the seed can dispatch
# as many concurrent submodel tasks as the cluster can handle.
# Override via imageSizeMapping.extraEnv or environment if a different cap is desired.
NODEODM_MAX_REMOTE_TASKS=${NODEODM_MAX_REMOTE_TASKS:-$MAX_CONCURRENCY}

echo "=== NodeODM Tapis Processing (ZIP Runtime) ==="
echo "Processing started by: ${_tapisJobOwner}"
echo "Job UUID: ${_tapisJobUUID}"
echo "Input directory: $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "Max concurrency: $MAX_CONCURRENCY"
echo "Max remote tasks (seed dispatch limit): $NODEODM_MAX_REMOTE_TASKS"
echo "Port: $NODEODM_PORT"
echo "NodeODM image: $NODEODM_IMAGE"
echo ""
echo "Authentication Debug Info:"
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

# Load required modules (from working nodeodm.sh)
echo "Loading required modules..."
if command -v module >/dev/null 2>&1; then
    # Temporarily disable set -u for TACC module system (bash completion references unbound BASH_COMPLETION_DEBUG)
    set +u
    module load tacc-apptainer
    set -u
else
    echo "module command not found (not on TACC); skipping module load"
fi

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

# Create output directory (namespace per LS6 node when fan-out is used)
if [[ "$NODEODM_CHILD" == "1" && -n "$NODEODM_CHILD_INDEX" ]]; then
    OUTPUT_DIR="${OUTPUT_DIR}/node-${NODEODM_CHILD_INDEX}"
fi
mkdir -p "$OUTPUT_DIR"
# Write logs inside the output tree so they're easy to find per node/child
LOG_DIR="$OUTPUT_DIR/logs"
mkdir -p "$LOG_DIR"

# Initialize logging
init_logging

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

# --- Cross-node activity coordination (multi-node fan-out only) ---
# LS6 allocates all nodes for a job up front, so an idle node cannot free capacity by
# exiting early anyway - it should stay up as long as ANY sibling node is still processing
# a task, since ClusterODM may still route it more work later. Coordination happens via a
# heartbeat file per node in the job's shared working directory (visible to all nodes on
# the same Lustre filesystem).
NODE_ACTIVITY_DIR=""
NODE_ACTIVITY_FILE=""
SHUTDOWN_FLAG=""
if [[ -n "$NODEODM_CHILD_INDEX" && -n "${_tapisJobWorkingDir:-}" ]]; then
    NODE_ACTIVITY_DIR="${_tapisJobWorkingDir}/.node_activity"
    NODE_ACTIVITY_FILE="${NODE_ACTIVITY_DIR}/${NODEODM_CHILD_INDEX}"
    SHUTDOWN_FLAG="${NODE_ACTIVITY_DIR}/shutdown.flag"
    mkdir -p "$NODE_ACTIVITY_DIR" 2>/dev/null || true
fi

# SIF image path (actual pull happens in nodeodm_launch.sh respecting NODEODM_SKIP_START)
NODEODM_SIF="$WORK_DIR/nodeodm.sif"

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
        # Retry rsync up to 3 times with backoff — Lustre can return EREMOTEIO
        # when multiple nodes rsync simultaneously
        rsync_ok=0
        for rsync_attempt in 1 2 3; do
            if rsync -a --delete "$NODEODM_SOURCE_DIR"/ "$NODEODM_RUNTIME_DIR"/; then
                rsync_ok=1
                break
            fi
            echo "rsync attempt $rsync_attempt failed (Lustre contention?), retrying in ${rsync_attempt}0s..."
            sleep $((rsync_attempt * 10))
        done
        if [[ "$rsync_ok" -ne 1 ]]; then
            echo "rsync failed after 3 attempts; falling back to cp -a"
            rm -rf "$NODEODM_RUNTIME_DIR"
            mkdir -p "$NODEODM_RUNTIME_DIR"
            cp -a "$NODEODM_SOURCE_DIR"/. "$NODEODM_RUNTIME_DIR"/
        fi
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
# container. Bind patched ODM files until the GPU image is rebuilt with the
# same code.
ODM_REMOTE_PATCH_BIND_ARGS=""
ODM_REMOTE_PATCH_SOURCE="${SCRIPT_DIR}/odm-patches/remote.py"
if [[ "${ODM_BIND_REMOTE_PATCH:-1}" == "1" && -f "$ODM_REMOTE_PATCH_SOURCE" ]]; then
    ODM_REMOTE_PATCH_BIND_ARGS="--bind $ODM_REMOTE_PATCH_SOURCE:/code/opendm/remote.py:ro"
    echo "ODM remote.py patch bind: $ODM_REMOTE_PATCH_SOURCE -> /code/opendm/remote.py"
else
    echo "ODM remote.py patch bind disabled or missing: $ODM_REMOTE_PATCH_SOURCE"
fi

ODM_OSFM_PATCH_BIND_ARGS=""
ODM_OSFM_PATCH_SOURCE="${SCRIPT_DIR}/odm-patches/osfm.py"
if [[ "${ODM_BIND_OSFM_PATCH:-1}" == "1" && -f "$ODM_OSFM_PATCH_SOURCE" ]]; then
    ODM_OSFM_PATCH_BIND_ARGS="--bind $ODM_OSFM_PATCH_SOURCE:/code/opendm/osfm.py:ro"
    echo "ODM osfm.py patch bind: $ODM_OSFM_PATCH_SOURCE -> /code/opendm/osfm.py"
else
    echo "ODM osfm.py patch bind disabled or missing: $ODM_OSFM_PATCH_SOURCE"
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

CORRAL_BIND=""
if [[ "${NODEODM_DISABLE_IMPORT_PATH:-0}" != "1" && -n "${NODEODM_CORRAL_MEDIA_ROOT:-}" && -d "$NODEODM_CORRAL_MEDIA_ROOT" ]]; then
    CORRAL_BIND="--bind ${NODEODM_CORRAL_MEDIA_ROOT}:${NODEODM_CORRAL_MEDIA_ROOT}:rw"
    echo "Binding corral webodm media root into container: ${NODEODM_CORRAL_MEDIA_ROOT}"
else
    echo "Corral webodm media root not bound (missing, or NODEODM_DISABLE_IMPORT_PATH=1): ${NODEODM_CORRAL_MEDIA_ROOT:-unset}"
fi

if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    NODEODM_BIND_ARGS="--bind $NODEODM_RUNTIME_DIR:/var/www:rw ${SCRATCH_BIND} ${RESUME_BIND} ${CORRAL_BIND} ${ODM_CODE_STORAGE_BIND_ARGS} ${ODM_REMOTE_PATCH_BIND_ARGS} ${ODM_OSFM_PATCH_BIND_ARGS}"
else
    NODEODM_BIND_ARGS="--bind $NODEODM_RUNTIME_DIR/data:/var/www/data:rw --bind $NODEODM_RUNTIME_DIR/tmp:/var/www/tmp:rw --bind $NODEODM_RUNTIME_DIR/logs:/var/www/logs:rw ${SCRATCH_BIND} ${RESUME_BIND} ${CORRAL_BIND} ${ODM_CODE_STORAGE_BIND_ARGS} ${ODM_REMOTE_PATCH_BIND_ARGS} ${ODM_OSFM_PATCH_BIND_ARGS}"
fi

echo "Runtime directory prepared:"
ls -la "$NODEODM_RUNTIME_DIR"

# Ensure SIF image exists BEFORE extracting node_modules (which needs the SIF)
if [[ "${NODEODM_SKIP_START:-0}" != "1" ]]; then
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
else
    echo "NODEODM_SKIP_START=1; skipping SIF pull"
fi

# Extract node_modules from base container cache (skip if NODEODM_SKIP_START)
if [[ "${NODEODM_SKIP_START:-0}" != "1" ]]; then
    extract_node_modules
else
    echo "NODEODM_SKIP_START=1; skipping node_modules extraction"
fi

# =============================================================================
# TAP AUTHENTICATION SETUP
# =============================================================================
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
# Use user ID as the node auth token (stable, never expires) instead of TAP_TOKEN
export ODM_NODE_TOKEN="$_tapisJobOwner"
if [[ -n "$NODEODM_PORT" ]]; then
    export ODM_NODE_TOKEN_${NODEODM_PORT}="$_tapisJobOwner"
    echo "[TAP] Exported ODM_NODE_TOKEN and ODM_NODE_TOKEN_${NODEODM_PORT} for downstream consumers (user ID: $_tapisJobOwner)"
else
    echo "[TAP] Exported ODM_NODE_TOKEN for downstream consumers (user ID: $_tapisJobOwner)"
fi

# Start completion server after TAP token is available
start_completion_server

# =============================================================================
# NODEODM CONFIGURATION & LAUNCH
# =============================================================================
# Create NodeODM configuration file with user ID as auth token
create_nodeodm_config

# Prepare runtime directory (import_path config, env exports, preflight checks)
prepare_runtime_dir

# Launch NodeODM
launch_nodeodm

# Verify NodeODM connectivity
verify_nodeodm_startup

# =============================================================================
# TAP EXTERNAL ACCESS
# =============================================================================
# Set up TAP external access if running on TACC
if [ -n "$SLURM_JOB_ID" ]; then
    echo "Setting up TAP external access..."
    if port_forwarding_tap; then
        echo "TAP reverse tunneling setup successful"
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

# =============================================================================
# CLUSTERODM REGISTRATION
# =============================================================================
echo "=== Starting ClusterODM registration ==="
set +e  # Temporarily disable exit on error to handle registration issues gracefully
register_with_clusterodm
REGISTRATION_EXIT_CODE=$?

if [ $REGISTRATION_EXIT_CODE -ne 0 ]; then
    echo "Registration failed with exit code: $REGISTRATION_EXIT_CODE"
    echo "Continuing without registration - NodeODM will still be accessible"
else
    echo "Registration completed successfully"
fi

send_nodeodm_webhook
set -e  # Re-enable exit on error
echo "=== Registration phase completed ==="

# Send PTDataX webhook notifications
send_nodeodm_status_to_ptdatax "ready" "NodeODM instance ready and registered with ClusterODM"

# =============================================================================
# MAIN TASK MONITORING LOOP
# =============================================================================
# NodeODM is now ready - it will wait for tasks from ClusterODM
echo "NodeODM is ready and waiting for tasks from ClusterODM..."
echo "No automatic task processing - ClusterODM will send tasks when ready"

monitor_tasks

# Cleanup handled by EXIT trap in common.sh
