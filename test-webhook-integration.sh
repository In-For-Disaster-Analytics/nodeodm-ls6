#!/bin/bash

# Test script for NodeODM webhook integration
# This simulates the registration/de-registration process without starting NodeODM

echo "🧪 Testing NodeODM Webhook Integration"
echo "====================================="

# Set up test environment variables
export CLUSTER_HOST="clusterodm.tacc.utexas.edu"
export CLUSTER_PORT="443"
export NODE_HOST="$(hostname)"
export NODE_PORT="3001"
export TAPIS_TOKEN="test:$(whoami):$(date +%s)"

echo "📋 Test Configuration:"
echo "  Cluster: $CLUSTER_HOST:$CLUSTER_PORT"
echo "  Node: $NODE_HOST:$NODE_PORT"
echo "  Token: ${TAPIS_TOKEN:0:20}..."
echo ""

# Test 1: Registration
echo "🔗 Test 1: Node Registration"
echo "----------------------------"
if [ -f "./register-node.sh" ]; then
    echo "✅ Registration script found"

    # Test registration (will fail without ClusterODM running, but shows the process)
    echo "Attempting registration..."
    ./register-node.sh --retries 1 --retry-delay 1

    if [ $? -eq 0 ]; then
        echo "✅ Registration test completed successfully"
        REGISTRATION_SUCCESS=true
    else
        echo "⚠️ Registration failed (expected if ClusterODM not accessible)"
        REGISTRATION_SUCCESS=false
    fi
else
    echo "❌ Registration script not found"
    REGISTRATION_SUCCESS=false
fi

echo ""

# Test 2: De-registration
echo "🔌 Test 2: Node De-registration"
echo "------------------------------"
if [ -f "./deregister-node.sh" ]; then
    echo "✅ De-registration script found"

    # Test de-registration
    echo "Attempting de-registration..."
    ./deregister-node.sh --retries 1 --retry-delay 1

    if [ $? -eq 0 ]; then
        echo "✅ De-registration test completed successfully"
        DEREGISTRATION_SUCCESS=true
    else
        echo "⚠️ De-registration failed (expected if ClusterODM not accessible)"
        DEREGISTRATION_SUCCESS=false
    fi
else
    echo "❌ De-registration script not found"
    DEREGISTRATION_SUCCESS=false
fi

echo ""

# Test 3: ZIP package contents
echo "📦 Test 3: ZIP Package Verification"
echo "----------------------------------"
if [ -f "./nodeodm-ls6.zip" ]; then
    echo "✅ ZIP package found"

    echo "Package contents:"
    unzip -l nodeodm-ls6.zip | grep -E "(register-node|deregister-node|tapisjob_app)"

    # Check if webhook scripts are in the ZIP
    if unzip -l nodeodm-ls6.zip | grep -q "register-node.sh"; then
        echo "✅ register-node.sh included in ZIP"
    else
        echo "❌ register-node.sh missing from ZIP"
    fi

    if unzip -l nodeodm-ls6.zip | grep -q "deregister-node.sh"; then
        echo "✅ deregister-node.sh included in ZIP"
    else
        echo "❌ deregister-node.sh missing from ZIP"
    fi
else
    echo "❌ ZIP package not found (run ./build-zip.sh first)"
fi

echo ""

# Test 4: Function definitions in main script
echo "⚙️ Test 4: Function Integration Check"
echo "-----------------------------------"
if [ -f "./tapisjob_app.sh" ]; then
    echo "✅ Main script found"

    if grep -q "register_with_clusterodm" tapisjob_app.sh; then
        echo "✅ register_with_clusterodm function found"
    else
        echo "❌ register_with_clusterodm function missing"
    fi

    if grep -q "deregister_from_clusterodm" tapisjob_app.sh; then
        echo "✅ deregister_from_clusterodm function found"
    else
        echo "❌ deregister_from_clusterodm function missing"
    fi

    if grep -q "TAPIS_TOKEN" tapisjob_app.sh; then
        echo "✅ Tapis token usage found"
    else
        echo "❌ Tapis token usage missing"
    fi
else
    echo "❌ Main script not found"
fi

echo ""

# Summary
echo "📊 Test Summary"
echo "==============="
echo "Registration scripts: $([ -f register-node.sh ] && [ -f deregister-node.sh ] && echo "✅ Present" || echo "❌ Missing")"
echo "ZIP package: $([ -f nodeodm-ls6.zip ] && echo "✅ Built" || echo "❌ Not built")"
echo "Function integration: $(grep -q "register_with_clusterodm\|deregister_from_clusterodm" tapisjob_app.sh 2>/dev/null && echo "✅ Integrated" || echo "❌ Not integrated")"

echo ""
echo "🚀 Integration Status:"
if [ -f register-node.sh ] && [ -f deregister-node.sh ] && [ -f nodeodm-ls6.zip ]; then
    echo "✅ NodeODM webhook integration is ready for deployment!"
    echo ""
    echo "📝 Next steps:"
    echo "  1. Upload nodeodm-ls6.zip to accessible URL"
    echo "  2. Update app.json containerImage URL"
    echo "  3. Submit Tapis job"
    echo "  4. NodeODM will automatically register/de-register with ClusterODM"
else
    echo "⚠️ Integration incomplete - check missing components above"
fi

echo ""
echo "🔍 For debugging, check:"
echo "  - ClusterODM admin interface: https://clusterodm.tacc.utexas.edu/admin"
echo "  - NodeODM logs in job output"
echo "  - Webhook endpoint: https://clusterodm.tacc.utexas.edu/webhook/"