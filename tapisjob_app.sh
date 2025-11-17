#!/bin/bash

# NodeODM processing script for Tapis
# Based on the working nodeodm.sh configuration - using ZIP runtime to access TACC modules
# ZIP runtime means we run directly on compute node and can use module load tacc-apptainer

if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
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
# Default NodeODM image (override with NODEODM_IMAGE to pin a forked build)
NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:latest}
# If set to 1, run directly from the container image code (no source overlay bind)
NODEODM_USE_IMAGE_SOURCE=${NODEODM_USE_IMAGE_SOURCE:-0}
ORIGINAL_ARGS=("$@")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

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
# Start log file early so we always have something to tail
echo "Starting NodeODM job (role=${NODEODM_ROLE:-admin} child=${NODEODM_CHILD_INDEX:-primary})" > "$LOG_FILE" || true

# Load required modules (from working nodeodm.sh)
echo "Loading required modules..."
module load tacc-apptainer

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
mkdir -p "$WORK_DIR"

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
chmod 777 "$NODEODM_RUNTIME_DIR/data" "$NODEODM_RUNTIME_DIR/tmp"

# Determine bind args for apptainer (overlay source vs. image code)
if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    NODEODM_BIND_ARGS="--bind $NODEODM_RUNTIME_DIR:/var/www:rw"
else
    NODEODM_BIND_ARGS="--bind $NODEODM_RUNTIME_DIR/data:/var/www/data:rw --bind $NODEODM_RUNTIME_DIR/tmp:/var/www/tmp:rw --bind $NODEODM_RUNTIME_DIR/logs:/var/www/logs:rw"
fi

echo "Runtime directory prepared:"
ls -la "$NODEODM_RUNTIME_DIR"

if [ "$NODEODM_USE_IMAGE_SOURCE" -eq 0 ]; then
    if [ ! -d "$NODEODM_RUNTIME_DIR/node_modules" ]; then
        echo "Extracting NodeODM node_modules from base container cache..."
        apptainer exec docker://$NODEODM_IMAGE \
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
	NODEODM_URL="https://${NODE_HOSTNAME_DOMAIN}:${LOGIN_PORT}/?token=${TAP_TOKEN}"
	INTERACTIVE_WEBHOOK_URL="${_webhook_base_url}"
	# Wait a few seconds for NodeODM to boot up and send webhook callback url for job ready notification.
	# Notification is sent to _INTERACTIVE_WEBHOOK_URL, e.g. https://ptdatax.tacc.utexas.edu/webhooks/interactive/
	(
		sleep 5 &&
			curl -k --data "event_type=nodeodm_session_ready&address=${NODEODM_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}&service_type=nodeodm&clusterodm_url=${CLUSTERODM_URL}" "${_INTERACTIVE_WEBHOOK_URL}" &
	) &

}

# Function to send NodeODM status updates to PTDataX
function send_nodeodm_status_to_ptdatax() {
    # PTDATAX webhook disabled for local/idev testing
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
    # Fallback cleanup
    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f apptainer 2>/dev/null || true
    # Clean up SSH tunnels
    pkill -f "ssh.*login" 2>/dev/null || true

    echo "Cleanup completed (exit code: $exit_code)"
}
# Trap cleanup on exit
trap cleanup EXIT

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


# Create NodeODM configuration file with TAP_TOKEN
PARALLEL_QUEUE=${NODEODM_PARALLEL_QUEUE:-$MAX_CONCURRENCY}
if [ "$PARALLEL_QUEUE" -lt 2 ]; then
    PARALLEL_QUEUE=2
fi

MAX_PARALLEL_TASKS=${NODEODM_MAX_PARALLEL_TASKS:-$MAX_CONCURRENCY}
if [ "$MAX_PARALLEL_TASKS" -lt 1 ]; then
    MAX_PARALLEL_TASKS=1
fi

