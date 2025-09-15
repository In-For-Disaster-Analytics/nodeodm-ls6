#!/bin/bash

# ClusterODM Node Auto-Registration Shell Script
# This script is designed to be run on HPC compute nodes to automatically
# register with the ClusterODM cluster without requiring telnet access.

set -e

# Default configuration
CLUSTER_HOST="${CLUSTER_HOST:-localhost}"
CLUSTER_PORT="${CLUSTER_PORT:-10000}"
NODE_HOST="${NODE_HOST:-$(hostname -I | awk '{print $1}')}"
NODE_PORT="${NODE_PORT:-3000}"
NODE_TOKEN="${NODE_TOKEN:-}"
REGISTRATION_SECRET="${REGISTRATION_SECRET:-}"
REGISTRATION_UUID="${REGISTRATION_UUID:-}"
TAPIS_TOKEN="${TAPIS_TOKEN:-}"
NODE_ID="${NODE_ID:-}"
RETRIES="${RETRIES:-5}"
RETRY_DELAY="${RETRY_DELAY:-10}"
DEREGISTER=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_info() {
    print_status "$BLUE" "ℹ️  $1"
}

print_success() {
    print_status "$GREEN" "✅ $1"
}

print_warning() {
    print_status "$YELLOW" "⚠️  $1"
}

print_error() {
    print_status "$RED" "❌ $1"
}

# Function to show help
show_help() {
    cat << EOF
ClusterODM Node Auto-Registration Script

This script automatically registers a compute node with a ClusterODM cluster
using the webhook API, eliminating the need for manual telnet registration.

Usage: $0 [options]

Options:
    --cluster-host <host>         ClusterODM hostname (default: localhost)
    --cluster-port <port>         ClusterODM admin web port (default: 10000)
    --node-host <host>            This node's hostname (default: auto-detect)
    --node-port <port>            This node's port (default: 3000)
    --node-token <token>          NodeODM authentication token (default: none)
    --registration-secret <secret> Shared secret for registration (default: none)
    --registration-uuid <uuid>    Job UUID for authentication (default: none)
    --tapis-token <token>         Tapis JWT token for authentication (default: none)
    --node-id <id>                Node ID for de-registration (default: none)
    --retries <number>            Number of retry attempts (default: 5)
    --retry-delay <seconds>       Delay between retries in seconds (default: 10)
    --deregister                  De-register node instead of registering
    --help, -h                    Show this help message

Environment Variables:
    CLUSTER_HOST                  ClusterODM hostname
    CLUSTER_PORT                  ClusterODM admin web port
    NODE_HOST                     This node's hostname
    NODE_PORT                     This node's port
    NODE_TOKEN                    NodeODM authentication token
    REGISTRATION_SECRET           Shared secret for registration
    REGISTRATION_UUID             Job UUID for authentication (preferred)
    TAPIS_TOKEN                   Tapis JWT token for authentication (fallback)
    NODE_ID                       Node ID for de-registration
    RETRIES                       Number of retry attempts
    RETRY_DELAY                   Delay between retries in seconds

Examples:
    # Basic registration with auto-detected IP
    $0 --cluster-host clusterodm.example.com

    # Registration with Tapis JWT token (recommended for Tapis deployments)
    $0 \\
        --cluster-host clusterodm.example.com \\
        --cluster-port 10000 \\
        --node-host 192.168.1.100 \\
        --node-port 3000 \\
        --tapis-token "eyJ0eXAiOiJKV1QiOiJhbGciOiJSUzI1NiJ9..."

    # Registration with traditional secret
    $0 \\
        --cluster-host clusterodm.example.com \\
        --registration-secret mySecretKey

    # Using environment variables (Tapis)
    export CLUSTER_HOST=clusterodm.example.com
    export NODE_HOST=192.168.1.100
    export TAPIS_TOKEN="eyJ0eXAiOiJKV1QiOiJhbGciOiJSUzI1NiJ9..."
    $0

    # Using environment variables (traditional)
    export CLUSTER_HOST=clusterodm.example.com
    export NODE_HOST=192.168.1.100
    export REGISTRATION_SECRET=mySecretKey
    $0

HPC Integration:
    # Add to SLURM job script after starting NodeODM
    srun nodeodm &
    sleep 10  # Wait for NodeODM to start
    $0 --cluster-host head-node.cluster.edu

    # Or with a wrapper in your job script (Tapis)
    export CLUSTER_HOST=\$SLURM_SUBMIT_HOST
    export NODE_HOST=\$(hostname -I | awk '{print \$1}')
    export TAPIS_TOKEN=\$TAPIS_JWT_TOKEN
    $0

    # Or with traditional secret
    export CLUSTER_HOST=\$SLURM_SUBMIT_HOST
    export NODE_HOST=\$(hostname -I | awk '{print \$1}')
    export REGISTRATION_SECRET="your-shared-secret"
    $0

EOF
}

