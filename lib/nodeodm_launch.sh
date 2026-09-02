#!/bin/bash
#
# lib/nodeodm_launch.sh - Config generation, SIF prep, container launch, verify startup
# Source THIRD - needs TAP token from tap_auth.sh
#

[[ -n "${_LIB_NODEODM_LAUNCH_SH:-}" ]] && return 0
readonly _LIB_NODEODM_LAUNCH_SH=1

# =============================================================================
# NODEODM CONFIGURATION
# =============================================================================
create_nodeodm_config() {
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
  "token": "${_tapisJobOwner}",
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
}

# =============================================================================
# RUNTIME DIRECTORY PREPARATION
# =============================================================================
prepare_runtime_dir() {
    # Configure shared filesystem roots for import_path passthrough (can be disabled)
    # Prefer the Tapis working dir if provided (so submodels under that tree are allowed)
    if [[ -n "${_tapisJobWorkingDir:-}" ]]; then
        SHARED_IMPORT_ROOT="${NODEODM_IMPORT_PATH_ROOT:-${_tapisJobWorkingDir}}"
    else
        SHARED_IMPORT_ROOT="${NODEODM_IMPORT_PATH_ROOT:-/corral/utexas/BCS26030/webodm/media}"
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
    # Pass through NODEODM_MAX_REMOTE_TASKS to override the remote.py auto-calibration cap.
    # Set this in imageSizeMapping.extraEnv or tapisjob_app.sh to control how many submodel
    # tasks the seed can dispatch concurrently across the cluster.
    if [[ -n "${NODEODM_MAX_REMOTE_TASKS:-}" ]]; then
        export APPTAINERENV_NODEODM_MAX_REMOTE_TASKS="$NODEODM_MAX_REMOTE_TASKS"
        export SINGULARITYENV_NODEODM_MAX_REMOTE_TASKS="$NODEODM_MAX_REMOTE_TASKS"
    fi
    echo "ODM split-merge import_path: enabled=${ODM_REMOTE_USE_IMPORT_PATH} base=${ODM_IMPORT_PATH_BASE}"

    echo "Using HTTP with node auth token (user ID) for ClusterODM communication"

    # Preflight curl (will likely fail before startup; logged for diagnostics)
    echo "Preflight: curl http://localhost:${NODEODM_PORT}/info?token=${_tapisJobOwner}... (expected fail before start)" | tee -a "$LOG_FILE"
    curl -v --connect-timeout 5 "http://localhost:${NODEODM_PORT}/info?token=${_tapisJobOwner}" >> "$LOG_FILE" 2>&1 || true

    # Ensure we have a local SIF image for NodeODM to avoid repeated remote pulls
    # Skip if NODEODM_SKIP_START=1 (local testing without Apptainer)
    if [[ "${NODEODM_SKIP_START:-0}" != "1" ]]; then
        echo "Ensuring local SIF image at: $NODEODM_SIF"
        if [ ! -f "$NODEODM_SIF" ]; then
            echo "Pulling NodeODM image into local SIF..."
            if ! apptainer pull "$NODEODM_SIF" "docker://$NODEODM_IMAGE"; then
                echo "ERROR: Failed to pull NodeODM image to $NODEODM_SIF"
                exit 1
            fi
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

    echo "SIF image details:"
    ls -lh "$NODEODM_SIF" 2>/dev/null || echo "SIF not yet pulled (NODEODM_SKIP_START=1)"
    echo "Testing apptainer exec sanity on SIF..."
    if [[ "${NODEODM_SKIP_START:-0}" != "1" ]]; then
        if ! apptainer exec "$NODEODM_SIF" /bin/true >> "$LOG_FILE" 2>&1; then
            echo "ERROR: apptainer exec sanity check failed for $NODEODM_SIF"
            exit 1
        fi
    else
        echo "Skipping apptainer sanity check (NODEODM_SKIP_START=1)"
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
            env | sort | grep -E "^(ODM_|NODEODM_IMPORT_PATH_ROOTS|NODEODM_MAX_REMOTE_TASKS|_tapisJobWorkingDir|APPTAINERENV_ODM_|SINGULARITYENV_ODM_)" || true
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
}

