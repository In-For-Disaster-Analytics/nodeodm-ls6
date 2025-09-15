#!/bin/bash

# Debug script to test the registration with better debugging
# Set environment variables similar to what tapisjob_app.sh would set

export CLUSTER_HOST="clusterodm.tacc.utexas.edu"
export CLUSTER_PORT="443"
export NODE_HOST="ls6.tacc.utexas.edu"
export NODE_PORT="60785"
export REGISTRATION_UUID="test-uuid-$(date +%s)"

echo "=== Debug Registration Test ==="
echo "CLUSTER_HOST: $CLUSTER_HOST"
echo "CLUSTER_PORT: $CLUSTER_PORT"
echo "NODE_HOST: $NODE_HOST"
echo "NODE_PORT: $NODE_PORT"
echo "REGISTRATION_UUID: $REGISTRATION_UUID"
echo "TAPIS_TOKEN: $TAPIS_TOKEN"
echo ""

# Test with single retry and verbose output
./register-node.sh --retries 1 --retry-delay 5