# Function to parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-host)
                CLUSTER_HOST="$2"
                shift 2
                ;;
            --cluster-port)
                CLUSTER_PORT="$2"
                shift 2
                ;;
            --node-host)
                NODE_HOST="$2"
                shift 2
                ;;
            --node-port)
                NODE_PORT="$2"
                shift 2
                ;;
            --node-token)
                NODE_TOKEN="$2"
                shift 2
                ;;
            --registration-secret)
                REGISTRATION_SECRET="$2"
                shift 2
                ;;
            --registration-uuid)
                REGISTRATION_UUID="$2"
                shift 2
                ;;
            --tapis-token)
                TAPIS_TOKEN="$2"
                shift 2
                ;;
            --node-id)
                NODE_ID="$2"
                shift 2
                ;;
            --deregister)
                DEREGISTER=true
                shift
                ;;
            --retries)
                RETRIES="$2"
                shift 2
                ;;
            --retry-delay)
                RETRY_DELAY="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Function to auto-detect local IP if not set
detect_node_host() {
    if [[ "$NODE_HOST" == "" ]]; then
        # Try different methods to get the IP address
        if command -v hostname >/dev/null 2>&1; then
            NODE_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
        fi

        if [[ "$NODE_HOST" == "" ]]; then
            NODE_HOST=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
        fi

        if [[ "$NODE_HOST" == "" ]]; then
            NODE_HOST="localhost"
            print_warning "Could not auto-detect IP address, using localhost"
        fi
    fi
}

