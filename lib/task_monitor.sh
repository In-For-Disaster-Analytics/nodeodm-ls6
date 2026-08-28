#!/bin/bash
#
# lib/task_monitor.sh - Task polling, status parsing, progress tracking, stream output
# Source FIFTH - needs NODEODM_URL from nodeodm_launch.sh, clusterodm.sh for registration
#

[[ -n "${_LIB_TASK_MONITOR_SH:-}" ]] && return 0
readonly _LIB_TASK_MONITOR_SH=1

# =============================================================================
# STREAM TASK OUTPUT
# =============================================================================
stream_task_output() {
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
            python3 <<'PY'
import json, sys

data = sys.stdin.read()
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
            <<< "$raw_output"
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
            echo "WARNING: Failed to write $OUTPUT_DIR/task_output.txt" >> "$LOG_FILE"
        fi
    else
        echo "WARNING: OUTPUT_DIR not set, skipping task_output.txt copy" >> "$LOG_FILE"
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

# =============================================================================
# PARSE TASK STATUS (uses stdin, not env var - fixes "Argument list too long")
# =============================================================================
parse_task_status() {
    local payload="$1"
    if command -v python3 >/dev/null 2>&1; then
        echo "$payload" | python3 -c '
import json
import sys

payload = sys.stdin.read()
code_map = {10: "QUEUED", 20: "RUNNING", 30: "FAILED", 40: "COMPLETED", 50: "CANCELED"}
status = None
resolved = ""
try:
    data = json.loads(payload)
    status = data.get("status")
    if isinstance(status, dict):
        resolved = code_map.get(int(status.get("code")), "")
    elif isinstance(status, int):
        resolved = code_map.get(status, "")
    elif isinstance(status, str):
        resolved = status
except Exception as exc:
    print(f"[parse_task_status] failed to parse payload: {exc}", file=sys.stderr)

print(f"[parse_task_status] raw status={status!r} resolved={resolved!r}", file=sys.stderr)
print(resolved)
'
    else
        local raw
        raw=$(echo "$payload" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        if [ -z "$raw" ]; then
            local code
            code=$(echo "$payload" | grep -o '"status":[0-9]*' | cut -d':' -f2)
            case "$code" in
                10) raw="QUEUED" ;;
                20) raw="RUNNING" ;;
                30) raw="FAILED" ;;
                40) raw="COMPLETED" ;;
                50) raw="CANCELED" ;;
            esac
        fi
        echo "[parse_task_status] raw status=$(echo "$payload" | grep -o '"status":[^,}]*') resolved='$raw'" >&2
        echo "$raw"
    fi
}

# =============================================================================
# PARSE TASK PROGRESS (uses stdin, not env var)
# =============================================================================
parse_task_progress() {
    local payload="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 <<'PY'
import json
import sys

try:
    data = json.loads(sys.stdin.read())
    progress = data.get("progress", 0)
    print(int(float(progress)))
except Exception:
    print("0")
PY
        <<< "$payload"
    else
        echo "$payload" | grep -o '"progress":[0-9]*' | cut -d':' -f2
    fi
}

