#!/bin/bash
set -e

# Build script for NodeODM LS6 ZIP package (minimal version)
# This creates a ZIP with just the run.sh script since we use apptainer to run the NodeODM container

PACKAGE_NAME="nodeodm-ls6.zip"

echo "Building NodeODM LS6 ZIP package (minimal)..."

# Clean up any existing files
rm -f $PACKAGE_NAME

# Create ZIP package with just the necessary files
echo "Creating ZIP package..."
zip -r $PACKAGE_NAME tapisjob_app.sh app.json README-ZIP.md

echo "ZIP package created: $PACKAGE_NAME"
echo "Size: $(ls -lh $PACKAGE_NAME | awk '{print $5}')"

echo ""
echo "Contents:"
unzip -l $PACKAGE_NAME

echo ""
echo "This ZIP contains:"
echo "- run.sh: Main execution script that uses 'module load tacc-apptainer'"
echo "- app.json: Tapis app definition"
echo "- README-ZIP.md: Documentation"

echo ""
echo "How it works:"
echo "1. Tapis extracts this ZIP on the compute node"
echo "2. run.sh runs with access to TACC module system"
echo "3. run.sh loads tacc-apptainer module and launches NodeODM container"
echo "4. This avoids nested container issues"

echo ""
echo "Next steps:"
echo "1. Upload $PACKAGE_NAME to a publicly accessible URL"
echo "2. Update the containerImage in app.json to point to that URL"
echo "3. Register the app with Tapis"