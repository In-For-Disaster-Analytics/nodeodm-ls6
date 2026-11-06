#!/bin/bash
#
# tests/test_nodeodx_launcher.sh - static and unit checks for the production NodeODX launcher
# (nodeodx/tapisjob_app.sh) checkpoint/resume wiring. No LS6, Tapis, apptainer or NodeODX needed.
# Needs bash, python3, zip/unzip.
#
# Usage: bash tests/test_nodeodx_launcher.sh
#

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$REPO_DIR/nodeodx/tapisjob_app.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/nodeodx-launcher-test.XXXXXX")
PASS=0
FAIL=0
trap 'rm -rf "$T"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$1', got '$2')"; fi; }
# line number of the first match of an extended regex in the launcher ("" when absent)
line_of() { grep -nE "$1" "$LAUNCHER" | head -n 1 | cut -d: -f1; }
assert_before() {  # earlier-line later-line message
    if [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; then ok "$3"; else bad "$3 ($1 vs $2)"; fi
}

echo "== syntax"
for f in "$LAUNCHER" "$REPO_DIR/tapisjob_app.sh" "$REPO_DIR/nodeodx/build-zip.sh" "$REPO_DIR"/lib/*.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n ${f#"$REPO_DIR"/}"; else bad "bash -n ${f#"$REPO_DIR"/}"; fi
done

echo "== launcher wiring"
for lib in common checkpoint task_watch; do
    if grep -qE "^source \"\\\$SCRIPT_DIR/lib/$lib\\.sh\"" "$LAUNCHER"; then ok "sources lib/$lib.sh"; else bad "sources lib/$lib.sh"; fi
done
assert_eq "NODEODM_LIB_FUNCTIONS_ONLY=1" "$(grep -m1 '^NODEODM_LIB_FUNCTIONS_ONLY=' "$LAUNCHER")" "libs loaded in functions-only mode"
L_PRUNE=$(line_of '^checkpoint_prune')
L_RESTORE=$(line_of 'checkpoint_restore_if_requested')
L_LAUNCH=$(line_of '^    apptainer exec --pwd /var/www .*NODEODX_BIND_ARGS.*SIF_PATH.*\\$')
L_WATCH=$(line_of '^            task_watch_start')
L_DISCOVER=$(line_of '^discover_active_task\(\)')
L_LOOP=$(line_of '^    discover_active_task \|\| true')
assert_before "$L_PRUNE" "$L_RESTORE" "checkpoint_prune runs before checkpoint_restore_if_requested"
assert_before "$L_RESTORE" "$L_LAUNCH" "restore runs before the NodeODX apptainer launch"
assert_before "$L_LAUNCH" "$L_WATCH" "task_watch_start comes after the launch (task discovery)"
assert_before "$L_DISCOVER" "$L_LOOP" "discovery function defined before the main loop"
CLEANUP_BODY=$(sed -n '/^cleanup() {/,/^}/p' "$LAUNCHER")
for needle in 'task_watch_wait' 'checkpoint_sync exit' 'task_watch_stop' 'deregister_node'; do
    if grep -q "$needle" <<<"$CLEANUP_BODY"; then ok "cleanup trap calls $needle"; else bad "cleanup trap calls $needle"; fi
done
assert_before "$(grep -n 'checkpoint_sync exit' <<<"$CLEANUP_BODY" | head -1 | cut -d: -f1)" \
              "$(grep -n 'deregister_node' <<<"$CLEANUP_BODY" | head -1 | cut -d: -f1)" "checkpoint_sync exit precedes deregister_node"
if grep -q '^trap cleanup EXIT TERM INT' "$LAUNCHER"; then ok "launcher keeps its own trap"; else bad "launcher keeps its own trap"; fi

echo "== registration payload"
# The function body holds a heredoc whose Python dict closes with a column-0 "}", so cut at the
# heredoc terminator and re-add the function's closing brace.
eval "$(sed -n '/^registration_payload() {/,/^PY$/p' "$LAUNCHER")
}"
export NODEODX_REGISTRATION_HOST=ls6.tacc.utexas.edu NODEODX_REGISTRATION_PORT=50123 \
       NODEODX_REGISTRATION_TOKEN=tok NODEODX_REGISTRATION_UUID=reg-1 NODEODX_REGISTRATION_JOB_UUID=job-1 \
       NODEODX_REGISTRATION_OWNER=alice NODEODX_REGISTRATION_ROLE=admin NODEODX_REGISTRATION_WORKER_ID=0 \
       NODEODX_REGISTRATION_CHILD_INDEX=primary NODEODX_REGISTRATION_HOST_INDEX=1 \
       NODEODX_REGISTRATION_JOB_INDEX=1 NODEODX_REGISTRATION_JOB_COUNT=1
pget() {  # key -> JSON value or MISSING
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[sys.argv[1]]) if sys.argv[1] in d else "MISSING")' "$1"
}
unset NODEODM_RESUME_TASK_UUID NODEODM_RESUME_MODE NODEODM_RESUME_FALLBACK_REASON
P=$(registration_payload)
assert_eq "2" "$(pget schemaVersion <<<"$P")" "schemaVersion is 2 without resume"
assert_eq "MISSING" "$(pget checkpointResume <<<"$P")" "no checkpointResume without resume"
assert_eq "MISSING" "$(pget resumeTaskUuid <<<"$P")" "no resumeTaskUuid without resume"
assert_eq '"alice"' "$(pget tapisJobOwner <<<"$P")" "existing fields preserved"
export NODEODM_RESUME_TASK_UUID=11111111-2222-3333-4444-555555555555 NODEODM_RESUME_MODE=failed NODEODM_RESUME_FALLBACK_REASON=checkpoint_missing
P=$(registration_payload)
assert_eq "2" "$(pget schemaVersion <<<"$P")" "schemaVersion is 2 with resume"
assert_eq "true" "$(pget checkpointResume <<<"$P")" "checkpointResume true"
assert_eq '"11111111-2222-3333-4444-555555555555"' "$(pget resumeTaskUuid <<<"$P")" "resumeTaskUuid"
assert_eq '"failed"' "$(pget resumeMode <<<"$P")" "resumeMode"
assert_eq '"checkpoint_missing"' "$(pget resumeFallbackReason <<<"$P")" "resumeFallbackReason"
unset NODEODM_RESUME_MODE
P=$(registration_payload)
assert_eq '"unknown"' "$(pget resumeMode <<<"$P")" "resumeMode defaults to unknown"
unset NODEODM_RESUME_TASK_UUID NODEODM_RESUME_FALLBACK_REASON

echo "== build-zip"
# Work in a temp copy so no stub or archive lands in the repo; the stub is only for checkouts
# without the vendored nodeodx-source.
mkdir -p "$T/repo/nodeodx"
cp -R "$REPO_DIR/lib" "$T/repo/lib"
cp "$REPO_DIR/nodeodx/build-zip.sh" "$REPO_DIR/nodeodx/tapisjob_app.sh" "$REPO_DIR/nodeodx/app.json" \
   "$REPO_DIR/nodeodx/README-ZIP.md" "$REPO_DIR/nodeodx/PINNED-SOURCE" "$T/repo/nodeodx/"
mkdir -p "$T/repo/nodeodx/nodeodx-source"
echo '{"name":"stub","version":"0.0.0"}' > "$T/repo/nodeodx/nodeodx-source/package.json"
APP_VERSION=$(python3 -c 'import json; print(json.load(open("'"$T"'/repo/nodeodx/app.json"))["version"])')
if ( cd "$T/repo/nodeodx" && SKIP_UPLOAD=1 APP_VERSION="$APP_VERSION" bash build-zip.sh ) >"$T/zip.log" 2>&1; then
    ok "build-zip.sh succeeds"
else
    bad "build-zip.sh succeeds"; sed 's/^/    /' "$T/zip.log"
fi
LISTING=$(unzip -l "$T/repo/nodeodx/nodeodx-ls6.zip" 2>/dev/null)
for m in common tap_auth nodeodm_launch task_monitor checkpoint task_watch clusterodm; do
    if grep -qE "(^|[[:space:]])lib/$m\\.sh\$" <<<"$LISTING"; then ok "ZIP contains lib/$m.sh"; else bad "ZIP contains lib/$m.sh"; fi
done
if grep -qE '(^|[[:space:]])tapisjob_app\.sh$' <<<"$LISTING"; then ok "ZIP contains tapisjob_app.sh"; else bad "ZIP contains tapisjob_app.sh"; fi
# the ZIP's launcher must be able to source its own lib/
mkdir "$T/unz" && unzip -q "$T/repo/nodeodx/nodeodx-ls6.zip" -d "$T/unz"
if ( NODEODM_LIB_FUNCTIONS_ONLY=1; source "$T/unz/lib/common.sh" && source "$T/unz/lib/checkpoint.sh" && source "$T/unz/lib/task_watch.sh" && verify_modules_loaded ) >/dev/null 2>&1; then
    ok "unpacked lib/ loads in functions-only mode and passes verify_modules_loaded"
else
    bad "unpacked lib/ loads in functions-only mode and passes verify_modules_loaded"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
