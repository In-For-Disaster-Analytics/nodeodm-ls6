#!/bin/bash
#
# tests/test_checkpoint.sh - local tests for the terminal checkpoint (lib/checkpoint.sh,
# lib/task_watch.sh). No LS6, Tapis, apptainer or NodeODM needed: a temp directory stands in
# for NODEODM_RUNTIME_DIR and NODEODM_CHECKPOINT_ROOT, and fake tasks.json / log.json / task
# directories are generated. Needs bash, python3, rsync and coreutils.
#
# Usage: bash tests/test_checkpoint.sh
#

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ckpt-test.XXXXXX")
PASS=0
FAIL=0
cleanup_tests() {
    chmod -R u+w "$T" 2>/dev/null
    rm -rf "$T"
}
trap cleanup_tests EXIT

# Defaults as shipped, captured before any test overrides
unset NODEODM_RESUME_ALLOW_COLD_START NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL NODEODM_CHECKPOINT_MAX_BYTES \
      NODEODM_CHECKPOINT_EXCLUDE NODEODM_RESUME_AS_UUID 2>/dev/null
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"
source "$REPO_DIR/lib/checkpoint.sh"
source "$REPO_DIR/lib/task_watch.sh"
trap cleanup_tests EXIT   # common.sh clears the EXIT trap

DEFAULT_COLD_START="$NODEODM_RESUME_ALLOW_COLD_START"
DEFAULT_COPY_ON_TERMINAL="$NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL"
DEFAULT_MAX_BYTES="$NODEODM_CHECKPOINT_MAX_BYTES"
DEFAULT_EXCLUDE="$NODEODM_CHECKPOINT_EXCLUDE"

# ----------------------------------------------------------------------------- helpers
ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() {  # expected actual message
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$1', got '$2')"; fi
}
assert_file()    { if [ -e "$1" ] || [ -L "$1" ]; then ok "$2"; else bad "$2 (missing $1)"; fi; }
assert_no_file() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then ok "$2"; else bad "$2 (unexpected $1)"; fi; }

jget() {  # file dotted.path -> scalar, or JSON for lists/dicts/bool/null
    python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v[k] if isinstance(v, dict) else v[int(k)]
print(json.dumps(v) if isinstance(v, (list, dict, bool)) or v is None else v)' "$1" "$2"
}

jmutate() {  # file python-statement operating on dict m
    python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(m, open(sys.argv[1], "w"))' "$1" "$2"
}

new_env() {
    rm -rf "$T/case"
    mkdir -p "$T/case/runtime/data" "$T/case/out" "$T/case/media" "$T/case/bin"
    NODEODM_RUNTIME_DIR="$T/case/runtime"
    NODEODM_CHECKPOINT_ROOT="$T/case/ckroot"
    mkdir -p "$NODEODM_CHECKPOINT_ROOT"
    NODEODM_CORRAL_MEDIA_ROOT="$T/case/media"
    OUTPUT_DIR="$T/case/out"
    LOG_FILE="$T/case/out/nodeodm.log"; echo "log" > "$LOG_FILE"
    WORK_DIR="$T/case"
    _tapisJobUUID="job-A"
    _tapisJobOwner="tester"
    NODEODM_ENGINE_VERSION="3.5.0"
    NODEODM_IMAGE="example/nodeodm@sha256:abc123"
    NODEODM_SIF=""
    NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL=1
    NODEODM_CHECKPOINT_EXCLUDE="$DEFAULT_EXCLUDE"
    NODEODM_CHECKPOINT_MAX_BYTES="$DEFAULT_MAX_BYTES"
    NODEODM_CHECKPOINT_RETENTION_SECONDS=604800
    NODEODM_RESUME_TASK_UUID=""
    NODEODM_RESUME_CHECKPOINT_PATH=""
    NODEODM_RESUME_DATA_PATH=""
    NODEODM_RESUME_RUNTIME_PATH=""
    NODEODM_RESUME_IMPORT_PATH=""
    NODEODM_RESUME_AS_UUID=""
    NODEODM_RESUME_ALLOW_COLD_START=0
    NODEODM_RESUME_ALLOWED_ROOTS="$T/case/scratch"
    NODEODM_RESUME_OPTIONS_JSON=""
    NODEODM_RESUME_MODE=""
    NODEODM_RESUME_FALLBACK_REASON=""
    SLURM_TIMELIMIT=240
    TASK_UUID=""
    STATUS_RESPONSE=""
    CHECKPOINT_SYNCING=0
    CHECKPOINT_LAST_SYNC=0
    CHECKPOINT_ENGINE_VERSION=""
    CHECKPOINT_IMAGE_DIGEST=""
    CHECKPOINT_RESTORE_REASON=""
    CHECKPOINT_RESUMED_UUID=""
    TASK_WATCH_PID=""
    TASK_WATCH_UUID=""
    PATH="$ORIG_PATH"
}
ORIG_PATH="$PATH"

