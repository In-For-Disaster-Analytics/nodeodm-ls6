#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE_NAME="nodeodx-ls6.zip"
SKIP_UPLOAD="${SKIP_UPLOAD:-${SKIP_TAPIS_UPLOAD:-1}}"
TAPIS_SYSTEM_ID="${TAPIS_SYSTEM_ID:-cloud.data}"
TAPIS_REMOTE_DIR="${TAPIS_REMOTE_DIR:-corral-repl/utexas/BCS26030/NodeODX}"
REMOTE_SSH_TARGET="${REMOTE_SSH_TARGET:-ls6}"
REMOTE_UPLOAD_DIR="${REMOTE_UPLOAD_DIR:-/corral/utexas/BCS26030/NodeODX}"
CORRAL_GROUP="${CORRAL_GROUP:-G-829114}"
CORRAL_READ_GROUP="${CORRAL_READ_GROUP:-G-820466}"

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

REMOTE_UPLOAD_PATH="${REMOTE_UPLOAD_DIR%/}/$PACKAGE_NAME"

# Corral charges newly created files to the effective group. Stream the archive
# through a shell using the allocation group rather than using scp directly,
# because the caller's primary group may be the exhausted legacy allocation.
ssh "$REMOTE_SSH_TARGET" \
    "sg '$CORRAL_GROUP' -c 'set -eu; test -d \"$REMOTE_UPLOAD_DIR\"; test -w \"$REMOTE_UPLOAD_DIR\"; umask 007; tmp=\"$REMOTE_UPLOAD_PATH.tmp.\$\$\"; cat > \"\$tmp\"; setfacl -m g::rw-,g:$CORRAL_READ_GROUP:r--,m::rw- \"\$tmp\"; mv -f \"\$tmp\" \"$REMOTE_UPLOAD_PATH\"; stat -c \"owner=%U group=%G mode=%A path=%n\" \"$REMOTE_UPLOAD_PATH\"; getfacl \"$REMOTE_UPLOAD_PATH\"'" \
    < "$PACKAGE_NAME"
echo "Uploaded to $REMOTE_SSH_TARGET:$REMOTE_UPLOAD_PATH using group $CORRAL_GROUP"
