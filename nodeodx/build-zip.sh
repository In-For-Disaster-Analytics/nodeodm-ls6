#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE_NAME="nodeodx-ls6.zip"
SKIP_UPLOAD="${SKIP_UPLOAD:-${SKIP_TAPIS_UPLOAD:-1}}"
TAPIS_SYSTEM_ID="${TAPIS_SYSTEM_ID:-ptdatax.project.PTDATAX-225}"
TAPIS_REMOTE_DIR="${TAPIS_REMOTE_DIR:-NodeODX}"
REMOTE_SSH_TARGET="${REMOTE_SSH_TARGET:-ls6}"
REMOTE_UPLOAD_DIR="${REMOTE_UPLOAD_DIR:-/corral-repl/tacc/aci/PT2050/projects/PTDATAX-225/NodeODX}"

test -f tapisjob_app.sh
test -f app.json
test -f nodeodx-source/package.json

rm -f "$PACKAGE_NAME"
zip -qr "$PACKAGE_NAME" \
    tapisjob_app.sh app.json README-ZIP.md PINNED-SOURCE nodeodx-source \
    -x 'nodeodx-source/.git/*' \
    -x 'nodeodx-source/node_modules/*' \
    -x 'nodeodx-source/tests/data/*' \
    -x 'nodeodx-source/tests/processing_results/*'

unzip -tq "$PACKAGE_NAME"
unzip -l "$PACKAGE_NAME" | grep -E '(^|/)tapisjob_app\.sh$|(^|/)app\.json$|nodeodx-source/package\.json$' >/dev/null
echo "Created $SCRIPT_DIR/$PACKAGE_NAME ($(du -h "$PACKAGE_NAME" | awk '{print $1}'))"
echo "Tapis URI: tapis://$TAPIS_SYSTEM_ID/$TAPIS_REMOTE_DIR/$PACKAGE_NAME"

if [[ "$SKIP_UPLOAD" == "1" ]]; then
    echo "Skipping upload (SKIP_UPLOAD=1)."
    exit 0
fi

ssh "$REMOTE_SSH_TARGET" "mkdir -p '$REMOTE_UPLOAD_DIR'"
scp "$PACKAGE_NAME" "$REMOTE_SSH_TARGET:${REMOTE_UPLOAD_DIR%/}/$PACKAGE_NAME"
echo "Uploaded to $REMOTE_SSH_TARGET:${REMOTE_UPLOAD_DIR%/}/$PACKAGE_NAME"