# make_task <uuid> [status_code] [images: dir|symlink]
make_task() {
    local uuid="$1" code="${2:-40}" images="${3:-dir}"
    local d="$NODEODM_RUNTIME_DIR/data/$uuid"
    mkdir -p "$d/odm_filterpoints" "$d/odm_georeferencing" "$d/odm_texturing" "$d/odm_orthophoto" \
             "$d/entwine_pointcloud" "$d/potree_pointcloud" "$d/orthophoto_tiles" "$d/3d_tiles" "$d/opensfm"
    head -c 4096 /dev/urandom > "$d/odm_filterpoints/point_cloud.ply"
    echo "geo" > "$d/odm_georeferencing/odm_georeferenced_model.laz"
    echo "tex" > "$d/odm_texturing/model.obj"
    echo "ortho" > "$d/odm_orthophoto/odm_orthophoto.tif"
    echo "mb" > "$d/odm_orthophoto/odm_orthophoto.mbtiles"
    echo "e" > "$d/entwine_pointcloud/ept.json"
    echo "p" > "$d/potree_pointcloud/cloud.js"
    echo "t" > "$d/orthophoto_tiles/0.png"
    echo "3d" > "$d/3d_tiles/tileset.json"
    echo "z" > "$d/all.zip"
    echo "sfm" > "$d/opensfm/reconstruction.json"
    cat > "$d/log.json" <<'JSON'
{"stages": [
 {"id": "dataset", "name": "Load Dataset", "startTime": 1, "endTime": 2},
 {"id": "opensfm", "name": "Structure from Motion", "startTime": 2, "endTime": 3},
 {"id": "odm_filterpoints", "name": "Filter Points", "startTime": 3, "endTime": 4},
 {"id": "odm_dem", "name": "DEM", "startTime": 4, "endTime": 5}]}
JSON
    if [ "$images" = "symlink" ]; then
        mkdir -p "$NODEODM_CORRAL_MEDIA_ROOT/project/images"
        echo "img" > "$NODEODM_CORRAL_MEDIA_ROOT/project/images/a.jpg"
        ln -s "$NODEODM_CORRAL_MEDIA_ROOT/project/images" "$d/images"
    else
        mkdir -p "$d/images"
        echo "jpg1" > "$d/images/a.jpg"
        echo "jpg2" > "$d/images/b.jpg"
    fi
    UUID="$uuid" CODE="$code" TASKS="$NODEODM_RUNTIME_DIR/data/tasks.json" python3 - <<'PY'
import json, os
path = os.environ["TASKS"]
tasks = json.load(open(path)) if os.path.exists(path) else []
tasks.append({"uuid": os.environ["UUID"], "name": "test", "status": {"code": int(os.environ["CODE"])},
              "options": [{"name": "dem-resolution", "value": 5}, {"name": "rerun-from", "value": "odm_dem"}],
              "imagesCount": 2})
json.dump(tasks, open(path, "w"))
PY
}

ckdir() { echo "$NODEODM_CHECKPOINT_ROOT/$1"; }

count_files() { find "$1" -type f ! -name .complete | wc -l | tr -d ' '; }
count_bytes() { find "$1" -type f ! -name .complete -exec wc -c {} + | awk '$2 != "total" {s += $1} END {print s + 0}'; }

# ----------------------------------------------------------------------------- tests
UUID_A="11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
UUID_B="22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

test_defaults() {
    echo "[defaults]"
    assert_eq "0" "$DEFAULT_COLD_START" "NODEODM_RESUME_ALLOW_COLD_START defaults to 0"
    assert_eq "0" "$DEFAULT_COPY_ON_TERMINAL" "NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL defaults to 0"
    assert_eq "1099511627776" "$DEFAULT_MAX_BYTES" "NODEODM_CHECKPOINT_MAX_BYTES defaults to 1 TB"
    assert_eq "*.zip odm_orthophoto/*.mbtiles *_tiles/ entwine_pointcloud/ potree_pointcloud/" "$DEFAULT_EXCLUDE" \
        "NODEODM_CHECKPOINT_EXCLUDE default list"
    if grep -q '\\"schemaVersion\\": 2' "$REPO_DIR/lib/clusterodm.sh"; then ok "registration payload carries schemaVersion 2"; else bad "registration payload carries schemaVersion 2"; fi
}

