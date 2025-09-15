#!/bin/bash

# Test script to verify ClusterODM connection setup using HTTP API

CLUSTERODM_HOST=${1:-"clusterodm.tacc.utexas.edu"}
CLUSTERODM_URL=${2:-"https://clusterodm.tacc.utexas.edu"}

echo "=== ClusterODM HTTP API Connection Test ==="
echo "ClusterODM Host: $CLUSTERODM_HOST"
echo "ClusterODM URL: $CLUSTERODM_URL"
echo ""

# Test basic HTTP connectivity
echo "Testing HTTPS connectivity to ClusterODM..."
if curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/info" > /dev/null 2>&1; then
    echo "✓ Successfully connected to $CLUSTERODM_URL"

    # Get ClusterODM info
    echo ""
    echo "ClusterODM Info:"
    CLUSTERODM_INFO=$(curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/info" 2>/dev/null)
    echo "$CLUSTERODM_INFO" | head -10

else
    echo "✗ Failed to connect to $CLUSTERODM_URL"
    echo "  This could mean:"
    echo "  - ClusterODM is not running"
    echo "  - Firewall is blocking the connection"
    echo "  - SSL/TLS issues"
    echo "  - Host/URL is incorrect"

    # Try HTTP as fallback
    echo ""
    echo "Trying HTTP fallback..."
    HTTP_URL="http://${CLUSTERODM_HOST}"
    if curl -s --connect-timeout 10 "$HTTP_URL/info" > /dev/null 2>&1; then
        echo "✓ HTTP connection successful to $HTTP_URL"
        CLUSTERODM_URL=$HTTP_URL
    else
        echo "✗ HTTP connection also failed"
        exit 1
    fi
fi

# Test nodes endpoint
echo ""
echo "Testing ClusterODM nodes endpoint..."
NODES_RESPONSE=$(curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/nodes" 2>/dev/null || echo "ENDPOINT_NOT_AVAILABLE")

if [ "$NODES_RESPONSE" != "ENDPOINT_NOT_AVAILABLE" ]; then
    echo "✓ Nodes endpoint is accessible"
    echo "Current nodes:"
    echo "$NODES_RESPONSE" | head -10
else
    echo "✗ Nodes endpoint not accessible"
    echo "  ClusterODM might use a different API structure"
fi

# Test a sample node registration (dry run)
echo ""
echo "Testing sample node registration (dry run)..."
TEST_HOSTNAME="test-node"
TEST_PORT="3001"

# Try JSON format first
echo "Testing JSON API registration..."
JSON_RESPONSE=$(curl -k -s --connect-timeout 10 -X POST \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$TEST_HOSTNAME\",\"port\":$TEST_PORT,\"token\":\"\",\"dry_run\":true}" \
    "$CLUSTERODM_URL/nodes" 2>/dev/null || echo "JSON_API_NOT_AVAILABLE")

if [ "$JSON_RESPONSE" != "JSON_API_NOT_AVAILABLE" ]; then
    echo "✓ JSON API registration endpoint appears to work"
    echo "Response: $JSON_RESPONSE"
else
    echo "JSON API not available, testing form-based registration..."

    # Try form-based approach
    FORM_RESPONSE=$(curl -k -s --connect-timeout 10 -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "hostname=$TEST_HOSTNAME&port=$TEST_PORT&token=&action=add_node&dry_run=true" \
        "$CLUSTERODM_URL/admin/nodes" 2>/dev/null || echo "FORM_API_NOT_AVAILABLE")

    if [ "$FORM_RESPONSE" != "FORM_API_NOT_AVAILABLE" ]; then
        echo "✓ Form-based registration endpoint appears to work"
    else
        echo "✗ Neither JSON nor form-based registration endpoints are available"
        echo "  Manual registration via web interface may be required"
    fi
fi

# Test webhook endpoint
echo ""
echo "Testing webhook endpoint..."
WEBHOOK_RESPONSE=$(curl -k -s --connect-timeout 10 -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "event_type=test&message=connection_test" \
    "$CLUSTERODM_URL/webhook" 2>/dev/null || echo "WEBHOOK_NOT_AVAILABLE")

if [ "$WEBHOOK_RESPONSE" != "WEBHOOK_NOT_AVAILABLE" ]; then
    echo "✓ Webhook endpoint is accessible"
else
    echo "✗ Webhook endpoint not available"
fi

echo ""
echo "=== Test Summary ==="
echo "1. HTTPS connectivity: $(curl -k -s --connect-timeout 10 "$CLUSTERODM_URL/info" > /dev/null 2>&1 && echo 'PASS' || echo 'FAIL')"
echo "2. Nodes endpoint: $([ "$NODES_RESPONSE" != "ENDPOINT_NOT_AVAILABLE" ] && echo 'PASS' || echo 'FAIL')"
echo "3. Registration API: $([ "$JSON_RESPONSE" != "JSON_API_NOT_AVAILABLE" ] && echo 'PASS' || echo 'PARTIAL')"
echo "4. Webhook endpoint: $([ "$WEBHOOK_RESPONSE" != "WEBHOOK_NOT_AVAILABLE" ] && echo 'PASS' || echo 'FAIL')"
echo ""
echo "Connection methods available:"
echo "  Primary: HTTP API calls to $CLUSTERODM_URL"
echo "  Alternative: Web interface at $CLUSTERODM_URL/admin"
echo "  Webhook notifications to: $CLUSTERODM_URL/webhook"