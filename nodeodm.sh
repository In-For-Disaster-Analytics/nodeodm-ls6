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

# Function to register NodeODM with ClusterODM
register_with_clusterodm() {
    echo "Registering NodeODM with ClusterODM..."

    # Check if register script is available
    if [ -f "./register-node.sh" ]; then
        # Set up environment for registration
        export CLUSTER_HOST="clusterodm.tacc.utexas.edu"
        export CLUSTER_PORT="443"
        export NODE_HOST="$NODE_HOSTNAME_DOMAIN"
        export NODE_PORT="$NODEODM_PORT"
        export TAPIS_TOKEN="slurm:${USER}:${SLURM_JOB_ID}"

        echo "Using webhook registration..."
        ./register-node.sh

        if [ $? -eq 0 ]; then
            echo "✅ Successfully registered NodeODM with ClusterODM"
            echo "🔗 Node accessible at: $HOSTNAME:$NODEODM_PORT"
        else
            echo "⚠️ Registration failed, manual registration may be needed"
            echo "📋 Add manually in ClusterODM admin: $HOSTNAME:$NODEODM_PORT"
        fi
    else
        echo "Registration script not available"
        echo "📋 Manual registration required:"
        echo "   - Access: https://clusterodm.tacc.utexas.edu/admin"
        echo "   - Add Node: $HOSTNAME:$NODEODM_PORT"
    fi
}

# Function to de-register NodeODM from ClusterODM
deregister_nodeodm() {
    echo "De-registering NodeODM from ClusterODM..."

    # Check if deregister script is available
    if [ -f "./deregister-node.sh" ]; then
        # Set up environment for de-registration
        export CLUSTER_HOST="clusterodm.tacc.utexas.edu"
        export CLUSTER_PORT="443"
        export NODE_HOST="$NODE_HOSTNAME_DOMAIN"
        export NODE_PORT="$NODEODM_PORT"
        export TAPIS_TOKEN="slurm:${USER}:${SLURM_JOB_ID}"

        echo "Using webhook de-registration..."
        ./deregister-node.sh

        if [ $? -eq 0 ]; then
            echo "✅ Successfully de-registered NodeODM from ClusterODM"
        else
            echo "⚠️ De-registration failed, but continuing cleanup"
        fi
    else
        echo "De-registration script not available, skipping"
    fi
}

# Global variable to control deregistration behavior
SHOULD_DEREGISTER_ON_EXIT=false

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    echo "Cleaning up processes (exit code: $exit_code)..."

    # Only deregister if explicitly requested or if there was an error after successful startup
    if [ "$SHOULD_DEREGISTER_ON_EXIT" = true ]; then
        echo "Deregistration requested - removing node from ClusterODM..."
        deregister_nodeodm
    elif [ $exit_code -ne 0 ] && [ -n "$NODEODM_PID" ] && [ "$NODEODM_READY" = true ]; then
        echo "NodeODM was running but exited with error - deregistering..."
        deregister_nodeodm
    else
        echo "Skipping deregistration (normal startup exit or NodeODM never fully started)"
        echo "  Exit code: $exit_code"
        echo "  NodeODM ready: ${NODEODM_READY:-false}"
        echo "  Should deregister: $SHOULD_DEREGISTER_ON_EXIT"
    fi

    # Clean up processes
    if [ -n "$NODEODM_PID" ] && ps -p $NODEODM_PID > /dev/null 2>&1; then
        echo "Stopping NodeODM process (PID: $NODEODM_PID)..."
        kill $NODEODM_PID 2>/dev/null || true
        sleep 5
        kill -9 $NODEODM_PID 2>/dev/null || true
    fi

    pkill -f "node.*index.js" 2>/dev/null || true
    pkill -f apptainer 2>/dev/null || true
    # Clean up SSH tunnels
    pkill -f "ssh.*login" 2>/dev/null || true
}

# Function to enable deregistration on cleanup
enable_deregistration_on_exit() {
    SHOULD_DEREGISTER_ON_EXIT=true
    echo "Deregistration on cleanup enabled"
}

# Trap cleanup on specific signals and EXIT - DISABLED FOR DEBUGGING
#trap cleanup EXIT
#trap 'echo "Received SIGINT - enabling deregistration and exiting..."; enable_deregistration_on_exit; exit 130' INT
#trap 'echo "Received SIGTERM - enabling deregistration and exiting..."; enable_deregistration_on_exit; exit 143' TERM

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

# Wait for NodeODM to start with longer initial delay
echo "Waiting for NodeODM to initialize..."
sleep 60  # Increased from 30 to 60 seconds

# Test NodeODM with more retries and better error handling
echo "Testing NodeODM connectivity..."
NODEODM_READY=false
for i in {1..20}; do  # Increased from 10 to 20 attempts
    echo "  Attempt $i/20: Testing NodeODM on port $NODEODM_PORT..."
    if curl -s --connect-timeout 10 --max-time 15 http://localhost:$NODEODM_PORT/info > /dev/null 2>&1; then
        echo "✓ NodeODM is responding on port $NODEODM_PORT"
        NODEODM_READY=true
        break
    else
        echo "  NodeODM not ready yet, waiting 15 seconds..."
        sleep 15  # Increased from 10 to 15 seconds
    fi
done

# Check if NodeODM startup failed
if [ "$NODEODM_READY" = false ]; then
    echo "⚠️ NodeODM connectivity check failed after 20 attempts"
    echo "Checking NodeODM process and logs..."
    if ps -p $NODEODM_PID > /dev/null 2>&1; then
        echo "NodeODM process is still running (PID: $NODEODM_PID)"
        echo "This may be a connectivity issue rather than a startup failure"
        echo "Proceeding with registration - ClusterODM will verify connectivity"
    else
        echo "ERROR: NodeODM process died during startup"
        echo "Check logs for details:"
        tail -20 $LOG_DIR/nodeodm.log
        exit 1
    fi
fi

# Get NodeODM info (only if connectivity check passed)
if [ "$NODEODM_READY" = true ]; then
    NODEODM_INFO=$(curl -s --connect-timeout 10 --max-time 15 http://localhost:$NODEODM_PORT/info 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$NODEODM_INFO" ]; then
        echo "NodeODM Info:"
        echo "$NODEODM_INFO"
    else
        echo "⚠️ Could not retrieve NodeODM info, but process is running"
    fi
else
    echo "⚠️ Skipping NodeODM info retrieval due to connectivity issues"
fi

# Always attempt registration - ClusterODM will validate connectivity
echo "Attempting ClusterODM registration..."
register_with_clusterodm

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

# Now that NodeODM is fully operational, enable deregistration on exit
# This prevents premature deregistration during startup issues
enable_deregistration_on_exit

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