test_atomic_copy() {
    echo "[atomic copy, .complete, manifest schema 2]"
    new_env; make_task "$UUID_A" 40 dir
    TASK_UUID="$UUID_A"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m
    ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    assert_file "$ck/data/.complete" ".complete marker exists"
    assert_no_file "$ck/data.tmp" "no data.tmp left"
    assert_no_file "$ck/lock" "lock released"
    assert_file "$ck/data/$UUID_A/log.json" "task directory copied"
    assert_file "$ck/data/tasks.json" "tasks.json copied"
    assert_no_file "$ck/data/$UUID_A/all.zip" "*.zip excluded"
    assert_no_file "$ck/data/$UUID_A/odm_orthophoto/odm_orthophoto.mbtiles" "mbtiles excluded"
    assert_no_file "$ck/data/$UUID_A/entwine_pointcloud" "entwine_pointcloud/ excluded"
    assert_no_file "$ck/data/$UUID_A/potree_pointcloud" "potree_pointcloud/ excluded"
    assert_no_file "$ck/data/$UUID_A/orthophoto_tiles" "*_tiles/ excluded"
    assert_file "$ck/data/$UUID_A/3d_tiles/tileset.json" "3d_tiles/ kept despite *_tiles/"
    assert_file "$ck/data/$UUID_A/odm_filterpoints/point_cloud.ply" "stage directories kept"
    assert_file "$ck/data/$UUID_A/images/a.jpg" "uploaded images dir kept"
    local files bytes
    files=$(count_files "$ck/data"); bytes=$(count_bytes "$ck/data")
    assert_eq "$files" "$(jget "$ck/data/.complete" files)" ".complete file count matches find"
    assert_eq "$bytes" "$(jget "$ck/data/.complete" bytes)" ".complete byte count matches find"
    assert_eq "$files" "$(jget "$m" fileCount)" "manifest fileCount matches"
    assert_eq "$bytes" "$(jget "$m" checkpointBytes)" "manifest checkpointBytes matches"
    assert_eq "2" "$(jget "$m" schemaVersion)" "schemaVersion 2"
    assert_eq "synced" "$(jget "$m" state)" "state synced"
    assert_eq "true" "$(jget "$m" dataComplete)" "dataComplete true"
    assert_eq '["dataset", "opensfm", "odm_filterpoints", "odm_dem"]' "$(jget "$m" stagesCompleted)" "stagesCompleted lists every stage in log.json"
    assert_eq "false" "$(jget "$m" split)" "split false"
    assert_eq "1" "$(jget "$m" nodeCount)" "nodeCount defaults to 1"
    CHECKPOINT_SYNCING=0; rm -rf "$ck"; SLURM_JOB_NUM_NODES=4
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    assert_eq "4" "$(jget "$m" nodeCount)" "nodeCount from SLURM_JOB_NUM_NODES"
    unset SLURM_JOB_NUM_NODES
    assert_eq "null" "$(jget "$m" submodelCloudsPresent)" "submodelCloudsPresent null when not split"
    assert_eq "dir" "$(jget "$m" imagesKind)" "imagesKind dir"
    assert_eq "40" "$(jget "$m" taskStatus)" "taskStatus 40"
    assert_eq "odm" "$(jget "$m" engine)" "engine odm"
    assert_eq "3.5.0" "$(jget "$m" engineVersion)" "engineVersion"
    assert_eq "sha256:abc123" "$(jget "$m" imageDigest)" "imageDigest from @sha256 reference"
    assert_eq "digest" "$(jget "$m" imageDigestKind)" "imageDigestKind digest"
    assert_eq "false" "$(jget "$m" optimizeDiskSpace)" "optimizeDiskSpace false"
    assert_eq "job-A" "$(jget "$m" writerJobUuid)" "writerJobUuid"
    case "$(jget "$m" optionsHash)" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ok "optionsHash is hex";; *) bad "optionsHash is hex";; esac
    assert_eq "40" "$(jget "$m" optionsHash | tr -d '\n' | wc -c | tr -d ' ')" "optionsHash is a sha1 (40 hex chars)"
    assert_eq "True" "$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["expiresAt"] > m["updatedAt"])' "$m")" "expiresAt after updatedAt"
    assert_eq "live-resumable" "$(r=$(checkpoint_evaluate_resumable "$m" "$ck/data/$UUID_A" "" "$ck/data/.complete"); [ "$r" = ok ] && echo live-resumable || echo "$r")" "evaluate rule says ok"
}

