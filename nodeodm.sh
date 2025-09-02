#!/bin/bash
#SBATCH -J nodeodm-hpc                     # Job name
#SBATCH -N 1                               # Single node
#SBATCH -n 1                               # Single task
#SBATCH --ntasks-per-node=1                # One task per node
#SBATCH -p vm-small                          # Queue (partition)
#SBATCH -t 2:00:00                         # Wall clock time limit (8 hours)
#SBATCH -A PT2050-DataX                    # Allocation name
#SBATCH -o nodeodm_%j.out                  # Standard output
#SBATCH -e nodeodm_%j.err                  # Standard error
#SBATCH --mail-type=ALL                    # Mail events
#SBATCH --mail-user=wmobley@tacc.utexas.edu # Email address

# Check for required command line argument
if [ $# -eq 0 ]; then
    echo "Usage: sbatch $0 <max_concurrency> [port]"
    echo "Example: sbatch $0 4 3001"
    echo "max_concurrency: Number of concurrent processing tasks (default: 4)"
    echo "port: NodeODM port (default: 3001)"
    exit 1
fi

# Parse command line arguments
MAX_CONCURRENCY=${1:-4}
NODEODM_PORT=${2:-3001}

# Load required modules
module load tacc-apptainer

# Set up variables
WORK_DIR=$SCRATCH/nodeodm_$SLURM_JOB_ID
LOG_DIR=$WORK_DIR/logs
USER=$(whoami)
HOSTNAME=$(hostname -s)
NODE_HOSTNAME_PREFIX=$HOSTNAME
NODE_HOSTNAME_DOMAIN="ls6.tacc.utexas.edu"
LOGIN_PORT=$(shuf -i8000-9999 -n1)

# Create working directories
mkdir -p $WORK_DIR
mkdir -p $LOG_DIR
cd $WORK_DIR

echo "=== NodeODM HPC Setup ==="
echo "Max Concurrency: $MAX_CONCURRENCY"
echo "Port: $NODEODM_PORT"
echo "Working Directory: $WORK_DIR"
echo "Hostname: $HOSTNAME"

# Create NodeODM working directories
mkdir -p nodeodm_workdir/data
mkdir -p nodeodm_workdir/tmp
chmod 777 nodeodm_workdir/data
chmod 777 nodeodm_workdir/tmp

echo "Directory structure created:"
ls -la nodeodm_workdir/

# Function to setup reverse SSH tunneling for external access
function port_forwarding() {
    local node=$1
    local local_port=$2
    local login_port=$3
    
    # Disable exit on error so we can check ssh tunnel status
    set +e
    
    echo "Setting up reverse SSH tunnels for $node:$local_port -> login nodes:$login_port..."
    
    for i in $(seq 2); do
        ssh -o StrictHostKeyChecking=no -q -f -g -N -R ${login_port}:${node}:${local_port} login${i} &
        sleep 2
    done
    
    # Check if tunnels were established successfully
    sleep 5
    if [ $(ps -fu ${USER} | grep ssh | grep login | grep -vc grep) != 2 ]; then
        echo "TACC: ERROR - SSH tunnels failed to launch"
        echo "TACC: ERROR - This is often due to an issue with your ssh keys"
        echo "TACC: ERROR - Undo any recent mods in ${HOME}/.ssh"
        echo "TACC: ERROR - Or submit a TACC consulting ticket with this error"
        echo "TACC: Job ${SLURM_JOB_ID} execution finished at: $(date)"
        return 1
    fi
    
    echo "✓ SSH tunnels established successfully"
    # Re-enable exit on error
    set -e
    return 0
}

# Function to cleanup on exit
cleanup() {
    echo "Cleaning up processes..."
    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f apptainer 2>/dev/null || true
    # Clean up SSH tunnels
    pkill -f "ssh.*login" 2>/dev/null || true
}
trap cleanup EXIT

# Start NodeODM with the proven working configuration
echo "Starting NodeODM with proven working setup..."
apptainer exec \
    --writable-tmpfs \
    --bind $WORK_DIR/nodeodm_workdir/tmp:/var/www/tmp:rw \
    --bind $WORK_DIR/nodeodm_workdir/data:/var/www/data:rw \
    docker://opendronemap/nodeodm:latest \
    sh -c "cd /var/www && node index.js --port $NODEODM_PORT --max-concurrency $MAX_CONCURRENCY --cleanup-tasks-after 2880" > $LOG_DIR/nodeodm.log 2>&1 &

NODEODM_PID=$!
echo "NodeODM PID: $NODEODM_PID"

# Wait for NodeODM to start
echo "Waiting for NodeODM to initialize..."
sleep 30

# Test NodeODM
echo "Testing NodeODM connectivity..."
for i in {1..10}; do
    if curl -s http://localhost:$NODEODM_PORT/info > /dev/null 2>&1; then
        echo "✓ NodeODM is responding on port $NODEODM_PORT"
        break
    else
        echo "  Attempt $i/10: NodeODM not ready yet..."
        sleep 10
    fi
done

# Get NodeODM info
NODEODM_INFO=$(curl -s http://localhost:$NODEODM_PORT/info 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "NodeODM Info:"
    echo "$NODEODM_INFO"
else
    echo "ERROR: NodeODM failed to start properly"
    echo "Check logs:"
    tail -20 $LOG_DIR/nodeodm.log
    exit 1
fi

# Set up external access via reverse SSH tunneling
echo "Setting up external web access..."
if port_forwarding $HOSTNAME $NODEODM_PORT $LOGIN_PORT; then
    # Generate access URLs
    NODEODM_URL="https://${NODE_HOSTNAME_DOMAIN}:${LOGIN_PORT}"
    
    echo ""
    echo "========================================="
    echo "NodeODM Ready with Web Access!"
    echo "========================================="
    echo "NodeODM is running on: $HOSTNAME:$NODEODM_PORT"
    echo "External Access URL: $NODEODM_URL"
    echo "Job ID: $SLURM_JOB_ID"
    echo "Working Directory: $WORK_DIR"
    echo ""
    echo "Connection Options:"
    echo ""
    echo "Option 1 - Direct Web Access:"
    echo "   URL: $NODEODM_URL"
    echo "   Test: $NODEODM_URL/info"
    echo ""
    echo "Option 2 - SSH Tunnel (for local WebODM):"
    echo "   ssh -N -L $NODEODM_PORT:$HOSTNAME:$NODEODM_PORT $USER@ls6.tacc.utexas.edu"
    echo "   Then add to WebODM: localhost:$NODEODM_PORT"
    echo ""
else
    echo "WARNING: Reverse SSH tunneling failed"
    echo "Using SSH tunnel method only:"
    echo "ssh -N -L $NODEODM_PORT:$HOSTNAME:$NODEODM_PORT $USER@ls6.tacc.utexas.edu"
    NODEODM_URL="localhost:$NODEODM_PORT (via SSH tunnel)"
fi
echo "NodeODM Capabilities:"
echo "- Max Concurrency: $MAX_CONCURRENCY"
echo "- Cleanup after: 2880 minutes (48 hours)"
echo "- Data Directory: $WORK_DIR/nodeodm_workdir/data"
echo "- Temp Directory: $WORK_DIR/nodeodm_workdir/tmp"
echo ""

# Save connection info
cat > $WORK_DIR/connection_info.txt << EOF
NodeODM Connection Information
==============================

External Web Access:
${NODEODM_URL:-"Not available - use SSH tunnel"}

SSH Tunnel Command:
ssh -N -L $NODEODM_PORT:$HOSTNAME:$NODEODM_PORT $USER@ls6.tacc.utexas.edu

Local WebODM Processing Node Settings:
- Hostname: localhost
- Port: $NODEODM_PORT  
- Label: TACC-$HOSTNAME-$SLURM_JOB_ID
- Token: (leave empty)

Direct Access (from TACC):
- URL: http://$HOSTNAME:$NODEODM_PORT
- Info: http://$HOSTNAME:$NODEODM_PORT/info

Job Details:
- Job ID: $SLURM_JOB_ID
- Hostname: $HOSTNAME
- Login Port: $LOGIN_PORT
- Working Directory: $WORK_DIR
- Max Concurrency: $MAX_CONCURRENCY
- Log File: $LOG_DIR/nodeodm.log

Usage Instructions:
1. Access via web URL (if reverse SSH worked) OR set up SSH tunnel
2. Add processing node in local WebODM
3. Submit tasks from local WebODM interface

To check status:
- squeue -u $USER
- curl ${NODEODM_URL:-"http://$HOSTNAME:$NODEODM_PORT"}/info
EOF

echo "Connection info saved to: $WORK_DIR/connection_info.txt"

# Monitor NodeODM and keep job alive
echo "========================================="
echo "Monitoring NodeODM (Ctrl+C to stop)..."
echo "Access connection info: $WORK_DIR/connection_info.txt"
echo "========================================="

# Simple monitoring loop
while true; do
    sleep 300  # Check every 5 minutes
    
    if curl -s http://localhost:$NODEODM_PORT/info > /dev/null 2>&1; then
        # Get task count
        TASK_COUNT=$(curl -s http://localhost:$NODEODM_PORT/task/list 2>/dev/null | grep -o '"uuid"' | wc -l || echo "0")
        echo "$(date): NodeODM running - Active tasks: $TASK_COUNT"
    else
        echo "$(date): NodeODM not responding, checking logs..."
        tail -5 $LOG_DIR/nodeodm.log
        echo "Attempting to restart NodeODM..."
        
        # Kill existing process
        pkill -f "node.*index.js" 2>/dev/null || true
        sleep 5
        
        # Restart NodeODM
        apptainer exec \
            --writable-tmpfs \
            --bind $WORK_DIR/nodeodm_workdir/tmp:/var/www/tmp:rw \
            --bind $WORK_DIR/nodeodm_workdir/data:/var/www/data:rw \
            docker://opendronemap/nodeodm:latest \
            sh -c "cd /var/www && node index.js --port $NODEODM_PORT --max-concurrency $MAX_CONCURRENCY --cleanup-tasks-after 2880" >> $LOG_DIR/nodeodm.log 2>&1 &
        
        sleep 30
    fi
done

echo "NodeODM monitoring complete"
