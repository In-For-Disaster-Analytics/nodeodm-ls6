#!/bin/bash
#SBATCH -J ODM-SingleNode-Multi_tap_       # Job name
#SBATCH -o ODM-Multi.o%j               # Name of stdout output file
#SBATCH -e ODM-Multi.e%j               # Name of stderr error file
#SBATCH -p vm-small                 # Queue (partition) name
#SBATCH -N 1                           # Single node
#SBATCH -n 1                           # One task
#SBATCH -t 02:00:00                    # Run time (hh:mm:ss)
#SBATCH -A PT2050-DataX                # Allocation name
#SBATCH --mail-user=wmobley@utexas.edu
#SBATCH --mail-type=all

# Usage: sbatch single-node-multi-nodeodm.sh /path/to/images/directory [project_name] [nodeodm_count]
# Example: sbatch single-node-multi-nodeodm.sh /scratch/06659/wmobley/images TestProject 4

# Check for required arguments
if [ $# -eq 0 ]; then
    echo "Usage: sbatch $0 <images_directory> [project_name] [nodeodm_count]"
    echo "Example: sbatch $0 /scratch/06659/wmobley/images TestProject 4"
    exit 1
fi

# Load required modules
module load tacc-apptainer
# Allow overriding the NodeODM image (default to our fork)
NODEODM_IMAGE=${NODEODM_IMAGE:-ghcr.io/ptdatax/nodeodm:latest}

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

function port_fowarding() {
	LOCAL_PORT=3000
	# Disable exit on error so we can check the ssh tunnel status.
	set +e
	for i in $(seq 2); do
		ssh -o StrictHostKeyChecking=no -q -f -g -N -R ${LOGIN_PORT}:${NODE_HOSTNAME_PREFIX}:${LOCAL_PORT} login${i}
	done
	if [ $(ps -fu ${USER} | grep ssh | grep login | grep -vc grep) != 2 ]; then
		# jupyter will not be working today. sadness.
		echo "TACC: ERROR - ssh tunnels failed to launch"
		echo "TACC: ERROR - this is often due to an issue with your ssh keys"
		echo "TACC: ERROR - undo any recent mods in ${HOME}/.ssh"
		echo "TACC: ERROR - or submit a TACC consulting ticket with this error"
		echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
		exit 1
	fi
	# Re-enable exit on error.
	set -e
    JUPYTER_URL="https://${NODE_HOSTNAME_DOMAIN}:${LOGIN_PORT}/"
    echo "TACC: Jupyter Notebook should be available at: ${JUPYTER_URL}"

}
# Parse command line arguments
IMAGES_DIR="$1"
PROJECT_NAME=${2:-"MultiNode_$(date +%Y%m%d_%H%M%S)"}
NODEODM_COUNT=${3:-4}  # Number of NodeODM instances to run on single node

# Set up variables
CLUSTER_PORT=3000
NODE_BASE_PORT=3001
LOGIN_PORT=$(shuf -i8000-9999 -n1)
WORK_DIR=$SCRATCH/multi_nodeodm_$SLURM_JOB_ID
LOG_DIR=$WORK_DIR/logs
OUTPUT_DIR=$WORK_DIR/output
USER=$(whoami)
CURRENT_NODE=$(hostname)

# Create working directories
mkdir -p $WORK_DIR
mkdir -p $LOG_DIR
mkdir -p $OUTPUT_DIR

echo "=== Multi-NodeODM Single Node Test Setup ==="
echo "Project: $PROJECT_NAME"
echo "Images Directory: $IMAGES_DIR"
echo "NodeODM Instances: $NODEODM_COUNT"
echo "Node: $CURRENT_NODE"
echo "Working Directory: $WORK_DIR"

cd $WORK_DIR

# Verify images directory
if [ ! -d "$IMAGES_DIR" ]; then
    echo "ERROR: Images directory not found: $IMAGES_DIR"
    exit 1
fi

IMAGE_COUNT=$(ls -1 "$IMAGES_DIR"/*.{jpg,jpeg,JPG,JPEG,tif,tiff,TIF,TIFF} 2>/dev/null | wc -l)
if [ $IMAGE_COUNT -eq 0 ]; then
    echo "ERROR: No image files found in $IMAGES_DIR"
    exit 1
fi

echo "Found $IMAGE_COUNT images to process"

# Cleanup function
cleanup() {
    echo "Cleaning up processes..."
    pkill -f 'node.*index.js' 2>/dev/null || true
    pkill -f apptainer 2>/dev/null || true
    
    # Kill specific NodeODM processes
    for ((i=1; i<=NODEODM_COUNT; i++)); do
        port=$((NODE_BASE_PORT + i - 1))
        pkill -f "port.*$port" 2>/dev/null || true
    done
    
    sleep 5
}
trap cleanup EXIT

# Function to start a NodeODM instance
start_nodeodm_instance() {
    local instance_id=$1
    local port=$2
    local max_concurrency=$3
    local max_parallel_tasks=$4
    
    local instance_dir="$WORK_DIR/nodeodm_instance_${instance_id}"
    mkdir -p $instance_dir/{data,tmp}
    chmod 777 $instance_dir/data
    chmod 777 $instance_dir/tmp
    
    # Create NodeODM config for this instance
    cat > $instance_dir/nodeodm-config.json << EOF
{
  "port": $port,
  "timeout": 0,
  "maxConcurrency": $max_concurrency,
  "maxImages": 0,
  "cleanupTasksAfter": 2880,
  "token": "",
  "parallelQueueProcessing": 1,
  "maxParallelTasks": $max_parallel_tasks,
  "odm_path": "/code",
  "logger": {
    "level": "info",
    "logDirectory": "/tmp/logs"
  }
}
EOF
    
    echo "Starting NodeODM instance $instance_id on port $port (concurrency: $max_concurrency, parallel: $max_parallel_tasks)"
    
    # Start NodeODM instance
    apptainer exec \
        --writable-tmpfs \
        --bind $instance_dir/nodeodm-config.json:/tmp/nodeodm-config.json \
        --bind $instance_dir/tmp:/var/www/tmp:rw \
        --bind $instance_dir/data:/var/www/data:rw \
        docker://$NODEODM_IMAGE \
        sh -c "cd /var/www && mkdir -p /tmp/logs && node index.js --config /tmp/nodeodm-config.json" > $LOG_DIR/nodeodm_instance_${instance_id}.log 2>&1 &
    
    local pid=$!
    echo "NodeODM instance $instance_id started with PID $pid on port $port"
    return $pid
}

# Calculate resource allocation per NodeODM instance
# Assume we have access to node specs - adjust based on Lonestar6 capabilities
TOTAL_CORES=$(nproc)
CORES_PER_NODEODM=$((TOTAL_CORES / NODEODM_COUNT))
if [ $CORES_PER_NODEODM -lt 1 ]; then
    CORES_PER_NODEODM=1
fi

echo "Total cores available: $TOTAL_CORES"
echo "Cores per NodeODM instance: $CORES_PER_NODEODM"

# Start multiple NodeODM instances
echo "=== Starting $NODEODM_COUNT NodeODM Instances ==="
nodeodm_pids=()
nodeodm_ports=()

for ((i=1; i<=NODEODM_COUNT; i++)); do
    port=$((NODE_BASE_PORT + i - 1))
    nodeodm_ports+=($port)
    
    # Adjust concurrency and parallel tasks based on available resources
    max_concurrency=$CORES_PER_NODEODM
    max_parallel_tasks=2
    
    # For testing, limit concurrency to avoid overwhelming single node
    if [ $max_concurrency -gt 4 ]; then
        max_concurrency=4
    fi
    
    start_nodeodm_instance $i $port $max_concurrency $max_parallel_tasks
    nodeodm_pids+=($!)
    
    sleep 3  # Stagger startup to avoid resource conflicts
done

# Wait for NodeODM instances to initialize
echo "Waiting for NodeODM instances to initialize..."
sleep 30

# Test NodeODM connectivity
echo "=== Testing NodeODM Instance Connectivity ==="
ready_instances=0
ready_ports=()

for ((i=1; i<=NODEODM_COUNT; i++)); do
    port=$((NODE_BASE_PORT + i - 1))
    echo -n "Testing NodeODM instance $i on port $port: "
    
    if timeout 15 curl -s "http://localhost:$port/info" >/dev/null 2>&1; then
        echo "Ready"
        ready_instances=$((ready_instances + 1))
        ready_ports+=($port)
        
        # Get instance info
        instance_info=$(curl -s "http://localhost:$port/info" 2>/dev/null || echo "No info available")
        echo "  Instance $i info: $instance_info" | head -c 200
    else
        echo "Not ready"
    fi
done

echo "Ready NodeODM instances: $ready_instances/$NODEODM_COUNT"

if [ $ready_instances -eq 0 ]; then
    echo "ERROR: No NodeODM instances are ready"
    exit 1
fi

# Set up ClusterODM
echo "=== Setting up ClusterODM ==="
mkdir -p clusterodm_workdir/data/images
mkdir -p clusterodm_workdir/tmp
chmod 777 clusterodm_workdir/data
chmod 777 clusterodm_workdir/tmp

# Copy ClusterODM files
echo "Copying ClusterODM files..."
apptainer exec docker://opendronemap/clusterodm:latest sh -c 'cd /var/www && tar -cf - .' | tar -xf - -C clusterodm_workdir/

# Create nodes.json with all ready NodeODM instances
echo "Creating nodes.json with $ready_instances NodeODM instances..."
echo '[' > clusterodm_workdir/data/nodes.json
first=true
for port in "${ready_ports[@]}"; do
    if [ "$first" = true ]; then
        first=false
    else
        echo ',' >> clusterodm_workdir/data/nodes.json
    fi
    echo "  {\"hostname\":\"localhost\", \"port\":\"$port\", \"token\":\"\"}" >> clusterodm_workdir/data/nodes.json
done
echo ']' >> clusterodm_workdir/data/nodes.json

# Create empty tasks file
echo '[]' > clusterodm_workdir/data/tasks.json
chmod 666 clusterodm_workdir/data/tasks.json

echo "ClusterODM node configuration:"
cat clusterodm_workdir/data/nodes.json

# Copy test images
if [ -d "$IMAGES_DIR" ]; then
    echo "Copying test images..."
    find "$IMAGES_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tif" -o -iname "*.tiff" \) | head -10 | xargs -I {} cp {} clusterodm_workdir/data/images/
    echo "Copied $(ls clusterodm_workdir/data/images/ | wc -l) test images"
fi

# Start ClusterODM
echo "Starting ClusterODM on port $CLUSTER_PORT..."
apptainer exec \
    --bind $PWD/clusterodm_workdir:/var/www \
    --bind $PWD/clusterodm_workdir/data:/var/www/data:rw \
    --bind $PWD/clusterodm_workdir/tmp:/var/www/tmp:rw \
    docker://opendronemap/clusterodm:latest \
    sh -c "cd /var/www && node index.js --port $CLUSTER_PORT --log-level info" > $LOG_DIR/clusterodm.log 2>&1 &

CLUSTERODM_PID=$!
echo "ClusterODM started with PID $CLUSTERODM_PID"

# Wait for ClusterODM to start
sleep 20

# Test ClusterODM
echo "=== Testing ClusterODM ==="
if timeout 15 curl -s "http://localhost:$CLUSTER_PORT/info" >/dev/null 2>&1; then
    echo "ClusterODM is responding on http://localhost:$CLUSTER_PORT"
    
    # Get cluster info
    cluster_info=$(curl -s "http://localhost:$CLUSTER_PORT/info" 2>/dev/null || echo "No info available")
    echo "ClusterODM info: $cluster_info"
else
    echo "ClusterODM may not be ready yet"
fi

# Check node connections
sleep 5
NODE_COUNT=$(curl -s "http://localhost:$CLUSTER_PORT/info" 2>/dev/null | grep -o '"totalNodes":[0-9]*' | cut -d':' -f2)
echo "Connected processing instances: $NODE_COUNT"

if [ -z "$NODE_COUNT" ] || [ "$NODE_COUNT" -eq 0 ]; then
    echo "Warning: No nodes connected. Adding manually..."
    for port in "${ready_ports[@]}"; do
        echo "Adding NodeODM instance on port $port..."
        curl -s -X POST "http://localhost:$CLUSTER_PORT/r/node/add" \
            -H 'Content-Type: application/json' \
            -d "{\"hostname\":\"localhost\",\"port\":$port,\"token\":\"\"}" || true
        sleep 2
    done
    sleep 10
fi
echo "Setup SSH tunnels for ODM access..."
load_tap_functions
get_tap_certificate
get_tap_token
port_fowarding

# Create status monitoring script
cat > $WORK_DIR/monitor_multi.sh << 'EOF'
#!/bin/bash
echo "=== Multi-NodeODM Cluster Status ==="
echo "ClusterODM Status:"
if curl -s "http://localhost:3000/info" >/dev/null 2>&1; then
    cluster_info=$(curl -s "http://localhost:3000/info" 2>/dev/null)
    echo "  Status: Running"
    echo "  Info: $cluster_info" | head -c 200
else
    echo "  Status: Not responding"
fi

echo -e "\nNodeODM Instances:"
for port in {3001..3010}; do
    if curl -s "http://localhost:$port/info" >/dev/null 2>&1; then
        echo "  Port $port: Running"
    fi
done

echo -e "\nProcess Status:"
echo "Active node processes:"
ps aux | grep -E "(node.*index\.js)" | grep -v grep | wc -l
echo "Container processes:"
ps aux | grep apptainer | grep -v grep | wc -l
EOF
chmod +x $WORK_DIR/monitor_multi.sh

# Create connection info
cat > $WORK_DIR/multi_nodeodm_info.txt << EOF
Multi-NodeODM Single Node Test Setup
====================================

Node: $CURRENT_NODE
Project: $PROJECT_NAME
Images: $IMAGE_COUNT files
NodeODM Instances: $ready_instances/$NODEODM_COUNT ready
ClusterODM Port: $CLUSTER_PORT

Access ClusterODM:
http://localhost:$CLUSTER_PORT

SSH Tunnel Command:
ssh -N -L 3000:$CURRENT_NODE:$CLUSTER_PORT $USER@ls6.tacc.utexas.edu

NodeODM Instances:
EOF

for ((i=0; i<${#ready_ports[@]}; i++)); do
    port=${ready_ports[$i]}
    echo "  Instance $((i+1)): http://localhost:$port" >> $WORK_DIR/multi_nodeodm_info.txt
done

echo "" >> $WORK_DIR/multi_nodeodm_info.txt
echo "Working Directory: $WORK_DIR" >> $WORK_DIR/multi_nodeodm_info.txt
echo "Monitor Script: ./monitor_multi.sh" >> $WORK_DIR/multi_nodeodm_info.txt

echo "========================================="
echo "Multi-NodeODM Cluster Started!"
echo "========================================="
cat $WORK_DIR/multi_nodeodm_info.txt

echo ""
echo "Use './monitor_multi.sh' to check status"
echo "Logs are in: $LOG_DIR/"

# Monitor cluster
echo "========================================="
echo "Monitoring cluster (Ctrl+C to stop)..."
echo "========================================="

monitor_count=0
while true; do
    sleep 60
    monitor_count=$((monitor_count + 1))
    
    if curl -s "http://localhost:$CLUSTER_PORT/info" >/dev/null 2>&1; then
        if [ $((monitor_count % 5)) -eq 0 ]; then  # Every 5 minutes, show detailed info
            echo "$(date): Cluster running - Detailed status:"
            ./monitor_multi.sh
        else
            echo "$(date): Cluster running - ClusterODM responsive"
        fi
    else
        echo "$(date): ClusterODM not responding"
        break
    fi
done

echo "Cluster monitoring complete"
