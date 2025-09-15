#!/bin/bash

# ClusterODM Node De-Registration Shell Script
# This script automatically de-registers a compute node from the ClusterODM cluster.

# Import the main registration script and set deregister mode
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEREGISTER=true

# Source the main script which now handles both registration and de-registration
source "${SCRIPT_DIR}/register-node.sh"