echo "Creating NodeODM configuration (maxConcurrency=$MAX_CONCURRENCY, maxParallelTasks=$MAX_PARALLEL_TASKS, parallelQueueProcessing=$PARALLEL_QUEUE)..."
cat > $WORK_DIR/nodeodm-config.json << EOF
{
  "port": $NODEODM_PORT,
  "timeout": 0,
  "maxConcurrency": $MAX_CONCURRENCY,
  "maxImages": 0,
  "cleanupTasksAfter": 2880,
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
SHARED_IMPORT_ROOT="${NODEODM_IMPORT_PATH_ROOT:-/corral-repl/tacc/aci/PT2050/projects/PTDATAX-263/webodm/media}"
if [[ "${NODEODM_DISABLE_IMPORT_PATH:-0}" == "1" ]]; then
    unset NODEODM_IMPORT_PATH_ROOTS
    echo "NODEODM import_path passthrough disabled (NODEODM_DISABLE_IMPORT_PATH=1)"
else
    export NODEODM_IMPORT_PATH_ROOTS="$SHARED_IMPORT_ROOT"
    echo "NODEODM import_path roots: ${NODEODM_IMPORT_PATH_ROOTS}"
fi

echo "Using HTTP with TAP_TOKEN authentication (no SSL proxy needed)"

# Start NodeODM with HTTP and TAP_TOKEN authentication
echo "Starting NodeODM with HTTP and TAP_TOKEN authentication..."
apptainer exec \
    --writable-tmpfs \
    --bind $WORK_DIR/nodeodm-config.json:/tmp/nodeodm-config.json \
    $NODEODM_BIND_ARGS \
    docker://$NODEODM_IMAGE \
    sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:\$PATH; \
            # Newer NodeODM images use an nvm-based node and a node.sh wrapper. \
            NODE_BIN=\$(command -v node || command -v nodejs || find /usr/local/nvm -type f -path '*bin/node' 2>/dev/null | head -n1); \
            if [ -z \"\$NODE_BIN\" ] && [ -x /usr/local/bin/node.sh ]; then \
                echo \"node not found in PATH; falling back to /usr/local/bin/node.sh wrapper\"; \
                NODE_BIN=\"/usr/local/bin/node.sh\"; \
            fi; \
            if [ -z \"\$NODE_BIN\" ]; then \
                echo \"ERROR: node binary not found inside container\"; \
                exit 127; \
            fi; \
            export PATH=\$(dirname \"\$NODE_BIN\"):\$PATH; \
            echo \"Using node binary: \$NODE_BIN\"; \
            echo \"Listing /var/www to confirm bound source:\"; \
            ls -la /var/www | head -40; \
            echo \"Showing top of /var/www/index.js:\"; \
            head -n 40 /var/www/index.js || true; \
            cd /var/www && mkdir -p tmp data logs && \
            if [ ! -d node_modules ] || [ ! -f node_modules/winston/package.json ]; then \
              echo 'Installing NodeODM dependencies (npm install --production)...'; \
              npm install --production || exit 1; \
            fi && \
            exec \"\$NODE_BIN\" index.js --config /tmp/nodeodm-config.json --log_level $NODEODM_LOG_LEVEL" > $LOG_FILE 2>&1 &

NODEODM_PID=$!
echo "NodeODM PID: $NODEODM_PID (HTTP port: $NODEODM_PORT with token: ${TAP_TOKEN:0:8}...)"

# Check if NodeODM process started
sleep 5
if ! kill -0 $NODEODM_PID 2>/dev/null; then
    echo "ERROR: NodeODM process died immediately"
    echo "Check startup logs:"
    cat $LOG_FILE
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

    # Direct curl registration call with job UUID mapping
    echo "Sending registration request to: $CLUSTERODM_URL/webhook/register-node"
    echo "Debug: CLUSTERODM_URL='$CLUSTERODM_URL'"
    echo "Debug: Full URL='$CLUSTERODM_URL/webhook/register-node'"

    # Prepare JSON payload with Tapis job owner for user-based authentication
    JSON_PAYLOAD="{\"hostname\": \"$NODEODM_HOST\", \"port\": $NODEODM_REGISTER_PORT, \"token\": \"$TAP_TOKEN\", \"uuid\": \"$REGISTRATION_UUID\", \"tapisJobUuid\": \"${_tapisJobUUID}\", \"tapisJobOwner\": \"${_tapisJobOwner}\", \"nodeReady\": true}"
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
DEFAULT_MONITOR_LIMIT=$((2 * 60 * 60))  # fall back to 2 hours
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
        STATUS=$(echo "$STATUS_RESPONSE" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

        if [ "$STATUS" = "QUEUED" ] || [ "$STATUS" = "RUNNING" ]; then
            echo "Task $TASK_UUID is processing, monitoring progress..."
            send_nodeodm_status_to_ptdatax "processing" "NodeODM started processing task $TASK_UUID"
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
    STATUS=$(echo "$STATUS_RESPONSE" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    PROGRESS=$(echo "$STATUS_RESPONSE" | grep -o '"progress":[0-9]*' | cut -d':' -f2)

    echo "Task status: $STATUS, Progress: ${PROGRESS:-0}%"
    stream_task_output

    case $STATUS in
        "COMPLETED")
            echo "✓ Task completed successfully"
            send_nodeodm_status_to_ptdatax "complete" "NodeODM task $TASK_UUID completed successfully"
            break
            ;;
        "FAILED")
            echo "✗ Task failed"
            echo "Error details:"
            echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4
            send_nodeodm_status_to_ptdatax "error" "NodeODM task $TASK_UUID failed: $(echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)"
            stream_task_output
            exit 1
            ;;
        "CANCELED")
            echo "✗ Task was canceled"
            send_nodeodm_status_to_ptdatax "error" "NodeODM task $TASK_UUID was canceled"
            stream_task_output
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
