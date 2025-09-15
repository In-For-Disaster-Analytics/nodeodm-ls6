#!/bin/bash

# Test script for infinite retry functionality
export CLUSTER_HOST="clusterodm.tacc.utexas.edu"
export CLUSTER_PORT="443"
export NODE_HOST="ls6.tacc.utexas.edu"
export NODE_PORT="99999"  # Use a different port to test retry
export REGISTRATION_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
export RETRY_DELAY="3"  # Shorter delay for testing

echo "=== Testing Infinite Retry Functionality ==="
echo "CLUSTER_HOST: $CLUSTER_HOST"
echo "CLUSTER_PORT: $CLUSTER_PORT"
echo "NODE_HOST: $NODE_HOST"
echo "NODE_PORT: $NODE_PORT"
echo "REGISTRATION_UUID: $REGISTRATION_UUID"
echo "RETRY_DELAY: $RETRY_DELAY seconds"
echo ""
echo "This will run forever until you press Ctrl+C"
echo ""

SKIP_VALIDATION=true ./register-node.sh --retries 1 --retry-delay 3