test_no_double_write() {
    echo "[exit is a no-op after a synced terminal checkpoint]"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m before after out
    ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    before=$(cksum < "$m"); sleep 1
    out=$(checkpoint_sync exit "$UUID_A" 2>&1)
    after=$(cksum < "$m")
    assert_eq "$before" "$after" "manifest unchanged by exit sync"
    case "$out" in *"already synced"*) ok "exit sync reports already synced";; *) bad "exit sync reports already synced ($out)";; esac
    checkpoint_sync periodic "$UUID_A" >/dev/null 2>&1
    assert_eq "synced" "$(jget "$m" state)" "periodic manifest does not downgrade synced"
}

test_partial_on_killed_copy() {
    echo "[killed copy -> partial; retry at exit -> synced]"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    cat > "$T/case/bin/rsync" <<'EOS'
#!/bin/bash
# Fake rsync: create a few files in the destination, then die like a killed copy.
for a in "$@"; do dest="$a"; done
mkdir -p "$dest"; echo half > "$dest/half-copied"; exit 1
EOS
    chmod +x "$T/case/bin/rsync"
    PATH="$T/case/bin:$ORIG_PATH"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m
    ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    assert_file "$ck/data.tmp/$UUID_A/half-copied" "data.tmp left behind"
    assert_no_file "$ck/data" "data/ never published"
    assert_no_file "$ck/lock" "lock released after failure"
    assert_eq "partial" "$(jget "$m" state)" "state partial"
    assert_eq "false" "$(jget "$m" dataComplete)" "dataComplete false"
    assert_eq "partial" "$(checkpoint_evaluate_resumable "$m" "$ck/data/$UUID_A" "" "$ck/data/.complete")" "rule: not resumable, reason partial"
    # exit safety net retries (no synced manifest yet) with a working rsync
    PATH="$ORIG_PATH"
    checkpoint_sync exit "$UUID_A" >/dev/null 2>&1
    assert_eq "synced" "$(jget "$m" state)" "exit retry produces synced"
    assert_no_file "$ck/data.tmp" "data.tmp replaced"
}

test_previous_data_survives_killed_copy() {
    echo "[a failed second copy keeps the previous data/ intact]"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m
    ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    # new writer job, same task id (re-run), copy dies
    _tapisJobUUID="job-B"; CHECKPOINT_SYNCING=0
    cat > "$T/case/bin/rsync" <<'EOS'
#!/bin/bash
for a in "$@"; do dest="$a"; done
mkdir -p "$dest"; echo half > "$dest/half-copied"; exit 1
EOS
    chmod +x "$T/case/bin/rsync"; PATH="$T/case/bin:$ORIG_PATH"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    assert_file "$ck/data/.complete" "previous data/.complete untouched"
    assert_file "$ck/data/$UUID_A/log.json" "previous data/ intact"
    assert_eq "partial" "$(jget "$m" state)" "manifest says partial (new copy did not finish)"
}

test_write_failed_readonly_root() {
    echo "[read-only checkpoint root -> write_failed fallback manifest]"
    if [ "$(id -u)" = "0" ]; then echo "  SKIP: running as root, chmod cannot make the root read-only"; return; fi
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    chmod 555 "$NODEODM_CHECKPOINT_ROOT"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local fb="$OUTPUT_DIR/checkpoint-manifest.$UUID_A.json"
    assert_file "$fb" "fallback manifest under the job output dir"
    assert_eq "write_failed" "$(jget "$fb" state)" "state write_failed"
    assert_eq "false" "$(jget "$fb" dataComplete)" "dataComplete false"
    assert_eq "2" "$(jget "$fb" schemaVersion)" "fallback manifest is schema 2"
    assert_eq "checkpoint_write_failed" "$(checkpoint_evaluate_resumable "$fb" "$T/none" "" "")" "rule: reason checkpoint_write_failed"
    assert_no_file "$(ckdir "$UUID_A")" "nothing created under the read-only root"
    chmod 755 "$NODEODM_CHECKPOINT_ROOT"
}

test_inconsistent_exit() {
    echo "[exit while the task is still running -> inconsistent, no copy]"
    new_env; make_task "$UUID_A" 20; TASK_UUID="$UUID_A"
    checkpoint_sync exit "$UUID_A" >/dev/null 2>&1
    local ck m
    ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    assert_eq "inconsistent" "$(jget "$m" state)" "state inconsistent"
    assert_eq "false" "$(jget "$m" dataComplete)" "dataComplete false"
    assert_no_file "$ck/data" "no data copied for a non-terminal task"
    assert_eq "state_inconsistent" "$(checkpoint_evaluate_resumable "$m" "$ck/data/$UUID_A" "" "$ck/data/.complete")" "rule: state_inconsistent"
}

