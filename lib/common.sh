#!/bin/bash
#
# lib/common.sh - Shared globals, logging, utilities, cleanup trap, module verification
# Source FIRST - sets up environment for all other modules
#

# Prevent double-sourcing
[[ -n "${_LIB_COMMON_SH:-}" ]] && return 0
readonly _LIB_COMMON_SH=1

# =============================================================================
# GLOBAL CONTRACT - Explicit declare for cross-module variables
# =============================================================================
# =============================================================================
# MULTI-NODE LAUNCH HELPER
# =============================================================================
launch_multi_node_workers() {
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
        if [[ $host_idx -eq 1 ]]; then
            # First node = admin
            local child_index="${host_idx}-admin"
            local child_role="admin"
            local worker_id=0
            echo "[MULTI] Launching admin on $host (index $child_index)"
        else
            # Subsequent nodes = workers
            local child_index="${host_idx}-worker"
            local child_role="worker"
            local worker_id=$((host_idx - 1))
            echo "[MULTI] Launching worker on $host (index $child_index)"
        fi
        srun --overlap --nodes=1 --ntasks=1 -w "$host" bash -lc \
            "cd \"$working_dir\" && export NODEODM_CHILD=1 NODEODM_CHILD_INDEX=$child_index NODEODM_CHILD_ROLE=$child_role NODEODM_HOST_ID=$host_idx NODEODM_WORKER_ID=$worker_id && exec \"$SCRIPT_DIR/tapisjob_app.sh\"$replay_args" &
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

# Tapis/env inputs (set by Tapis or environment before module load)
# Set defaults for local testing (override with SKIP_TAP_SETUP=1)
export _tapisJobUUID="${_tapisJobUUID:-test-$(uuidgen 2>/dev/null || echo localjob)}"
export _tapisJobOwner="${_tapisJobOwner:-localuser}"
export _tapisJobWorkingDir="${_tapisJobWorkingDir:-/tmp/test-work}"
export SLURM_JOB_ID="${SLURM_JOB_ID:-local-$$}"
export SLURM_NODELIST="${SLURM_NODELIST:-$(hostname)}"
export SLURM_JOB_PARTITION="${SLURM_JOB_PARTITION:-cpu}"
export SLURM_TIMELIMIT="${SLURM_TIMELIMIT:-7200}"
export NODEODM_PORT="${NODEODM_PORT:-3001}"
export NODEODM_LOG_LEVEL="${NODEODM_LOG_LEVEL:-silly}"
export NODEODM_IMAGE="${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:latest}"
export NODEODM_MONITOR_TIMEOUT_SEC="${NODEODM_MONITOR_TIMEOUT_SEC:-}"
export NODEODM_MONITOR_TIMEOUT_HOURS="${NODEODM_MONITOR_TIMEOUT_HOURS:-}"
export NODEODM_CHECKPOINT_ROOT="${NODEODM_CHECKPOINT_ROOT:-/corral/utexas/BCS26030/webodm/media/.nodeodm-checkpoints}"
export NODEODM_CORRAL_MEDIA_ROOT="${NODEODM_CORRAL_MEDIA_ROOT:-/corral/utexas/BCS26030/webodm/media}"
export NODEODM_CHECKPOINT_INTERVAL_SECONDS="${NODEODM_CHECKPOINT_INTERVAL_SECONDS:-900}"
export NODEODM_CHECKPOINT_RETENTION_SECONDS="${NODEODM_CHECKPOINT_RETENTION_SECONDS:-604800}"
export NODEODM_CHECKPOINT_COPY_DATA="${NODEODM_CHECKPOINT_COPY_DATA:-0}"

# Tapis execution directories (for local testing)
export _tapisExecSystemInputDir="${_tapisExecSystemInputDir:-/tmp/test-input}"
export _tapisExecSystemOutputDir="${_tapisExecSystemOutputDir:-/tmp/test-output}"

# Optional Tapis/ClusterODM vars (defaults for local testing)
export _tapisAccessToken="${_tapisAccessToken:-}"
export _webhook_base_url="${_webhook_base_url:-}"

# Module outputs (explicit export for cross-module variables; globals by default in bash)
# Set defaults to satisfy set -u; actual values assigned in main/modules
export LOG_FILE="" RUNTIME_DIR="" SIF_PATH="" NODEODM_URL="" NODEODM_PID=""
export ODM_NODE_TOKEN="" ODM_NODE_TOKEN_${NODEODM_PORT:-3001}=""
export TASK_UUID="" TASK_STATUS="" CHECKPOINT_DIR=""
export TAP_TOKEN="" LOGIN_PORT="" EXTERNAL_URL=""
export NODEODM_BIND_ARGS="" NODEODM_SIF=""
export COMPLETION_SERVER_PID="" NODEODM_EXIT_CODE_FILE=""
export COMPLETE_FLAG="" NODEODM_COMPLETE_TOKEN="" NODEODM_COMPLETE_PORT=""
export NODEODM_ROLE="${NODEODM_ROLE:-admin}" NODEODM_CHILD="${NODEODM_CHILD:-0}" NODEODM_CHILD_INDEX="${NODEODM_CHILD_INDEX:-primary}" NODEODM_CHILD_ROLE="${NODEODM_CHILD_ROLE:-admin}"
export NODEODM_HOST_ID="${NODEODM_HOST_ID:-0}" NODEODM_WORKER_ID="${NODEODM_WORKER_ID:-0}" NODEODM_JOB_INDEX="${NODEODM_JOB_INDEX:-1}" NODEODM_JOB_COUNT="${NODEODM_JOB_COUNT:-1}"
export NODEODM_REPLICAS_PER_JOB="1" MAX_CONCURRENCY="12"
export NODEODM_USE_IMAGE_SOURCE="${NODEODM_USE_IMAGE_SOURCE:-0}"
export NODEODM_SKIP_START="${NODEODM_SKIP_START:-0}"
export NODEODM_DEBUG_SHELL="${NODEODM_DEBUG_SHELL:-0}"
export NODEODM_DISABLE_IMPORT_PATH="0" ODM_REMOTE_USE_IMPORT_PATH="1" ODM_IMPORT_PATH_BASE=""
export NODEODM_IMPORT_PATH_ROOTS="" _tapisJobWorkingDir=""
export NV_FLAG="" HAS_GPU="0"
export INPUT_DIR="" OUTPUT_DIR="" WORK_DIR="" WORK_DIR_BASE=""
export ORIGINAL_ARGS=()
export CHECKPOINT_LAST_SYNC="0" CHECKPOINT_SYNCING="0"
export NODE_ACTIVITY_DIR="" NODE_ACTIVITY_FILE="" SHUTDOWN_FLAG=""
export REGISTERED_NODE_ID="" REGISTRATION_UUID=""
export TASK_OUTPUT_LINE="0"
export NODE_EXIT_STATUS="0"
export NODEODM_PRESERVE_ON_EXIT="${NODEODM_PRESERVE_ON_EXIT:-0}"

# Internal state
MODULES_LOADED=0

# =============================================================================
# LOGGING SETUP
# =============================================================================
# Mirror output to stdout and log, wrap curl for verbose tracing
# curl debug output goes to stderr to avoid polluting command substitution stdout
curl() {
    printf '\n>>> curl' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    command curl -v "$@"
}

# Start log file early so we always have something to tail
init_logging() {
    if [[ -n "$NODEODM_CHILD_INDEX" ]]; then
        LOG_FILE="${LOG_DIR}/${NODEODM_CHILD_INDEX}_nodeodm.log"
    else
        LOG_FILE="${LOG_DIR}/nodeodm.log"
    fi
    # Save original stdout for command substitution (which only captures stdout)
    exec 3>&1
    # Mirror output to log (stdout) and keep stderr separate for command substitution
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    echo "Starting NodeODM job (role=${NODEODM_ROLE:-admin} child=${NODEODM_CHILD_INDEX:-primary})" > "$LOG_FILE" || true
}

# =============================================================================
# MULTI-NODE COORDINATION
# =============================================================================
mark_node_active() {
    [[ -n "$NODE_ACTIVITY_FILE" ]] || return 0
    mkdir -p "$NODE_ACTIVITY_DIR" 2>/dev/null || true
    touch "$NODE_ACTIVITY_FILE" 2>/dev/null || true
}

mark_node_idle() {
    [[ -n "$NODE_ACTIVITY_FILE" ]] || return 0
    rm -f "$NODE_ACTIVITY_FILE" 2>/dev/null || true
}

any_sibling_active() {
    [[ -n "$NODE_ACTIVITY_DIR" ]] || return 1
    local stale_after=90
    local now f mtime
    now=$(date +%s)
    for f in "$NODE_ACTIVITY_DIR"/*; do
        [[ -e "$f" ]] || continue
        [[ "$f" == "$NODE_ACTIVITY_FILE" ]] && continue
        [[ "$f" == "$SHUTDOWN_FLAG" ]] && continue
        mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
        if [[ $((now - mtime)) -le "$stale_after" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if all nodes are idle (no active siblings)
all_nodes_idle() {
    [[ -n "$NODE_ACTIVITY_DIR" ]] || return 1
    ! any_sibling_active
}

# Check if the coordinated shutdown flag exists
is_shutdown_requested() {
    [[ -n "$SHUTDOWN_FLAG" && -f "$SHUTDOWN_FLAG" ]]
}

# =============================================================================
# MODULE VERIFICATION
# =============================================================================
verify_modules_loaded() {
    local required_functions=(
        # tap_auth.sh
        "get_tap_certificate" "get_tap_token" "load_tap_functions"
        "port_forwarding_tap" "send_url_to_webhook"
        # nodeodm_launch.sh
        "create_nodeodm_config" "prepare_runtime_dir" "extract_node_modules"
        "preflight_checks" "launch_nodeodm" "verify_nodeodm_startup"
        # clusterodm.sh
        "register_with_clusterodm" "send_nodeodm_webhook" "deregister_from_clusterodm"
        # task_monitor.sh
        "monitor_tasks" "wait_for_task" "monitor_task_progress"
        "stream_task_output" "parse_task_status" "parse_task_progress"
        # checkpoint.sh
        "checkpoint_sync" "checkpoint_write_manifest" "checkpoint_restore_if_requested"
        "checkpoint_restore_from_scratch" "checkpoint_apply_resume_state"
        "checkpoint_prepare_cold_start" "checkpoint_path_allowed_for_resume"
    )
    
    local missing=0
    for fn in "${required_functions[@]}"; do
        if ! declare -f "$fn" >/dev/null; then
            echo "ERROR: Required function '$fn' not found - module not loaded" >&2
            missing=1
        fi
    done
    
    if [[ "$missing" -eq 1 ]]; then
        echo "FATAL: One or more modules failed to load. Check ZIP package." >&2
        return 1
    fi
    
    MODULES_LOADED=1
    return 0
}

# =============================================================================
# CLEANUP TRAP
# =============================================================================
cleanup() {
    local exit_code=$?
    echo "Cleaning up processes (exit code: $exit_code)..."

    # When NODEODM_PRESERVE_ON_EXIT is set, the monitoring loop exited normally and
    # NodeODM should stay alive to accept new tasks from ClusterODM. Skip all
    # cleanup that would kill or deregister the node.
    if [ "$NODEODM_PRESERVE_ON_EXIT" = "1" ]; then
        echo "NODEODM_PRESERVE_ON_EXIT=1; keeping NodeODM (PID: ${NODEODM_PID:-unknown}) alive for new tasks"
        echo "Skipping deregistration, shutdown notification, and process cleanup"
        echo "Cleanup completed (exit code: $exit_code) — NodeODM preserved"
        return 0
    fi

    mark_node_idle

    # Clean up shutdown flag if this node wrote it (admin node)
    if [[ "$NODEODM_ROLE" == "admin" && -n "$SHUTDOWN_FLAG" && -f "$SHUTDOWN_FLAG" ]]; then
        echo "Removing coordinated shutdown flag: $SHUTDOWN_FLAG"
        rm -f "$SHUTDOWN_FLAG" 2>/dev/null || true
    fi

    checkpoint_sync "exit" "${TASK_UUID:-${NODEODM_RESUME_TASK_UUID:-}}" || true

    # Always notify PTDataX that NodeODM is shutting down (non-blocking)
    send_nodeodm_status_to_ptdatax "shutdown" "NodeODM instance shutting down - job ${_tapisJobUUID} complete"

    # De-register from ClusterODM before cleanup (make it more resilient)
    echo "De-registering from ClusterODM..."
    set +e  # Don't exit if deregistration fails
    deregister_from_clusterodm
    if [ $? -ne 0 ]; then
        echo "WARNING: ClusterODM deregistration failed, but continuing cleanup..."
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

# Disable EXIT trap during module loading, enable after all modules loaded
trap - EXIT
# Trap will be set in main script after verify_modules_loaded()

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================
detect_gpu() {
    if nvidia-smi >/dev/null 2>&1; then
        HAS_GPU=1
        NV_FLAG="--nv"
        NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:gpu}
    elif [[ "${SLURM_JOB_PARTITION:-}" == *gpu* ]]; then
        HAS_GPU=1
        NV_FLAG="--nv"
        NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:gpu}
    else
        HAS_GPU=0
        NV_FLAG=""
        NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/wmobley/nodeodm:latest}
    fi
    echo "GPU detected: $HAS_GPU (partition='${SLURM_JOB_PARTITION:-}', NV_FLAG='$NV_FLAG')"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
checkpoint_dir_for_task() {
    local uuid="$1"
    if [ -n "$NODEODM_RESUME_CHECKPOINT_PATH" ] && [ "$uuid" = "${NODEODM_RESUME_TASK_UUID:-}" ]; then
        printf "%s\n" "$NODEODM_RESUME_CHECKPOINT_PATH"
    else
        printf "%s/%s\n" "${NODEODM_CHECKPOINT_ROOT%/}" "$uuid"
    fi
}

checkpoint_resolve_path() {
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

add_resume_bind() {
    local bind_path="$1"
    if [[ -z "$bind_path" || ! -d "$bind_path" ]]; then
        return 0
    fi
    case " $RESUME_BIND " in
        *" --bind ${bind_path}:${bind_path}:rw "*) return 0 ;;
    esac
    RESUME_BIND="${RESUME_BIND} --bind ${bind_path}:${bind_path}:rw"
}