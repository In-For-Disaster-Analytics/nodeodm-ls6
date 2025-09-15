#!/bin/bash

# Debug script to test the registration with proper UUID format
# Generate a proper UUID for testing

# Generate a proper UUID (format: 8-4-4-4-12 hex characters)
PROPER_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

export CLUSTER_HOST="clusterodm.tacc.utexas.edu"
export CLUSTER_PORT="443"
export NODE_HOST="ls6.tacc.utexas.edu"
export NODE_PORT="60785"
export REGISTRATION_UUID="$PROPER_UUID"

echo "=== Debug Registration Test with Proper UUID ==="
echo "CLUSTER_HOST: $CLUSTER_HOST"
echo "CLUSTER_PORT: $CLUSTER_PORT"
echo "NODE_HOST: $NODE_HOST"
echo "NODE_PORT: $NODE_PORT"
echo "REGISTRATION_UUID: $REGISTRATION_UUID"
echo "TAPIS_TOKEN: $TAPIS_TOKEN"
echo ""

# Test with single retry and verbose output, skip validation
SKIP_VALIDATION=true ./register-node.sh --retries 1 --retry-delay 5