test_split_manifest() {
    echo "[split primaries: split + submodelCloudsPresent]"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    local d="$NODEODM_RUNTIME_DIR/data/$UUID_A/submodels"
    mkdir -p "$d/submodel_0000/odm_filterpoints" "$d/submodel_0001"
    echo ply > "$d/submodel_0000/odm_filterpoints/point_cloud.ply"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local m; m="$(ckdir "$UUID_A")/manifest.json"
    assert_eq "true" "$(jget "$m" split)" "split true"
    assert_eq "false" "$(jget "$m" submodelCloudsPresent)" "submodelCloudsPresent false when one cloud is missing"
    assert_eq "true" "$(jget "$m" submodelClouds.submodel_0000)" "per-submodel entry true"
    assert_eq "false" "$(jget "$m" submodelClouds.submodel_0001)" "per-submodel entry false"
    mkdir -p "$d/submodel_0001/odm_filterpoints"; echo ply > "$d/submodel_0001/odm_filterpoints/point_cloud.ply"
    CHECKPOINT_SYNCING=0; rm -rf "$(ckdir "$UUID_A")"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    assert_eq "true" "$(jget "$m" submodelCloudsPresent)" "submodelCloudsPresent true when every submodel has a cloud"
}

test_resume_as_uuid() {
    echo "[resume as a different uuid; checkpoint is read-only]"
    new_env; make_task "$UUID_A" 40 symlink; TASK_UUID="$UUID_A"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m
    ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    assert_eq "symlink" "$(jget "$m" imagesKind)" "imagesKind symlink"
    assert_no_file "$ck/data/$UUID_A/images" "import-path symlink not copied"
    local before_m before_c
    before_m=$(cksum < "$m"); before_c=$(cksum < "$ck/data/.complete")

    # a new job: fresh runtime directory
    rm -rf "$NODEODM_RUNTIME_DIR"; mkdir -p "$NODEODM_RUNTIME_DIR/data"
    TASK_UUID=""; CHECKPOINT_SYNCING=0
    NODEODM_RESUME_TASK_UUID="$UUID_A"; NODEODM_RESUME_AS_UUID="$UUID_B"
    NODEODM_RESUME_OPTIONS_JSON='[{"name":"rerun-from","value":"odm_dem"},{"name":"dem-resolution","value":"2"}]'
    checkpoint_restore_if_requested >/dev/null 2>&1
    assert_eq "0" "$?" "restore succeeds"
    assert_file "$NODEODM_RUNTIME_DIR/data/$UUID_B/log.json" "data/<new>/ exists"
    assert_no_file "$NODEODM_RUNTIME_DIR/data/$UUID_A" "data/<old>/ renamed away"
    local tj="$NODEODM_RUNTIME_DIR/data/tasks.json"
    assert_eq "$UUID_B" "$(jget "$tj" 0.uuid)" "tasks.json uuid rewritten"
    assert_eq "1" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$tj")" "tasks.json still one task"
    assert_eq '{"code": 10}' "$(jget "$tj" 0.status)" "task re-queued (status 10)"
    assert_eq "dem-resolution=2" "$(jget "$tj" 0.options.1.name)=$(jget "$tj" 0.options.1.value)" "options replaced from NODEODM_RESUME_OPTIONS_JSON"
    assert_eq "$NODEODM_CORRAL_MEDIA_ROOT/project/images" "$(readlink "$NODEODM_RUNTIME_DIR/data/$UUID_B/images")" "images symlink recreated from importPath"
    assert_no_file "$NODEODM_RUNTIME_DIR/data/.complete" ".complete not copied into runtime"
    assert_eq "checkpoint" "$NODEODM_RESUME_MODE" "resume mode checkpoint"
    assert_eq "" "$NODEODM_RESUME_FALLBACK_REASON" "no fallback reason"
    assert_eq "$before_m" "$(cksum < "$m")" "checkpoint manifest unchanged"
    assert_eq "$before_c" "$(cksum < "$ck/data/.complete")" "checkpoint .complete unchanged"
    # the resumed task's own checkpoint lands under the new uuid, not the source checkpoint
    TASK_UUID="$UUID_B"; STATUS_RESPONSE=""
    python3 - "$tj" <<'PY'
import json, sys
tasks = json.load(open(sys.argv[1])); tasks[0]["status"] = {"code": 40}; json.dump(tasks, open(sys.argv[1], "w"))
PY
    checkpoint_sync terminal "$UUID_B" >/dev/null 2>&1
    assert_eq "synced" "$(jget "$(ckdir "$UUID_B")/manifest.json" state)" "new uuid gets its own synced checkpoint"
    assert_eq "$before_m" "$(cksum < "$m")" "source checkpoint still unchanged after the resumed task's sync"
}