# Function to de-register the node using curl
deregister_node() {
    local url="https://${CLUSTER_HOST}:${CLUSTER_PORT}/webhook/deregister-node"

    # Build JSON payload
    local payload='{'
    payload+='"hostname":"'$NODE_HOST'",'
    payload+='"port":'$NODE_PORT

    # Add node ID if provided (most reliable identification)
    if [[ -n "$NODE_ID" ]]; then
        payload+=',"nodeId":'$NODE_ID
    fi

    # Add authentication - prefer UUID, then Tapis token, fallback to registration secret
    if [[ -n "$REGISTRATION_UUID" ]]; then
        payload+=',"registrationUuid":"'$REGISTRATION_UUID'"'
    elif [[ -n "$TAPIS_TOKEN" ]]; then
        payload+=',"tapisToken":"'$TAPIS_TOKEN'"'
    elif [[ -n "$REGISTRATION_SECRET" ]]; then
        payload+=',"registrationSecret":"'$REGISTRATION_SECRET'"'
    fi

    payload+='}'

    print_info "Attempting to de-register node $NODE_HOST:$NODE_PORT from cluster at $CLUSTER_HOST:$CLUSTER_PORT"

    for ((attempt=1; attempt<=RETRIES; attempt++)); do
        print_info "De-registration attempt $attempt/$RETRIES..."

        # Use curl to make the de-registration request
        local response
        local http_code

        response=$(curl -s -w "%{http_code}" \
                       -X POST \
                       -H "Content-Type: application/json" \
                       -d "$payload" \
                       --connect-timeout 30 \
                       --max-time 60 \
                       "$url" 2>/dev/null)

        http_code="${response: -3}"
        response="${response%???}"


        if [[ "$http_code" == "200" ]]; then
            local success=$(echo "$response" | grep -o '"success"[[:space:]]*:[[:space:]]*true' || echo "")
            if [[ -n "$success" ]]; then
                local node_info=$(echo "$response" | sed -n 's/.*"nodeInfo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                local message=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                print_success "Successfully de-registered! Node: $node_info"
                if [[ -n "$message" ]]; then
                    print_info "Message: $message"
                fi
                return 0
            else
                local error=$(echo "$response" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                print_warning "De-registration failed: $error"
            fi
        elif [[ "$http_code" == "404" ]]; then
            print_warning "Node not found in cluster (may already be removed)"
            print_info "Considering this successful since node is not registered."
            return 0
        elif [[ "$http_code" == "401" ]]; then
            print_error "Authentication failed (HTTP 401). Check your authentication credentials."
            return 1
        elif [[ "$http_code" == "000" ]]; then
            print_error "Cannot connect to ClusterODM at $CLUSTER_HOST:$CLUSTER_PORT"
            print_info "Make sure ClusterODM is running and accessible."
        else
            print_error "De-registration failed (HTTP $http_code): $response"
        fi

        if [[ $attempt -lt $RETRIES ]]; then
            print_info "Retrying in $RETRY_DELAY seconds..."
            sleep "$RETRY_DELAY"
        fi
    done

    print_error "Failed to de-register after $RETRIES attempts"
    return 1
}

# Function to register the node using curl
register_node() {
    local url="https://${CLUSTER_HOST}:${CLUSTER_PORT}/webhook/register-node"

    # Build JSON payload
    local payload='{'
    payload+='"hostname":"'$NODE_HOST'",'
    payload+='"port":'$NODE_PORT

    if [[ -n "$NODE_TOKEN" ]]; then
        payload+=',"token":"'$NODE_TOKEN'"'
    fi

    # Add authentication - prefer UUID, then Tapis token, fallback to registration secret
    if [[ -n "$REGISTRATION_UUID" ]]; then
        payload+=',"registrationUuid":"'$REGISTRATION_UUID'"'
    elif [[ -n "$TAPIS_TOKEN" ]]; then
        payload+=',"tapisToken":"'$TAPIS_TOKEN'"'
    elif [[ -n "$REGISTRATION_SECRET" ]]; then
        payload+=',"registrationSecret":"'$REGISTRATION_SECRET'"'
    fi

    payload+='}'

    print_info "Attempting to register node $NODE_HOST:$NODE_PORT with cluster at $CLUSTER_HOST:$CLUSTER_PORT"
    print_info "Will retry indefinitely every $RETRY_DELAY seconds until successful or manually canceled (Ctrl+C)"

    local attempt=1
    while true; do
        print_info "Registration attempt $attempt (infinite retry - Ctrl+C to cancel)..."

        # Use curl to make the registration request
        local response
        local http_code

        response=$(curl -s -w "%{http_code}" \
                       -X POST \
                       -H "Content-Type: application/json" \
                       -d "$payload" \
                       --connect-timeout 30 \
                       --max-time 60 \
                       "$url" 2>/dev/null)

        http_code="${response: -3}"
        response="${response%???}"


        if [[ "$http_code" == "200" ]]; then
            local success=$(echo "$response" | grep -o '"success"[[:space:]]*:[[:space:]]*true' || echo "")
            if [[ -n "$success" ]]; then
                local node_id=$(echo "$response" | sed -n 's/.*"nodeId"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
                local message=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                print_success "Successfully registered! Node ID: $node_id"
                if [[ -n "$message" ]]; then
                    print_info "Message: $message"
                fi
                return 0
            else
                local error=$(echo "$response" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                print_warning "Registration failed: $error"
                if [[ "$error" == *"already exists"* ]]; then
                    print_info "Node is already registered, considering this successful."
                    return 0
                fi
            fi
        elif [[ "$http_code" == "401" ]]; then
            print_error "Authentication failed (HTTP 401). Check your registration secret."
            return 1
        elif [[ "$http_code" == "000" ]]; then
            print_error "Cannot connect to ClusterODM at $CLUSTER_HOST:$CLUSTER_PORT"
            print_info "Make sure ClusterODM is running and accessible."
        else
            print_error "Registration failed (HTTP $http_code): $response"
        fi

        print_info "Retrying in $RETRY_DELAY seconds..."
        sleep "$RETRY_DELAY"
        ((attempt++))
    done

    # This will never be reached due to infinite loop
    print_error "Registration loop ended unexpectedly"
    return 1
}

# Function to validate that NodeODM is running
validate_nodeodm() {
    # Use local validation if requested (for Tapis jobs where external URL isn't reachable from inside)
    local test_host="$NODE_HOST"
    local test_port="$NODE_PORT"

    if [[ "$VALIDATE_LOCALLY" == "true" ]] && [[ -n "$LOCAL_NODE_HOST" ]] && [[ -n "$LOCAL_NODE_PORT" ]]; then
        print_info "Using local validation - checking NodeODM on $LOCAL_NODE_HOST:$LOCAL_NODE_PORT..."
        test_host="$LOCAL_NODE_HOST"
        test_port="$LOCAL_NODE_PORT"
        print_info "Will register externally as: $NODE_HOST:$NODE_PORT"
    else
        print_info "Checking if NodeODM is running on $NODE_HOST:$NODE_PORT..."
    fi

    local response
    local test_url="http://$test_host:$test_port/info"

    # Add token if available for local validation
    if [[ "$VALIDATE_LOCALLY" == "true" ]] && [[ -n "$LOCAL_NODE_TOKEN" ]]; then
        test_url="http://$test_host:$test_port/info?token=$LOCAL_NODE_TOKEN"
    fi

    response=$(curl -s --connect-timeout 10 --max-time 10 \
                   "$test_url" 2>/dev/null || echo "")

    if [[ -n "$response" ]] && echo "$response" | grep -q '"version"'; then
        local version=$(echo "$response" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        print_success "NodeODM is running (version $version)"
        return 0
    else
        print_warning "Cannot reach NodeODM at $test_host:$test_port"
        print_info "Proceeding anyway, ClusterODM will verify connectivity."
        return 1
    fi
}

# Function to check dependencies
check_dependencies() {
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl is required but not installed."
        print_info "Please install curl and try again."
        exit 1
    fi
}

# Main function
main() {
    local title="ClusterODM Node Auto-Registration Script"
    if [[ "$DEREGISTER" == "true" ]]; then
        title="ClusterODM Node De-Registration Script"
    fi

    print_info "$title"
    echo "========================================"

    # Check dependencies
    check_dependencies

    # Parse command line arguments
    parse_args "$@"

    # Validate required parameters
    if [[ -z "$CLUSTER_HOST" ]]; then
        print_error "--cluster-host is required"
        echo "Use --help for usage information"
        exit 1
    fi

    # Auto-detect node host if not provided
    detect_node_host

    # Display configuration
    echo "Cluster: $CLUSTER_HOST:$CLUSTER_PORT"
    echo "Node: $NODE_HOST:$NODE_PORT"
    if [[ "$DEREGISTER" == "true" && -n "$NODE_ID" ]]; then
        echo "Node ID: $NODE_ID"
    fi
    echo "Token: $([ -n "$NODE_TOKEN" ] && echo "***set***" || echo "none")"
    echo "Auth: $([ -n "$REGISTRATION_UUID" ] && echo "UUID" || [ -n "$TAPIS_TOKEN" ] && echo "Tapis JWT" || [ -n "$REGISTRATION_SECRET" ] && echo "Secret" || echo "none")"
    echo ""

    if [[ "$DEREGISTER" == "true" ]]; then
        # Attempt de-registration
        if deregister_node; then
            print_success "Node de-registration completed successfully!"
            exit 0
        else
            print_error "Node de-registration failed!"
            exit 1
        fi
    else
        # Optional: Check if NodeODM is running locally for registration
        if [[ "$SKIP_VALIDATION" != "true" ]]; then
            validate_nodeodm
        else
            print_info "Validation skipped - assuming NodeODM is running"
        fi

        # Attempt registration
        if register_node; then
            print_success "Node registration completed successfully!"
            exit 0
        else
            print_error "Node registration failed!"
            exit 1
        fi
    fi
}

# Handle script termination gracefully
trap 'print_warning "Registration cancelled by user"; exit 1' INT TERM

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi