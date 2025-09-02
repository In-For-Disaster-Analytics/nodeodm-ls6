#!/bin/bash
#SBATCH -J ODM-Production              # Job name
#SBATCH -o ODM-Prod.o%j               # Name of stdout output file
#SBATCH -e ODM-Prod.e%j               # Name of stderr error file
#SBATCH -p development                # Queue (partition) name
#SBATCH -N 2                          # Total # of nodes
#SBATCH -n 2                          # Total # of tasks
#SBATCH --ntasks-per-node=1           # One task per node
#SBATCH -t 02:00:00                   # Run time (hh:mm:ss)
#SBATCH -A PT2050-DataX               # Allocation name
#SBATCH --mail-user=wmobley@utexas.edu
#SBATCH --mail-type=all

# Usage: sbatch cluster-improved.sh /path/to/images/directory [project_name] [batch_size]

# Check for required arguments
if [ $# -eq 0 ]; then
    echo "Usage: sbatch $0 <images_directory> [project_name] [batch_size]"
    echo "Example: sbatch $0 /scratch/06659/wmobley/images Bethel_Ortho 50"
    exit 1
fi

# Load required modules
module load tacc-apptainer

# Parse command line arguments
IMAGES_DIR="$1"
if [ $# -ge 2 ]; then
    PROJECT_NAME="$2"
else
    PROJECT_NAME=$(basename $(dirname "$IMAGES_DIR"))_$(basename "$IMAGES_DIR")_$(date +%Y%m%d_%H%M)
fi
BATCH_SIZE=${3:-50}

# Set up variables (matching your working script)
CLUSTER_PORT=3000
NODE_BASE_PORT=3001
LOGIN_PORT=$(shuf -i8000-9999 -n1)
WORK_DIR=$SCRATCH/odm_cluster_$SLURM_JOB_ID
LOG_DIR=$WORK_DIR/logs
OUTPUT_DIR=$WORK_DIR/output
USER=$(whoami)

# Create working directories
mkdir -p $WORK_DIR
mkdir -p $LOG_DIR  
mkdir -p $OUTPUT_DIR

echo "=== ODM Cluster Production Setup ==="
echo "Project: $PROJECT_NAME"
echo "Images Directory: $IMAGES_DIR"
echo "Batch Size: $BATCH_SIZE images per task"
echo "Working Directory: $WORK_DIR"

cd $WORK_DIR

# Verify images directory (from your working script)
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

# Get node allocation
NODELIST=($(scontrol show hostname $SLURM_NODELIST))
CLUSTER_NODE=${NODELIST[0]}
PROCESSING_NODES=(${NODELIST[@]:1})

echo "Cluster node: $CLUSTER_NODE"
echo "Processing nodes: ${PROCESSING_NODES[@]}"

# Cleanup function (from your working script)
cleanup() {
    echo "Cleaning up processes..."
    for node in "${NODELIST[@]}"; do
        srun -N1 --nodelist=$node bash -c "pkill -f 'node.*index.js' 2>/dev/null || true" &
        srun -N1 --nodelist=$node bash -c "pkill -f apptainer 2>/dev/null || true" &
    done
    wait
}
trap cleanup EXIT

# Port forwarding function (from your working script)
function port_forwarding() {
    local node=$1
    local port=$2
    local login_port=$3
    
    set +e
    echo "Setting up reverse SSH tunnels for $node:$port -> login nodes:$login_port..."
    for i in $(seq 2); do
        srun -N1 --nodelist=$node bash -c "ssh -o StrictHostKeyChecking=no -q -f -g -N -R ${login_port}:${node}:${port} login${i}" &
        sleep 2
    done
    set -e
}

# Start NodeODM instances (improved version of your approach)
echo "=== Setting up NodeODM instances ==="
for i in "${!PROCESSING_NODES[@]}"; do
    node=${PROCESSING_NODES[$i]}
    port=$((NODE_BASE_PORT + i))
    
    echo "Starting NodeODM on $node:$port..."
    srun -N1 --nodelist=$node bash -c "
        cd $WORK_DIR
        mkdir -p nodeodm_workdir_$node/data
        mkdir -p nodeodm_workdir_$node/tmp
        chmod 777 nodeodm_workdir_$node/data
        chmod 777 nodeodm_workdir_$node/tmp
        
        # Create NodeODM config
        cat > nodeodm_workdir_$node/nodeodm-config.json << EOF
{
  \\\"port\\\": $port,
  \\\"timeout\\\": 0,
  \\\"maxConcurrency\\\": 2,
  \\\"maxImages\\\": 0,
  \\\"cleanupTasksAfter\\\": 2880,
  \\\"token\\\": \\\"\\\",
  \\\"parallelQueueProcessing\\\": 1,
  \\\"maxParallelTasks\\\": 3,
  \\\"odm_path\\\": \\\"/code\\\",
  \\\"logger\\\": {
    \\\"level\\\": \\\"info\\\",
    \\\"logDirectory\\\": \\\"/tmp/logs\\\"
  }
}
EOF
        
        # Start NodeODM
        apptainer exec \\
            --writable-tmpfs \\
            --bind \\$PWD/nodeodm_workdir_$node/nodeodm-config.json:/tmp/nodeodm-config.json \\
            --bind \\$PWD/nodeodm_workdir_$node/tmp:/var/www/tmp:rw \\
            --bind \\$PWD/nodeodm_workdir_$node/data:/var/www/data:rw \\
            docker://opendronemap/nodeodm:latest \\
            sh -c 'cd /var/www && mkdir -p /tmp/logs && node index.js --config /tmp/nodeodm-config.json' > $LOG_DIR/nodeodm_$node.log 2>&1 &
        
        echo 'NodeODM started on $node:$port'
    " &
done

# Wait for NodeODM instances to start
echo "Waiting for NodeODM instances to initialize..."
sleep 30

# Verify NodeODM instances (from your working script)
echo "Verifying NodeODM instances..."
for i in "${!PROCESSING_NODES[@]}"; do
    node=${PROCESSING_NODES[$i]}
    port=$((NODE_BASE_PORT + i))
    
    if srun -N1 --nodelist=$node bash -c "curl -s http://localhost:$port/info > /dev/null 2>&1"; then
        echo "✓ NodeODM on $node:$port is ready"
    else
        echo "✗ NodeODM on $node:$port failed to start"
        exit 1
    fi
done

# Set up ClusterODM (improved version)
echo "=== Setting up ClusterODM ==="

# Create the nodes.json content (from your working script)
NODES_JSON="["
for i in "${!PROCESSING_NODES[@]}"; do
    node=${PROCESSING_NODES[$i]}
    port=$((NODE_BASE_PORT + i))
    if [ $i -gt 0 ]; then
        NODES_JSON="${NODES_JSON},"
    fi
    NODES_JSON="${NODES_JSON}{\\\"hostname\\\":\\\"${node}\\\", \\\"port\\\":\\\"${port}\\\", \\\"token\\\":\\\"\\\"}"
done
NODES_JSON="${NODES_JSON}]"

srun -N1 --nodelist=$CLUSTER_NODE bash -c "
    cd $WORK_DIR
    mkdir -p clusterodm_workdir/data/images
    mkdir -p clusterodm_workdir/tmp
    chmod 777 clusterodm_workdir/data
    chmod 777 clusterodm_workdir/tmp
    
    # Copy ClusterODM files
    echo 'Copying ClusterODM files...'
    apptainer exec docker://opendronemap/clusterodm:latest sh -c 'cd /var/www && tar -cf - .' | tar -xf - -C clusterodm_workdir/
    
    # Create nodes configuration
    echo 'Creating nodes.json with processing nodes...'
    echo '$NODES_JSON' > clusterodm_workdir/data/nodes.json
    
    # Create empty tasks file
    echo '[]' > clusterodm_workdir/data/tasks.json
    chmod 666 clusterodm_workdir/data/tasks.json
    
    echo 'Pre-configured nodes:'
    cat clusterodm_workdir/data/nodes.json
    
    # Start ClusterODM
    echo 'Starting ClusterODM...'
    apptainer exec \\
        --bind \\$PWD/clusterodm_workdir:/var/www \\
        --bind \\$PWD/clusterodm_workdir/data:/var/www/data:rw \\
        --bind \\$PWD/clusterodm_workdir/tmp:/var/www/tmp:rw \\
        docker://opendronemap/clusterodm:latest \\
        sh -c 'cd /var/www && node index.js --port $CLUSTER_PORT --log-level info' > $LOG_DIR/clusterodm.log 2>&1 &
        
    echo 'ClusterODM started'
" &

# Wait for ClusterODM to start
echo "Waiting for ClusterODM to initialize..."
sleep 30

# Verify ClusterODM (from your working script)
if srun -N1 --nodelist=$CLUSTER_NODE bash -c "curl -s http://localhost:$CLUSTER_PORT/info > /dev/null 2>&1"; then
    echo "✓ ClusterODM is ready"
else
    echo "✗ ClusterODM failed to start"
    exit 1
fi

# Check node connections (from your working script)
NODE_COUNT=$(srun -N1 --nodelist=$CLUSTER_NODE bash -c "
    curl -s http://localhost:$CLUSTER_PORT/info 2>/dev/null | grep -o '\\\"totalNodes\\\":[0-9]*' | cut -d':' -f2
")
echo "Connected processing nodes: $NODE_COUNT"

if [ "$NODE_COUNT" -eq 0 ]; then
    echo "Warning: No nodes connected. Adding manually..."
    for i in "${!PROCESSING_NODES[@]}"; do
        node=${PROCESSING_NODES[$i]}
        port=$((NODE_BASE_PORT + i))
        
        srun -N1 --nodelist=$CLUSTER_NODE bash -c "
            curl -s -X POST http://localhost:$CLUSTER_PORT/api/node/add \\
                -H 'Content-Type: application/json' \\
                -d '{\\\"hostname\\\":\\\"$node\\\",\\\"port\\\":$port,\\\"token\\\":\\\"\\\"}' || true
        "
    done
    sleep 10
fi

# Set up external access (from your working script)
port_forwarding $CLUSTER_NODE $CLUSTER_PORT $LOGIN_PORT

# Generate access URLs (from your working script)
ODM_URL="https://ls6.tacc.utexas.edu:${LOGIN_PORT}"

echo "========================================="
echo "ODM Cluster Started Successfully!"
echo "========================================="
echo "Project: $PROJECT_NAME"
echo "Images: $IMAGE_COUNT files"
echo "Processing nodes: $NODE_COUNT"
echo "Access URL: $ODM_URL"
echo ""
echo "SSH Tunnel Access:"
echo "ssh -N -L 3000:$CLUSTER_NODE:$CLUSTER_PORT $USER@ls6.tacc.utexas.edu"
echo "Then: http://localhost:3000"
echo ""

# Save connection info (from your working script)
cat > $WORK_DIR/connection_info.txt << EOF
ODM Cluster Access Information
==============================

Main Interface: $ODM_URL

SSH Tunnel Commands:
ssh -N -L 3000:$CLUSTER_NODE:$CLUSTER_PORT $USER@ls6.tacc.utexas.edu

Project: $PROJECT_NAME
Images: $IMAGE_COUNT files
Batch Size: $BATCH_SIZE images per task
Connected Nodes: $NODE_COUNT
Cluster Node: $CLUSTER_NODE
Processing Nodes: ${PROCESSING_NODES[*]}
Working Directory: $WORK_DIR

Output Directory: $OUTPUT_DIR
EOF

echo "Connection info saved to: $WORK_DIR/connection_info.txt"

# Monitor cluster (simplified from your working script)
echo "========================================="
echo "Monitoring cluster (Ctrl+C to stop)..."
echo "Access web interface: $ODM_URL"
echo "========================================="

while true; do
    sleep 300
    
    if srun -N1 --nodelist=$CLUSTER_NODE bash -c "curl -s http://localhost:$CLUSTER_PORT/info > /dev/null 2>&1"; then
        echo "$(date): Cluster running - Access: $ODM_URL"
    else
        echo "$(date): ClusterODM not responding"
        break
    fi
done

echo "Cluster monitoring complete"