# restore must refuse with <reason>: mutate runs in the case's checkpoint dir ($1 = ck dir, $2 = uuid)
expect_refusal() {  # reason rerun-from mutate-python-or-shell-cmd
    local want="$1" rerun="$2" mutation="$3"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m; ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    case "$mutation" in
        py:*) jmutate "$m" "${mutation#py:}" ;;
        sh:*) (cd "$ck" && eval "${mutation#sh:}") ;;
    esac
    local before; before=$(cat "$m" 2>/dev/null | cksum)
    rm -rf "$NODEODM_RUNTIME_DIR"; mkdir -p "$NODEODM_RUNTIME_DIR/data"
    TASK_UUID=""; CHECKPOINT_SYNCING=0
    NODEODM_RESUME_TASK_UUID="$UUID_A"; NODEODM_RESUME_MODE=""; NODEODM_RESUME_FALLBACK_REASON=""
    NODEODM_RESUME_OPTIONS_JSON="[{\"name\":\"rerun-from\",\"value\":\"$rerun\"}]"
    checkpoint_restore_if_requested >/dev/null 2>&1
    local rc=$?
    assert_eq "1" "$rc" "refused: $want (exit status 1)"
    assert_eq "$want" "$NODEODM_RESUME_FALLBACK_REASON" "refused: reason code $want"
    assert_eq "failed" "$NODEODM_RESUME_MODE" "refused: $want sets resume mode failed"
    assert_no_file "$NODEODM_RUNTIME_DIR/data/$UUID_A" "refused: $want restores nothing"
    # a failed resume never writes to the source checkpoint (exit trap included)
    checkpoint_sync exit "$UUID_A" >/dev/null 2>&1
    assert_eq "$before" "$(cat "$m" 2>/dev/null | cksum)" "refused: $want leaves the checkpoint manifest alone"
}

test_rule_refusals() {
    echo "[resumability rule refusals]"
    expect_refusal partial odm_dem 'py:m["state"]="partial"'
    expect_refusal checkpoint_write_failed odm_dem 'py:m["state"]="write_failed"'
    expect_refusal state_manifest_only odm_dem 'py:m["state"]="manifest_only"'
    expect_refusal data_incomplete odm_dem 'py:m["dataComplete"]=False'
    expect_refusal data_incomplete odm_dem 'sh:rm -f data/.complete'
    expect_refusal expired odm_dem 'py:m["expiresAt"]=1'
    expect_refusal optimize_disk_space odm_dem 'py:m["optimizeDiskSpace"]=True'
    expect_refusal engine_version_mismatch odm_dem 'py:m["engineVersion"]="3.4.9"'
    expect_refusal engine_version_unknown odm_dem 'py:m["engineVersion"]=None'
    expect_refusal image_digest_mismatch odm_dem 'py:m["imageDigest"]="sha256:other"'
    expect_refusal schema_unsupported odm_dem 'py:m["schemaVersion"]=1'
    expect_refusal missing_stage_dir:odm_filterpoints odm_meshing 'sh:rm -rf data/*/odm_filterpoints'
    expect_refusal missing_stage_dir:odm_georeferencing odm_dem 'sh:rm -rf data/*/odm_georeferencing'
    expect_refusal missing_stage_dir:odm_texturing odm_orthophoto 'sh:rm -rf data/*/odm_texturing'
    expect_refusal missing_stage_dir:submodels merge 'sh:true'
    expect_refusal manifest_missing odm_dem 'sh:rm -f manifest.json'
    expect_refusal manifest_unreadable odm_dem 'sh:echo "{not json" > manifest.json'
    expect_refusal checkpoint_missing odm_dem 'sh:cd .. && rm -rf "$(basename "$OLDPWD")"'

    echo "[rule: a satisfiable rerun-from passes; missing worker identity refuses]"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    local ck m; ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    NODEODM_RESUME_TASK_UUID="$UUID_A"
    NODEODM_RESUME_OPTIONS_JSON='[{"name":"rerun-from","value":"odm_dem,odm_orthophoto"}]'
    assert_eq "ok" "$(checkpoint_evaluate_resumable "$m" "$ck/data/$UUID_A" "" "$ck/data/.complete")" "odm_dem,odm_orthophoto prerequisites present"
    CHECKPOINT_ENGINE_VERSION=""; NODEODM_ENGINE_VERSION=""
    assert_eq "engine_version_unknown" "$(checkpoint_evaluate_resumable "$m" "$ck/data/$UUID_A" "" "$ck/data/.complete")" "worker engine version unknown -> refuse"

    echo "[cold start: disabled by default, allowed only when enabled with an import path]"
    new_env
    NODEODM_RESUME_TASK_UUID="$UUID_A"
    checkpoint_restore_if_requested >/dev/null 2>&1; local rc=$?
    assert_eq "1" "$rc" "missing checkpoint with cold start disabled fails"
    assert_eq "checkpoint_missing" "$NODEODM_RESUME_FALLBACK_REASON" "reason checkpoint_missing"
    NODEODM_RESUME_ALLOW_COLD_START=1; NODEODM_RESUME_IMPORT_PATH="$T/case/media"; NODEODM_RESUME_MODE=""
    checkpoint_restore_if_requested >/dev/null 2>&1; rc=$?
    assert_eq "0" "$rc" "cold start allowed when enabled with an import path"
    assert_eq "cold-start" "$NODEODM_RESUME_MODE" "mode cold-start"
}

