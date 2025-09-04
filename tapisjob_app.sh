#!/bin/bash

# NodeODM processing script for Tapis
# Based on the working nodeodm.sh configuration - using ZIP runtime to access TACC modules
# ZIP runtime means we run directly on compute node and can use module load tacc-apptainer

MAX_CONCURRENCY=${1:-4}
NODEODM_PORT=${2:-3001}
CLUSTERODM_URL=${3:-"http://localhost:3000"}  # ClusterODM endpoint URL

# Use Tapis environment variables for input/output directories  
INPUT_DIR="${_tapisExecSystemInputDir}"
OUTPUT_DIR="${_tapisExecSystemOutputDir}"

echo "=== NodeODM Tapis Processing (ZIP Runtime) ==="
echo "Processing started by: ${_tapisJobOwner}"
echo "Job UUID: ${_tapisJobUUID}"
echo "Input directory: $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "Max concurrency: $MAX_CONCURRENCY"
echo "Port: $NODEODM_PORT"

# Create output directory
mkdir -p $OUTPUT_DIR
LOG_DIR=$OUTPUT_DIR/logs
mkdir -p $LOG_DIR

# Load required modules (from working nodeodm.sh)
echo "Loading required modules..."
module load tacc-apptainer

echo "Working directory: $(pwd)"
echo "Environment:"
echo "  User: $(whoami)"
echo "  Hostname: $(hostname)"
echo "  SLURM_JOB_ID: ${SLURM_JOB_ID}"

# Validate input directory and count images
if [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory $INPUT_DIR not found!"
    exit 1
fi

IMAGE_COUNT=$(find $INPUT_DIR -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o -name "*.png" -o -name "*.PNG" -o -name "*.tif" -o -name "*.tiff" -o -name "*.TIF" -o -name "*.TIFF" | wc -l)
echo "Found $IMAGE_COUNT images in input directory"

if [ $IMAGE_COUNT -eq 0 ]; then
    echo "ERROR: No images found in input directory"
    exit 1
fi

# Set up working directory structure (same as nodeodm.sh)
WORK_DIR=$(pwd)/nodeodm_workdir
mkdir -p $WORK_DIR/data
mkdir -p $WORK_DIR/tmp
chmod 777 $WORK_DIR/data
chmod 777 $WORK_DIR/tmp

echo "Directory structure created:"
ls -la $WORK_DIR/

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
    LOGIN_PORT=$(tap_get_port)
    export TAP_TOKEN
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
	JUPYTER_URL="https://${NODE_HOSTNAME_DOMAIN}:${LOGIN_PORT}/?token=${TAP_TOKEN}"
	INTERACTIVE_WEBHOOK_URL="${_webhook_base_url}"
	# Wait a few seconds for jupyter to boot up and send webhook callback url for job ready notification.
	# Notification is sent to _INTERACTIVE_WEBHOOK_URL, e.g. https://3dem.org/webhooks/interactive/
	(
		sleep 5 &&
			curl -k --data "event_type=interactive_session_ready&address=${JUPYTER_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}" "${_INTERACTIVE_WEBHOOK_URL}" &
	) &

}

# Function to cleanup on exit
cleanup() {
    echo "Cleaning up processes..."

    
    # Kill specific PIDs if available
    if [ -n "$NODEODM_PID" ] && kill -0 $NODEODM_PID 2>/dev/null; then
        echo "Stopping NodeODM (PID: $NODEODM_PID)..."
        kill $NODEODM_PID 2>/dev/null || true
    fi
    # Fallback cleanup
    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f apptainer 2>/dev/null || true
    # Clean up SSH tunnels
    pkill -f "ssh.*login" 2>/dev/null || true
}
trap cleanup EXIT

# Set up TAP token first (needed for NodeODM authentication)
echo "Setting up TAP authentication..."
load_tap_functions
get_tap_certificate
get_tap_token
send_url_to_webhook


# Create NodeODM configuration file with TAP_TOKEN
echo "Creating NodeODM configuration..."
cat > $WORK_DIR/nodeodm-config.json << EOF
{
  "port": $NODEODM_PORT,
  "timeout": 0,
  "maxConcurrency": $MAX_CONCURRENCY,
  "maxImages": 0,
  "cleanupTasksAfter": 2880,
  "token": "$TAP_TOKEN",
  "parallelQueueProcessing": 1,
  "maxParallelTasks": 2,
  "odm_path": "/code",
  "logger": {
    "level": "debug",
    "logDirectory": "/tmp/logs"
  }
}
EOF

echo "NodeODM config created:"
cat $WORK_DIR/nodeodm-config.json

echo "Using HTTP with TAP_TOKEN authentication (no SSL proxy needed)"

# Start NodeODM with HTTP and TAP_TOKEN authentication
echo "Starting NodeODM with HTTP and TAP_TOKEN authentication..."
apptainer exec \
    --writable-tmpfs \
    --bind $WORK_DIR/nodeodm-config.json:/tmp/nodeodm-config.json \
    --bind $WORK_DIR/tmp:/var/www/tmp:rw \
    --bind $WORK_DIR/data:/var/www/data:rw \
    docker://opendronemap/nodeodm:latest \
    sh -c "cd /var/www && mkdir -p /tmp/logs && node index.js --config /tmp/nodeodm-config.json" > $LOG_DIR/nodeodm.log 2>&1 &