# =============================================================================
# WAIT FOR TASK (inner loop polling /task/list)
# =============================================================================
wait_for_task() {
    while true; do
        echo "CURL TASK CHECK: curl -s 'http://localhost:$NODEODM_PORT/task/list?token=${TAP_TOKEN:0:10}...'"
        TASK_LIST_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/list?token=$TAP_TOKEN")

        if echo "$TASK_LIST_RESPONSE" | grep -q '"uuid"'; then
            # A node can pick up more than one task over its lifetime now, and a task it
            # already finished can still linger in this list, so scan every uuid for one
            # that's actually queued/running instead of assuming the first entry is it.
            for CANDIDATE_UUID in $(echo "$TASK_LIST_RESPONSE" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4); do
                echo "CURL TASK STATUS: curl -s 'http://localhost:$NODEODM_PORT/task/$CANDIDATE_UUID/info?token=${TAP_TOKEN:0:10}...'"
                CANDIDATE_STATUS_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/$CANDIDATE_UUID/info?token=$TAP_TOKEN")
                CANDIDATE_STATUS=$(parse_task_status "$CANDIDATE_STATUS_RESPONSE")
                if [ "$CANDIDATE_STATUS" = "QUEUED" ] || [ "$CANDIDATE_STATUS" = "RUNNING" ]; then
                    TASK_UUID="$CANDIDATE_UUID"
                    STATUS="$CANDIDATE_STATUS"
                    STATUS_RESPONSE="$CANDIDATE_STATUS_RESPONSE"
                    break
                fi
            done
        fi

        if [ -n "$TASK_UUID" ]; then
            echo "Found task: $TASK_UUID"
            TASK_OUTPUT_LINE=0
            echo "Task $TASK_UUID is processing, monitoring progress..."
            send_nodeodm_status_to_ptdatax "processing" "NodeODM started processing task $TASK_UUID"
            checkpoint_sync "task-start" "$TASK_UUID"
            mark_node_active
            break
        fi

        # Check timeout
        MONITORING_TIMEOUT=$((MONITORING_TIMEOUT + 30))
        if [ "$MONITORING_TIMEOUT" -gt "$MAX_MONITORING_TIME" ]; then
            if any_sibling_active; then
                echo "Local idle timeout reached, but a sibling node is still active - staying up in case more tasks are dispatched here"
                MONITORING_TIMEOUT=0
            else
                echo "Timeout waiting for tasks from ClusterODM"
                send_nodeodm_status_to_ptdatax "timeout" "NodeODM timed out waiting for tasks"
                mark_node_idle
                return 1
            fi
        fi

        echo "Waiting for task from ClusterODM... (${MONITORING_TIMEOUT}s elapsed)"
        sleep 30
    done
    return 0
}

# =============================================================================
# MONITOR TASK PROGRESS (inner loop polling /task/<uuid>/info)
# =============================================================================
monitor_task_progress() {
    while true; do
        echo "CURL PROGRESS CHECK: curl -s 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=${TAP_TOKEN:0:10}...'"
        STATUS_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=$TAP_TOKEN")
        STATUS=$(parse_task_status "$STATUS_RESPONSE")
        PROGRESS=$(parse_task_progress "$STATUS_RESPONSE")

        echo "Task status: $STATUS, Progress: ${PROGRESS:-0}%"
        stream_task_output
        maybe_checkpoint_sync
        mark_node_active

        case $STATUS in
            "COMPLETED")
                echo "Task completed successfully"
                send_nodeodm_status_to_ptdatax "complete" "NodeODM task $TASK_UUID completed successfully"
                checkpoint_sync "completed" "$TASK_UUID"
                return 0
                ;;
            "FAILED")
                echo "Task failed"
                echo "Error details:"
                echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4
                send_nodeodm_status_to_ptdatax "error" "NodeODM task $TASK_UUID failed: $(echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)"
                stream_task_output
                checkpoint_sync "failed" "$TASK_UUID"
                NODE_EXIT_STATUS=1
                return 1
                ;;
            "CANCELED")
                echo "Task was canceled"
                send_nodeodm_status_to_ptdatax "error" "NodeODM task $TASK_UUID was canceled"
                stream_task_output
                checkpoint_sync "canceled" "$TASK_UUID"
                NODE_EXIT_STATUS=1
                return 1
                ;;
            *)
                sleep 30
                ;;
        esac
    done
}

