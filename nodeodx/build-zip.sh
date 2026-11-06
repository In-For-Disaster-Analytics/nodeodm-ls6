#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE_NAME="nodeodx-ls6.zip"
SKIP_UPLOAD="${SKIP_UPLOAD:-${SKIP_TAPIS_UPLOAD:-1}}"
TAPIS_SYSTEM_ID="${TAPIS_SYSTEM_ID:-cloud.data}"
APP_VERSION="${APP_VERSION:-$(node -p "require('./app.json').version")}"
TAPIS_REMOTE_DIR="${TAPIS_REMOTE_DIR:-corral-repl/utexas/BCS26030/NodeODX/${APP_VERSION}}"
REMOTE_SSH_TARGET="${REMOTE_SSH_TARGET:-ls6}"
REMOTE_UPLOAD_DIR="${REMOTE_UPLOAD_DIR:-/corral/utexas/BCS26030/NodeODX/${APP_VERSION}}"
CORRAL_GROUP="${CORRAL_GROUP:-G-829114}"
CORRAL_READ_GROUP="${CORRAL_READ_GROUP:-G-820466}"

test -f tapisjob_app.sh
test -f app.json
test -f nodeodx-source/package.json
# Shared checkpoint/resume modules live in the repo-root lib/ (also used by the nodeodm-ls62 app).
LIB_SOURCE_DIR="$SCRIPT_DIR/../lib"
test -d "$LIB_SOURCE_DIR"

rm -f "$PACKAGE_NAME"
zip -qr "$PACKAGE_NAME" \
    tapisjob_app.sh app.json README-ZIP.md PINNED-SOURCE nodeodx-source \
    -x 'nodeodx-source/.git/*' \
    -x 'nodeodx-source/node_modules/*' \
    -x 'nodeodx-source/tests/data/*' \
    -x 'nodeodx-source/tests/processing_results/*'

# Add lib/ so the archive carries lib/*.sh next to tapisjob_app.sh; staged in a temp dir so no
# copy is left in the working tree.
LIB_STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$LIB_STAGE_DIR"' EXIT
mkdir "$LIB_STAGE_DIR/lib"
cp "$LIB_SOURCE_DIR"/*.sh "$LIB_STAGE_DIR/lib/"
(cd "$LIB_STAGE_DIR" && zip -qr "$SCRIPT_DIR/$PACKAGE_NAME" lib -x 'lib/__pycache__/*')

unzip -tq "$PACKAGE_NAME"
unzip -l "$PACKAGE_NAME" | grep -E '(^|/)tapisjob_app\.sh$|(^|/)app\.json$|nodeodx-source/package\.json$' >/dev/null
# The launcher sources these seven modules' shared subset; fail the build if any is missing.
EXPECTED_MODULES=7
FOUND_MODULES="$(unzip -l "$PACKAGE_NAME" | grep -cE '(^|[[:space:]])lib/(common|tap_auth|nodeodm_launch|task_monitor|checkpoint|task_watch|clusterodm)\.sh$' || true)"
if [[ "$FOUND_MODULES" -ne "$EXPECTED_MODULES" ]]; then
    echo "ERROR: ZIP missing module files (found $FOUND_MODULES/$EXPECTED_MODULES)" >&2
    unzip -l "$PACKAGE_NAME" | grep 'lib/' >&2 || true
    exit 1
fi
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
