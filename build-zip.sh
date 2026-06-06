#!/bin/bash
set -e

# Build script for NodeODM LS6 ZIP package
# This creates a ZIP runtime that launches NodeODM through Apptainer on LS6.

PACKAGE_NAME="nodeodm-ls6.zip"
TAPIS_SYSTEM_ID="${TAPIS_SYSTEM_ID:-ptdatax.project.PTDATAX-225}"
TAPIS_REMOTE_DIR="${TAPIS_REMOTE_DIR:-NodeODM}"
REMOTE_SSH_TARGET="${REMOTE_SSH_TARGET:-ls6}"
REMOTE_UPLOAD_DIR="${REMOTE_UPLOAD_DIR:-/corral-repl/tacc/aci/PT2050/projects/PTDATAX-225/NodeODM}"
SKIP_UPLOAD="${SKIP_UPLOAD:-${SKIP_TAPIS_UPLOAD:-0}}"
TAPIS_CONTAINER_IMAGE_URI="tapis://${TAPIS_SYSTEM_ID}/${TAPIS_REMOTE_DIR}/${PACKAGE_NAME}"
REMOTE_UPLOAD_FILE="${REMOTE_UPLOAD_DIR%/}/${PACKAGE_NAME}"

if [ ! -d nodeodm-source ] || [ ! -f nodeodm-source/package.json ]; then
  echo "ERROR: nodeodm-source directory missing or incomplete (package.json not found)."
  echo "Populate nodeodm-source/ with the NodeODM repository (e.g. rsync from WebODM or git clone https://github.com/OpenDroneMap/NodeODM.git) before running this script."
  exit 1
fi

echo "Building NodeODM LS6 ZIP package (full)..."

# Clean up any existing files
rm -f "$PACKAGE_NAME"

# Create ZIP package with all necessary files including webhook scripts
echo "Creating ZIP package..."
zip -r "$PACKAGE_NAME" tapisjob_app.sh app.json README-ZIP.md register-node.sh deregister-node.sh nodeodm-source odm-patches \
  -x "nodeodm-source/.git/*" \
  -x "nodeodm-source/node_modules/*" \
  -x "odm-patches/__pycache__/*"

echo "ZIP package created: $PACKAGE_NAME"
echo "Size: $(ls -lh "$PACKAGE_NAME" | awk '{print $5}')"

if [ "$SKIP_UPLOAD" = "1" ]; then
  echo ""
  echo "Skipping upload (SKIP_UPLOAD=1)."
else
  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    echo ""
    echo "ERROR: upload requires ssh and scp."
    echo "Install/configure SSH, or rerun with SKIP_UPLOAD=1 to build only."
    exit 1
  fi

  echo ""
  echo "Creating remote directory ${REMOTE_SSH_TARGET}:${REMOTE_UPLOAD_DIR}..."
  ssh "$REMOTE_SSH_TARGET" "mkdir -p '$REMOTE_UPLOAD_DIR'"
  echo "Uploading $PACKAGE_NAME to ${REMOTE_SSH_TARGET}:${REMOTE_UPLOAD_FILE}..."
  scp "$PACKAGE_NAME" "${REMOTE_SSH_TARGET}:${REMOTE_UPLOAD_FILE}"
  echo "Uploaded $PACKAGE_NAME to ${REMOTE_SSH_TARGET}:${REMOTE_UPLOAD_FILE}"
fi

echo ""
echo "Contents:"
unzip -l "$PACKAGE_NAME"

echo ""
echo "This ZIP contains:"
echo "- tapisjob_app.sh: Main execution script that uses 'module load tacc-apptainer'"
echo "- app.json: Tapis app definition"
echo "- README-ZIP.md: Documentation"
echo "- register-node.sh: Webhook registration script for ClusterODM"
echo "- deregister-node.sh: Webhook de-registration script for ClusterODM"
echo "- nodeodm-source/: NodeODM source code synced into the runtime"
echo "- odm-patches/: ODM runtime patches bound into /code"

echo ""
echo "How it works:"
echo "1. Tapis extracts this ZIP on the compute node"
echo "2. tapisjob_app.sh runs with access to TACC module system"
echo "3. tapisjob_app.sh loads tacc-apptainer module and launches NodeODM container"
echo "4. This avoids nested container issues"

echo ""
echo "Next steps:"
echo "1. Confirm app.json containerImage points to ${TAPIS_CONTAINER_IMAGE_URI}"
echo "2. Register or update the app with Tapis"