extract_node_modules() {
    if [[ "${NODEODM_SKIP_START:-0}" == "1" ]]; then
        echo "NODEODM_SKIP_START=1; skipping node_modules extraction"
        return 0
    fi
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
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================
preflight_checks() {
    echo "Starting NodeODM with HTTP and user ID authentication..."
    NODEODM_EXIT_CODE_FILE="$WORK_DIR/nodeodm_exit_code"
    rm -f "$NODEODM_EXIT_CODE_FILE"
    
    if [[ "${NODEODM_SKIP_START:-0}" == "1" ]]; then
        echo "NODEODM_SKIP_START=1; skipping SIF verification and launch"
        return 0
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
            env | sort | grep -E "^(ODM_|NODEODM_IMPORT_PATH_ROOTS|NODEODM_MAX_REMOTE_TASKS|_tapisJobWorkingDir|APPTAINERENV_ODM_|SINGULARITYENV_ODM_)" || true
        ' >> "$LOG_FILE" 2>&1 || echo "WARNING: ODM runtime patch preflight failed; continuing so job logs can capture later failure"
}

# =============================================================================
# LAUNCH NODEODM
# =============================================================================
launch_nodeodm() {
    if [[ "${NODEODM_SKIP_START:-0}" == "1" ]]; then
        echo "NODEODM_SKIP_START=1; skipping NodeODM launch"
        return 0
    fi
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
                    env | sort | grep -E '^(ODM_|NODEODM_IMPORT_PATH_ROOTS|NODEODM_MAX_REMOTE_TASKS|_tapisJobWorkingDir)=' || true; \
                    mkdir -p tmp data logs; \
                    export ODM_AI_MODELS_PATH=\"${ODM_AI_MODELS_PATH}\"; \
                    export ODM_REMOTE_USE_IMPORT_PATH=\"${ODM_REMOTE_USE_IMPORT_PATH}\"; \
                    export ODM_IMPORT_PATH_BASE=\"${ODM_IMPORT_PATH_BASE}\"; \
                    export NODEODM_IMPORT_PATH_ROOTS=\"${NODEODM_IMPORT_PATH_ROOTS:-}\"; \
                    export NODEODM_MAX_REMOTE_TASKS=\"${NODEODM_MAX_REMOTE_TASKS:-}\"; \
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
    echo "NodeODM PID: $NODEODM_PID (HTTP port: $NODEODM_PORT with token: ${_tapisJobOwner})"
}

# =============================================================================
# VERIFY NODEODM STARTUP
# =============================================================================
verify_nodeodm_startup() {
    if [[ "${NODEODM_SKIP_START:-0}" == "1" ]]; then
        echo "NODEODM_SKIP_START=1; skipping NodeODM startup verification"
        return 0
    fi
    
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

    # Test NodeODM connectivity with user ID token
    echo "Testing NodeODM connectivity with user ID authentication..."
    for i in {1..10}; do
        # Test HTTP connection with token
        echo "CURL TEST $i: curl -s 'http://localhost:$NODEODM_PORT/info?token=${_tapisJobOwner}'"
        NODEODM_INFO_TEST=$(curl -s "http://localhost:$NODEODM_PORT/info?token=$_tapisJobOwner" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$NODEODM_INFO_TEST" ]; then
            echo "NodeODM is responding with token authentication on port $NODEODM_PORT"
            break
        else
            echo "  Attempt $i/10: NodeODM not ready yet..."
            sleep 10
        fi
    done

    # Final connectivity test and info gathering (using HTTP with token)
    echo "CURL FINAL TEST: curl -s 'http://localhost:$NODEODM_PORT/info?token=${_tapisJobOwner}'"
    NODEODM_INFO=$(curl -s "http://localhost:$NODEODM_PORT/info?token=$_tapisJobOwner" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$NODEODM_INFO" ]; then
        echo "NodeODM connectivity confirmed"
        echo "NodeODM Info:"
        echo "$NODEODM_INFO"
        echo "$NODEODM_INFO" > $OUTPUT_DIR/nodeodm_info.json
        
        # Verify JSON response format
        if echo "$NODEODM_INFO" | grep -q '"version"'; then
            echo "NodeODM API responding correctly"
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
}