make_ckdir() {  # name bytes updatedAt expiresAt
    mkdir -p "$NODEODM_CHECKPOINT_ROOT/$1/data"
    echo x > "$NODEODM_CHECKPOINT_ROOT/$1/data/f"
    printf '{"schemaVersion":2,"uuid":"%s","state":"synced","checkpointBytes":%s,"updatedAt":%s,"expiresAt":%s}\n' \
        "$1" "$2" "$3" "$4" > "$NODEODM_CHECKPOINT_ROOT/$1/manifest.json"
}

test_prune() {
    echo "[prune: expiry, stale data.tmp, size cap, locks]"
    new_env
    local now; now=$(date +%s)
    make_ckdir expired 10 $((now - 1000)) $((now - 10))
    make_ckdir fresh 10 "$now" $((now + 99999))
    make_ckdir tmpstale 10 "$now" $((now + 99999))
    mkdir -p "$NODEODM_CHECKPOINT_ROOT/tmpstale/data.tmp/x"; touch -t 202001010000 "$NODEODM_CHECKPOINT_ROOT/tmpstale/data.tmp"
    make_ckdir tmpfresh 10 "$now" $((now + 99999))
    mkdir -p "$NODEODM_CHECKPOINT_ROOT/tmpfresh/data.tmp/x"
    make_ckdir lockedexpired 10 $((now - 1000)) $((now - 10))
    printf '{"writerJobUuid":"j","createdAt":%s,"pid":%s,"host":"%s"}\n' "$now" "$$" "$(hostname)" > "$NODEODM_CHECKPOINT_ROOT/lockedexpired/lock"
    make_ckdir staleexpired 10 $((now - 1000)) $((now - 10))
    printf '{"writerJobUuid":"j","createdAt":%s,"pid":999999,"host":"%s"}\n' "$now" "$(hostname)" > "$NODEODM_CHECKPOINT_ROOT/staleexpired/lock"
    make_ckdir resumesrc 10 $((now - 1000)) $((now - 10))
    NODEODM_RESUME_TASK_UUID="resumesrc"
    NODEODM_CHECKPOINT_MAX_BYTES=0
    checkpoint_prune >/dev/null 2>&1
    assert_no_file "$NODEODM_CHECKPOINT_ROOT/expired" "expired checkpoint removed"
    assert_file "$NODEODM_CHECKPOINT_ROOT/fresh" "fresh checkpoint kept"
    assert_no_file "$NODEODM_CHECKPOINT_ROOT/tmpstale/data.tmp" "data.tmp older than a day removed"
    assert_file "$NODEODM_CHECKPOINT_ROOT/tmpstale/manifest.json" "its checkpoint is kept"
    assert_file "$NODEODM_CHECKPOINT_ROOT/tmpfresh/data.tmp" "recent data.tmp kept"
    assert_file "$NODEODM_CHECKPOINT_ROOT/lockedexpired" "expired but live-locked checkpoint kept"
    assert_no_file "$NODEODM_CHECKPOINT_ROOT/staleexpired" "expired checkpoint with a stale lock removed"
    assert_file "$NODEODM_CHECKPOINT_ROOT/resumesrc" "resume source of this job kept"

    echo "[prune: size cap removes oldest first]"
    new_env
    now=$(date +%s)
    make_ckdir old 600 $((now - 300)) $((now + 99999))
    make_ckdir mid 600 $((now - 200)) $((now + 99999))
    make_ckdir new 600 $((now - 100)) $((now + 99999))
    NODEODM_CHECKPOINT_MAX_BYTES=1000
    checkpoint_prune >/dev/null 2>&1
    assert_no_file "$NODEODM_CHECKPOINT_ROOT/old" "oldest removed"
    assert_no_file "$NODEODM_CHECKPOINT_ROOT/mid" "next oldest removed (1800 > 1000, 1200 > 1000)"
    assert_file "$NODEODM_CHECKPOINT_ROOT/new" "newest kept (600 <= 1000)"
    NODEODM_CHECKPOINT_MAX_BYTES=0
    make_ckdir another 600 "$now" $((now + 99999))
    checkpoint_prune >/dev/null 2>&1
    assert_file "$NODEODM_CHECKPOINT_ROOT/another" "cap 0 disables the size cap"
}

