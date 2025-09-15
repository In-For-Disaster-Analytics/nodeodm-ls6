#!/bin/bash

# Test script for local ClusterODM-Tapis webhook registration
export CLUSTER_HOST="localhost"
export CLUSTER_PORT="10000"
export NODE_HOST="ls6.tacc.utexas.edu"
export NODE_PORT="60785"
export REGISTRATION_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

echo "=== Testing Local ClusterODM-Tapis Registration ==="
echo "CLUSTER_HOST: $CLUSTER_HOST"
echo "CLUSTER_PORT: $CLUSTER_PORT"
echo "NODE_HOST: $NODE_HOST"
echo "NODE_PORT: $NODE_PORT"
echo "REGISTRATION_UUID: $REGISTRATION_UUID"
echo ""

# Test with HTTP since localhost:10000 doesn't use HTTPS
sed 's/https:\/\//http:\/\//g' register-node.sh > register-node-http.sh
chmod +x register-node-http.sh

SKIP_VALIDATION=true ./register-node-http.sh --retries 1 --retry-delay 2