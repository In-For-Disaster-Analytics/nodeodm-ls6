#!/bin/bash
#
# lib/clusterodm.sh - Register, deregister, webhook notifications
# Source FOURTH - needs NODEODM_URL from nodeodm_launch.sh
#

[[ -n "${_LIB_CLUSTERODM_SH:-}" ]] && return 0
readonly _LIB_CLUSTERODM_SH=1

# =============================================================================
# NOTIFY CLUSTERODM COMPLETE (LEGACY)
# =============================================================================
notify_clusterodm_complete() {
    echo "Notifying ClusterODM that job is complete..."

    # Get node information for removal
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_HOST=$(echo "$EXTERNAL_URL" | sed 's|http[s]*://||' | cut -d: -f1)
        NODEODM_REGISTER_PORT=$(echo "$EXTERNAL_URL" | sed 's|.*:||' | cut -d? -f1 | sed 's|/||g')
    else
        NODEODM_HOST=$(hostname)
        NODEODM_REGISTER_PORT=$NODEODM_PORT
    fi

    # Try to notify ClusterODM via HTTP API about job completion
    if curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/info" > /dev/null 2>&1; then
        echo "Notifying ClusterODM via HTTP API..."

        # Try to get current nodes list to find our node ID
        NODES_INFO=$(curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/nodes" 2>/dev/null || echo "")

        # Send completion notification webhook
        COMPLETION_DATA="hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&job_uuid=${_tapisJobUUID}&status=complete"
        curl -k -s --connect-timeout 10 -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "$COMPLETION_DATA" \
            "$CLUSTERODM_URL/admin/job_complete" >/dev/null 2>&1 || echo "Job completion notification sent"

        # Optionally try to remove/lock the node if it won't be used again
        # This depends on whether you want the node to remain available for other jobs
        # REMOVAL_DATA="hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&action=remove_node"
        # curl -k -s --connect-timeout 10 -X POST \
        #     -H "Content-Type: application/x-www-form-urlencoded" \
        #     -d "$REMOVAL_DATA" \
        #     "$CLUSTERODM_URL/admin/nodes" >/dev/null 2>&1 || echo "Node removal attempted"

        echo "ClusterODM notified of job completion via HTTP"
    else
        echo "WARNING: Could not reach ClusterODM for completion notification"
    fi

    # Also send completion webhook if configured
    if [ -n "${_webhook_base_url}" ]; then
        curl -k --data "event_type=nodeodm_complete&hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&job_uuid=${_tapisJobUUID}&owner=${_tapisJobOwner}&clusterodm_url=$CLUSTERODM_URL" "${_webhook_base_url}/clusterodm" 2>/dev/null || echo "Completion webhook sent"
        echo "Sent completion notification to webhook"
    fi
}

# =============================================================================
# DEREGISTER FROM CLUSTERODM
# =============================================================================
deregister_from_clusterodm() {
    echo "De-registering NodeODM from ClusterODM..."

    # Get node information for de-registration
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_HOST=$(echo "$EXTERNAL_URL" | sed 's|http[s]*://||' | cut -d: -f1)
        NODEODM_REGISTER_PORT=$(echo "$EXTERNAL_URL" | sed 's|.*:||' | cut -d? -f1 | sed 's|/||g')
    else
        NODEODM_HOST=$(hostname)
        NODEODM_REGISTER_PORT=$NODEODM_PORT
    fi

    # Use webhook de-registration if script is available
    if [ -f "./deregister-node.sh" ]; then
        echo "Using webhook de-registration with Tapis JWT token..."

        # Extract ClusterODM hostname from URL
        CLUSTERODM_HOST=$(echo "$CLUSTERODM_URL" | sed 's|https\?://||' | cut -d/ -f1)

        # Set up environment variables for de-registration
        export CLUSTER_HOST="$CLUSTERODM_HOST"
        export CLUSTER_PORT="443"
        export NODE_HOST="$NODEODM_HOST"
        export NODE_PORT="$NODEODM_REGISTER_PORT"
        export NODE_TOKEN="$TAP_TOKEN"

        # Use the same UUID as registration
        export REGISTRATION_UUID="${_tapisJobUUID%-*}"
        # Clear any JWT tokens to force UUID-based auth
        unset TAPIS_TOKEN

        # Add node ID if we have it
        if [ -n "$REGISTERED_NODE_ID" ]; then
            export NODE_ID="$REGISTERED_NODE_ID"
        fi

        # Use the webhook de-registration script
        ./deregister-node.sh

        if [ $? -eq 0 ]; then
            echo "Successfully de-registered NodeODM from ClusterODM via webhook!"
        else
            echo "WARNING: Webhook de-registration failed, but continuing cleanup..."
        fi
    else
        echo "Webhook de-registration script not found, using legacy approach..."
        # Legacy de-registration notification
        notify_clusterodm_complete
    fi

    # Also send legacy completion notification if configured
    if [ -n "${_webhook_base_url}" ]; then
        curl -k --data "event_type=nodeodm_deregistration&hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&job_uuid=${_tapisJobUUID}&owner=${_tapisJobOwner}&clusterodm_url=$CLUSTERODM_URL" "${_webhook_base_url}/clusterodm" 2>/dev/null || echo "Legacy de-registration webhook sent"
    fi

    echo "NodeODM de-registration process completed"
}

# =============================================================================
# REGISTER WITH CLUSTERODM (WEBHOOK API)
# =============================================================================
register_with_clusterodm() {
    echo "[REGISTER] Starting registration flow (role=$NODEODM_ROLE child=${NODEODM_CHILD_INDEX:-primary} host=$(hostname) port=$NODEODM_PORT)"
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        # Extract hostname from external URL for ClusterODM registration
        NODEODM_HOST=$(echo "$EXTERNAL_URL" | sed 's|http[s]*://||' | cut -d: -f1)
        NODEODM_REGISTER_PORT=$(echo "$EXTERNAL_URL" | sed 's|.*:||' | cut -d? -f1 | sed 's|/||g')
    else
        # Use compute node hostname for direct registration
        NODEODM_HOST=$(hostname)
        NODEODM_REGISTER_PORT=$NODEODM_PORT
    fi

    echo "Attempting to register NodeODM with ClusterODM using webhook API..."
    echo "NodeODM Host: $NODEODM_HOST"
    echo "NodeODM Port: $NODEODM_REGISTER_PORT"
    echo "ClusterODM URL: $CLUSTERODM_URL"

    # Use direct curl command for webhook registration
    echo "Using webhook registration with Tapis JWT token..."

    # Prepare registration data
    REGISTRATION_UUID="${_tapisJobUUID%-*}"  # Remove any suffix like -007

    echo "Registration details:"
    echo "  UUID: $REGISTRATION_UUID"
    echo "  Host: $NODEODM_HOST"
    echo "  Port: $NODEODM_REGISTER_PORT"
    echo "  Token: ${TAP_TOKEN:0:10}..."
    echo "  Child index: ${NODEODM_CHILD_INDEX:-primary}"
    echo "  Role: ${NODEODM_ROLE:-admin}"
    echo "  Host ID: ${NODEODM_HOST_ID:-0}"
    echo "  Worker ID: ${NODEODM_WORKER_ID:-0}"
    echo "  Job index/count: ${NODEODM_JOB_INDEX:-1}/${NODEODM_JOB_COUNT:-1}"
    echo "  Replicas per job: ${NODEODM_REPLICAS_PER_JOB:-1}"

    # Direct curl registration call with job UUID mapping
    echo "Sending registration request to: $CLUSTERODM_URL/webhook/register-node"
    echo "Debug: CLUSTERODM_URL='$CLUSTERODM_URL'"
    echo "Debug: Full URL='$CLUSTERODM_URL/webhook/register-node'"

    # Prepare JSON payload with Tapis job owner for user-based authentication
    RESUME_JSON_FIELDS=""
    if [ -n "${NODEODM_RESUME_TASK_UUID:-}" ]; then
        RESUME_JSON_FIELDS=", \"checkpointResume\": true, \"resumeTaskUuid\": \"${NODEODM_RESUME_TASK_UUID}\", \"resumeMode\": \"${NODEODM_RESUME_MODE:-unknown}\", \"resumeFallbackReason\": \"${NODEODM_RESUME_FALLBACK_REASON:-}\""
    fi
    JSON_PAYLOAD="{\"hostname\": \"$NODEODM_HOST\", \"port\": $NODEODM_REGISTER_PORT, \"token\": \"$TAP_TOKEN\", \"uuid\": \"$REGISTRATION_UUID\", \"tapisJobUuid\": \"${_tapisJobUUID}\", \"tapisJobOwner\": \"${_tapisJobOwner}\", \"nodeReady\": true, \"childIndex\": \"${NODEODM_CHILD_INDEX:-primary}\", \"role\": \"${NODEODM_ROLE:-admin}\", \"hostId\": \"${NODEODM_HOST_ID:-0}\", \"workerId\": \"${NODEODM_WORKER_ID:-0}\", \"jobIndex\": \"${NODEODM_JOB_INDEX:-1}\", \"jobCount\": \"${NODEODM_JOB_COUNT:-1}\", \"replicasPerJob\": \"${NODEODM_REPLICAS_PER_JOB:-1}\"${RESUME_JSON_FIELDS}}"
    echo "Debug: JSON payload='$JSON_PAYLOAD'"

    # Show the exact curl command for manual testing
    echo ""
    echo "Manual registration command:"
    echo "curl -X POST '$CLUSTERODM_URL/webhook/register-node' \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -H 'Authorization: Bearer \${TAPIS_ACCESS_TOKEN}' \\"
    echo "  -d '$JSON_PAYLOAD'"
    echo ""

    # Check authentication options - prefer user ID over JWT token
    if [ -n "${TAPIS_ACCESS_TOKEN}" ] && [ "${TAPIS_ACCESS_TOKEN}" != "" ]; then
        echo "Using TAPIS_ACCESS_TOKEN for authentication"
        AUTH_METHOD="jwt-token"
        EFFECTIVE_TOKEN="${TAPIS_ACCESS_TOKEN}"
    elif [ -n "${_tapisJobOwner}" ]; then
        echo "Using Tapis Job Owner for authentication: ${_tapisJobOwner}"
        AUTH_METHOD="user-id"
        EFFECTIVE_TOKEN=""
    else
        echo "WARNING: Neither _tapisJobOwner nor TAPIS_ACCESS_TOKEN is available"
        echo "Available Tapis environment variables:"
        env | grep -E "^_tapis" | sort || echo "No _tapis* variables found"
        echo ""
        echo "Using user ID authentication as fallback..."
        AUTH_METHOD="user-id"
        EFFECTIVE_TOKEN=""
    fi

    # Show the actual curl command being executed
    echo "EXECUTING CURL COMMAND ($AUTH_METHOD authentication):"
    echo "curl -s -w 'HTTP_CODE:%{http_code}' -X POST '$CLUSTERODM_URL/webhook/register-node' \\"
    echo "  -H 'Content-Type: application/json' \\"
    if [ -n "$EFFECTIVE_TOKEN" ]; then
        echo "  -H 'Authorization: Bearer ${EFFECTIVE_TOKEN:0:20}...' \\"  # Show first 20 chars of token
    else
        echo "  (No Authorization header - using user ID in payload)"
    fi
    echo "  -d '$JSON_PAYLOAD'"
    echo ""

    # Execute curl with or without Authorization header based on auth method
    if [ -n "$EFFECTIVE_TOKEN" ]; then
        REGISTRATION_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$CLUSTERODM_URL/webhook/register-node" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${EFFECTIVE_TOKEN}" \
            -d "$JSON_PAYLOAD")
    else
        REGISTRATION_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$CLUSTERODM_URL/webhook/register-node" \
            -H "Content-Type: application/json" \
            -d "$JSON_PAYLOAD")
    fi

    CURL_EXIT_CODE=$?

    if [ $CURL_EXIT_CODE -ne 0 ]; then
        echo "Curl command failed with exit code: $CURL_EXIT_CODE"
        echo "Registration response: $REGISTRATION_RESPONSE"
        echo "   This may indicate network issues or ClusterODM is unreachable"
        return 7
    fi

    # Extract HTTP code and response body
    HTTP_CODE=$(echo "$REGISTRATION_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    RESPONSE_BODY=$(echo "$REGISTRATION_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')

    echo "HTTP Code: $HTTP_CODE"
    echo "Response: $RESPONSE_BODY"

    if echo "$RESPONSE_BODY" | grep -q '"success":true'; then
        echo "Successfully registered NodeODM with ClusterODM via webhook!"
        # Extract node ID from response if available
        NODE_ID=$(echo "$RESPONSE_BODY" | grep -o '"nodeId":[0-9]*' | cut -d: -f2)
        if [ -n "$NODE_ID" ]; then
            export REGISTERED_NODE_ID="$NODE_ID"
            echo "Node registration ID: $REGISTERED_NODE_ID"
        fi
    else
        echo "Webhook registration failed (HTTP: $HTTP_CODE)"
        echo "Response: $RESPONSE_BODY"
        echo "   Manual registration may be needed: $CLUSTERODM_URL/admin"

        if [ "$HTTP_CODE" = "401" ]; then
            echo "   Authentication failed - check UUID or token"
        elif [ "$HTTP_CODE" = "500" ]; then
            echo "   Server error - check ClusterODM logs"
        fi
    fi

    # Legacy webhook notification for backward compatibility
    if [ -n "${_webhook_base_url}" ]; then
        echo "Sending additional webhook notifications..."
        curl -k --data "event_type=nodeodm_registration&hostname=$NODEODM_HOST&port=$NODEODM_REGISTER_PORT&clusterodm_url=$CLUSTERODM_URL&external_url=${EXTERNAL_URL:-N/A}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}" "${_webhook_base_url}/clusterodm" 2>/dev/null || echo "Legacy webhook notification sent"
    fi

    echo "NodeODM registration process completed"
    echo "Manual verification:"
    echo "   - Check ClusterODM admin: $CLUSTERODM_URL/admin"
    echo "   - Node should appear as: $NODEODM_HOST:$NODEODM_REGISTER_PORT"
}

# =============================================================================
# SEND NODEODM WEBHOOK (LEGACY)
# =============================================================================
send_nodeodm_webhook() {
    if [ -n "$EXTERNAL_URL" ] && [ "$EXTERNAL_URL" != "N/A - use SSH tunnel" ] && [ "$EXTERNAL_URL" != "N/A - not on TACC" ]; then
        NODEODM_URL="$EXTERNAL_URL"
    else
        # Fallback to localhost for testing
        NODEODM_URL="http://localhost:$NODEODM_PORT?token=$TAP_TOKEN"
    fi

    echo "NodeODM webhook notification - URL: $NODEODM_URL"
    echo "Webhook base URL configured: ${_webhook_base_url:-'not set'}"

    # Check if webhook URL is configured and valid
    if [ -n "${_webhook_base_url}" ] && [ "${_webhook_base_url}" != "" ]; then
        CLUSTERODM_WEBHOOK_URL="${_webhook_base_url}"
        echo "Sending NodeODM ready notification to webhook: $CLUSTERODM_WEBHOOK_URL"

        # Prepare node info safely (avoid command substitution in curl)
        NODE_INFO_SAFE=$(echo "$NODEODM_INFO" | tr -d '\n' | sed 's/"/\\"/g')

        # Wait a few seconds for NodeODM to be fully ready, then send webhook
        (
            sleep 10 &&
            curl -k -s --data "event_type=nodeodm_ready&address=${NODEODM_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}&max_concurrency=${MAX_CONCURRENCY}&node_info=${NODE_INFO_SAFE}" "${CLUSTERODM_WEBHOOK_URL}" >/dev/null 2>&1 || echo "Legacy webhook notification failed"
        ) &

        echo "Legacy webhook notification scheduled for: $NODEODM_URL"
        echo "Legacy webhook endpoint: $CLUSTERODM_WEBHOOK_URL"
    else
        echo "No legacy webhook URL configured (_webhook_base_url not set or empty)"
        echo "Skipping legacy webhook notification"
        echo "NodeODM URL for manual access: $NODEODM_URL"
    fi
}