test_lock() {
    echo "[lock: live lock blocks the copy, stale lock is taken over]"
    new_env; make_task "$UUID_A" 40; TASK_UUID="$UUID_A"
    local ck m; ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"; mkdir -p "$ck"
    printf '{"writerJobUuid":"other","createdAt":%s,"pid":%s,"host":"%s"}\n' "$(date +%s)" "$$" "$(hostname)" > "$ck/lock"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    assert_no_file "$ck/data" "no copy while another live writer holds the lock"
    assert_file "$ck/lock" "foreign lock left in place"
    # lock older than the job max run time (240 min + 10 min)
    printf '{"writerJobUuid":"other","createdAt":%s,"pid":%s,"host":"%s"}\n' "$(( $(date +%s) - 20000 ))" "$$" "$(hostname)" > "$ck/lock"
    CHECKPOINT_SYNCING=0
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    assert_eq "synced" "$(jget "$m" state)" "lock older than max run time is stale -> copy proceeds"
    assert_no_file "$ck/lock" "lock released after the copy"
    # dead writer on this host
    rm -rf "$ck"; mkdir -p "$ck"; CHECKPOINT_SYNCING=0
    printf '{"writerJobUuid":"other","createdAt":%s,"pid":999999,"host":"%s"}\n' "$(date +%s)" "$(hostname)" > "$ck/lock"
    checkpoint_sync terminal "$UUID_A" >/dev/null 2>&1
    assert_eq "synced" "$(jget "$m" state)" "lock of a dead process on this host is stale"
}

test_task_watch() {
    echo "[status watch: terminal checkpoint before the monitor reports]"
    new_env; make_task "$UUID_A" 40
    # Fake NodeODX: RUNNING for the first two polls, then COMPLETED.
    cat > "$T/case/bin/curl" <<EOS
#!/bin/bash
n=\$(cat "$T/case/curl.count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$T/case/curl.count"
if [ \$n -le 2 ]; then code=20; else code=40; fi
echo '{"uuid":"$UUID_A","name":"test","status":{"code":'\$code'},"options":[{"name":"dem-resolution","value":5}],"imagesCount":2}'
EOS
    chmod +x "$T/case/bin/curl"; PATH="$T/case/bin:$ORIG_PATH"
    NODEODM_TASK_WATCH_INTERVAL_SECONDS=1
    NODEODM_PORT=3999
    TASK_UUID="$UUID_A"
    task_watch_start "$UUID_A" >/dev/null 2>&1
    task_watch_wait "$UUID_A" >/dev/null 2>&1
    local ck m; ck=$(ckdir "$UUID_A"); m="$ck/manifest.json"
    assert_eq "synced" "$(jget "$m" state)" "synced manifest exists when task_watch_wait returns"
    assert_file "$ck/data/.complete" "terminal copy done"
    assert_eq "40" "$(jget "$m" taskStatus)" "taskStatus from the watcher's /info response"
    assert_file "$(task_watch_done_file "$UUID_A")" "done file written"
    assert_eq "3" "$(cat "$T/case/curl.count")" "polled until the first terminal status, then stopped"
    CHECKPOINT_SYNCING=0
    local before; before=$(cksum < "$m")
    checkpoint_sync exit "$UUID_A" >/dev/null 2>&1
    assert_eq "$before" "$(cksum < "$m")" "exit trap sync is a no-op afterwards"
    task_watch_stop
}

test_defaults
test_atomic_copy
test_no_double_write
test_partial_on_killed_copy
test_previous_data_survives_killed_copy
test_write_failed_readonly_root
test_inconsistent_exit
test_split_manifest
test_resume_as_uuid
test_rule_refusals
test_prune
test_lock
test_task_watch

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