NODEODM_PID=$!
echo "NodeODM PID: $NODEODM_PID (HTTP port: $NODEODM_PORT with token: ${TAP_TOKEN:0:8}...)"

# Check if NodeODM process started
sleep 5
if ! kill -0 $NODEODM_PID 2>/dev/null; then
    echo "ERROR: NodeODM process died immediately"
    echo "Check startup logs:"
    cat $LOG_DIR/nodeodm.log
    exit 1
fi

# Wait for NodeODM to start
echo "Waiting for NodeODM to initialize..."
sleep 15

# Test NodeODM connectivity with TAP_TOKEN
echo "Testing NodeODM connectivity with TAP_TOKEN authentication..."
for i in {1..10}; do
    # Test HTTP connection with token
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
    if [ -f $LOG_DIR/nodeodm.log ]; then
        tail -50 $LOG_DIR/nodeodm.log
    else
        echo "  No log file found at $LOG_DIR/nodeodm.log"
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

# Function to notify ClusterODM that NodeODM is ready
function send_nodeodm_webhook() {
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_URL="$EXTERNAL_URL"
    else
        # Fallback to localhost for testing
        NODEODM_URL="http://localhost:$NODEODM_PORT?token=$TAP_TOKEN"
    fi
    
    # Check if webhook URL is configured
    if [ -n "${_webhook_base_url}" ]; then
        CLUSTERODM_WEBHOOK_URL="${_webhook_base_url}"
        echo "Sending NodeODM ready notification to ClusterODM webhook..."
        
        # Wait a few seconds for NodeODM to be fully ready, then send webhook
        (
            sleep 10 &&
            curl -k --data "event_type=nodeodm_ready&address=${NODEODM_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}&max_concurrency=${MAX_CONCURRENCY}&node_info=$(echo "$NODEODM_INFO" | tr -d '\n')" "${CLUSTERODM_WEBHOOK_URL}" &
        ) &
        
        echo "Webhook notification scheduled for: $NODEODM_URL"
        echo "Webhook endpoint: $CLUSTERODM_WEBHOOK_URL"
    else
        echo "No webhook URL configured (_webhook_base_url not set)"
        echo "NodeODM URL for manual registration: $NODEODM_URL"
    fi
}

# Send webhook notification after NodeODM is confirmed working
send_nodeodm_webhook

# Create a processing task
echo "Creating processing task..."
TASK_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: multipart/form-data" \
    -F "name=tapis_job_${_tapisJobUUID}" \
    "http://localhost:$NODEODM_PORT/task/new?token=$TAP_TOKEN")

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create task"
    exit 1
fi

# Extract task UUID
echo "$TASK_RESPONSE"
TASK_UUID=$(echo "$TASK_RESPONSE" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4)
echo "Created task with UUID: $TASK_UUID"

# Upload images to the task
echo "Uploading images to task..."
cd $INPUT_DIR
for image in $(find . -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o -name "*.png" -o -name "*.PNG" -o -name "*.tif" -o -name "*.tiff" -o -name "*.TIF" -o -name "*.TIFF"); do
    echo "Uploading: $image"
    curl -s -X POST \
        -F "images=@$image" \
        "http://localhost:$NODEODM_PORT/task/$TASK_UUID/upload?token=$TAP_TOKEN"
done

# Start processing
echo "Starting task processing..."
curl -s -X POST "http://localhost:$NODEODM_PORT/task/$TASK_UUID/start?token=$TAP_TOKEN"

# Monitor task progress
echo "Monitoring task progress..."
while true; do
    STATUS_RESPONSE=$(curl -s "http://localhost:$NODEODM_PORT/task/$TASK_UUID/info?token=$TAP_TOKEN")
    STATUS=$(echo "$STATUS_RESPONSE" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    PROGRESS=$(echo "$STATUS_RESPONSE" | grep -o '"progress":[0-9]*' | cut -d':' -f2)
    
    echo "Task status: $STATUS, Progress: ${PROGRESS:-0}%"
    
    case $STATUS in
        "COMPLETED")
            echo "✓ Task completed successfully"
            break
            ;;
        "FAILED")
            echo "✗ Task failed"
            echo "Error details:"
            echo "$STATUS_RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4
            exit 1
            ;;
        "CANCELED")
            echo "✗ Task was canceled"
            exit 1
            ;;
        *)
            sleep 30
            ;;
    esac
done

# Download results
echo "Downloading results..."
curl -s -o $OUTPUT_DIR/all.zip "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/all.zip?token=$TAP_TOKEN"
curl -s -o $OUTPUT_DIR/orthophoto.tif "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/orthophoto.tif?token=$TAP_TOKEN"
curl -s -o $OUTPUT_DIR/dsm.tif "http://localhost:$NODEODM_PORT/task/$TASK_UUID/download/dsm.tif?token=$TAP_TOKEN"
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