# =============================================================================
# MAIN TASK MONITORING LOOP
# =============================================================================
monitor_tasks() {
    echo "Monitoring for incoming tasks..."

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

    NODE_EXIT_STATUS=0
    while true; do
        TASK_UUID=""
        TASK_OUTPUT_LINE=0
        MONITORING_TIMEOUT=0

        # ---- Wait for a task to be assigned to this node ----
        wait_for_task || break

        # ---- Monitor task progress ----
        echo "Monitoring task progress for $TASK_UUID..."
        monitor_task_progress
        local task_result=$?

        stream_task_output

        if [ "$task_result" -eq 0 ]; then
            # Namespace downloads/report per task so a second task handled by this node
            # doesn't overwrite the first one's results.
            TASK_RESULT_DIR="$OUTPUT_DIR/$TASK_UUID"
            mkdir -p "$TASK_RESULT_DIR"

            echo "Downloading results..."
            echo "CURL DOWNLOAD: curl -s -o $TASK_RESULT_DIR/all.zip 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/all.zip?token=${TAP_TOKEN:0:10}...'"
            curl -s -o "$TASK_RESULT_DIR/all.zip" "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/all.zip?token=$TAP_TOKEN"
            echo "CURL DOWNLOAD: curl -s -o $TASK_RESULT_DIR/orthophoto.tif 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/orthophoto.tif?token=${TAP_TOKEN:0:10}...'"
            curl -s -o "$TASK_RESULT_DIR/orthophoto.tif" "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/orthophoto.tif?token=$TAP_TOKEN"
            echo "CURL DOWNLOAD: curl -s -o $TASK_RESULT_DIR/dsm.tif 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dsm.tif?token=${TAP_TOKEN:0:10}...'"
            curl -s -o "$TASK_RESULT_DIR/dsm.tif" "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dsm.tif?token=$TAP_TOKEN"
            echo "CURL DOWNLOAD: curl -s -o $TASK_RESULT_DIR/dtm.tif 'http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dtm.tif?token=${TAP_TOKEN:0:10}...'"
            curl -s -o "$TASK_RESULT_DIR/dtm.tif" "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dtm.tif?token=$TAP_TOKEN"

            # Generate processing report
            echo "NodeODM Processing Report" > "$TASK_RESULT_DIR/processing_report.txt"
            echo "========================" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Job Owner: ${_tapisJobOwner}" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Job UUID: ${_tapisJobUUID}" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Task UUID: $TASK_UUID" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Processing Time: $(date)" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Input Directory: $INPUT_DIR" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Output Directory: $TASK_RESULT_DIR" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Images Processed: $IMAGE_COUNT" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Max Concurrency: $MAX_CONCURRENCY" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Port: $NODEODM_PORT" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "External URL: ${EXTERNAL_URL}" >> "$TASK_RESULT_DIR/processing_report.txt"
            if [ -n "$LOGIN_PORT" ]; then
                echo "TAP Login Port: $LOGIN_PORT" >> "$TASK_RESULT_DIR/processing_report.txt"
            fi
            echo "" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "NodeODM Info:" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "$NODEODM_INFO" >> "$TASK_RESULT_DIR/processing_report.txt"

            # List output files
            echo "" >> "$TASK_RESULT_DIR/processing_report.txt"
            echo "Output Files:" >> "$TASK_RESULT_DIR/processing_report.txt"
            ls -la "$TASK_RESULT_DIR" >> "$TASK_RESULT_DIR/processing_report.txt"

            echo "NodeODM processing completed successfully!"
            echo "Results saved to: $TASK_RESULT_DIR"

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
            echo "Output directory: $TASK_RESULT_DIR"
            echo "========================================="
        fi

        mark_node_idle
        echo "Node ${NODEODM_CHILD_INDEX:-primary} is idle again; checking for more work..."
        # loop back to wait for another task
    done

    echo "Node ${NODEODM_CHILD_INDEX:-primary} found no more work and no active siblings; shutting down."
    # Wait for ClusterODM to signal that results have been transferred to WebODM. This is a
    # whole-node (not per-task) signal, so it only runs once, right before this node exits for good.
    wait_for_completion_signal

    exit $NODE_EXIT_STATUS
}