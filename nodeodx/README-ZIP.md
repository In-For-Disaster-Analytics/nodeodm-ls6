# NodeODX LS6 Tapis app

This package launches the pinned NodeODX source on a TACC LS6 allocation. It
uses the published `ghcr.io/in-for-disaster-analytics/nodeodx` OCI image pulled into a per-job Apptainer
SIF on `$SCRATCH` by default. Set `NODEODX_SIF_PATH` to a preseeded Scratch
cache only after making that cache immutable and concurrency-safe. The image
supplies the Node runtime, dependencies, and the ODX
engine at `/code`; the package overlays the NodeODX source so the shared
filesystem `import_path` extension under test is the code that runs.

At startup the launcher resolves the image's real Node binary instead of the
image's shell wrapper, verifies that the complete production dependency tree
(including `multer`) is available, and exits with a clear log message if the
image is incomplete. Production dependencies are installed and verified during
the container image build; the Tapis job never runs package installation on
LS6.

When Tapis allocates more than one LS6 host, the launcher uses `srun` to start
one NodeODX child per host. Each child receives a unique local port, TAP
reverse-proxy endpoint, Scratch work root, and ClusterODM registration
metadata. The first host registers as `admin` and receives the parent task;
remaining hosts register as ordinary `worker` nodes for split-merge dispatch,
matching `nodeodm-ls6`. Each worker has a distinct registration UUID and worker
ID; host indices do not change the parent Tapis job index/count. A one-host
allocation follows the normal admin service path. All sibling services share
one Slurm allocation and terminate when that allocation ends.

Each NodeODX instance defaults to 64 simultaneous processing tasks, advertised
as `maxParallelTasks` by `/info`. Set `NODEODX_PARALLEL_QUEUE_PROCESSING` to a
positive integer to override this capacity. This is independent of
`max_concurrency`, which limits threads within each task (12 by default).
For example, 64 tasks at 12 threads each can request roughly 768 threads on
one host; choose these settings together for the allocation's CPU and memory.
The new default applies to jobs started with the updated launcher.

## Why the reverse proxy is part of the app

LS6 compute nodes are not directly reachable from ClusterODM or WebODM. When
TAP functions are available, the launcher:

1. starts NodeODX on the compute node's private port;
2. obtains the TAP login-node port;
3. opens reverse SSH tunnels on `login1` and `login2` to the compute node;
4. registers `ls6.tacc.utexas.edu:<login-port>` with the configured cluster;
5. keeps the tunnels alive until the Tapis job exits.

No direct compute-node hostname is registered. Registration is diagnostic and
retryable by default: if TAP setup or ClusterODM registration fails, the
launcher records the HTTP/curl result and keeps NodeODX alive so the Tapis job
can be inspected and the registration path can be tested manually. Set
`NODEODX_REQUIRE_REGISTRATION=1` in a deployment that must fail fast when a
worker cannot register.

Registration diagnostics are written beneath the job work root. The launcher
records the HTTP status, curl status, endpoint, response headers, and a redacted
response summary in `registration-response.txt`, `registration-headers.txt`,
and the launch log. On registration failure it also writes the exact JSON body
to `registration-payload.json` with mode `600` and logs a copy/pasteable curl
command. Export `TAPIS_ACCESS_TOKEN` in the job shell before running that
command; the JWT itself is never printed. The ClusterODX reverse proxy must route `/webhook` to the
admin web port (normally 10000); routing it to the main proxy port (normally
3000) returns the main proxy's `Cannot handle /webhook...` 404.

The Tapis app exposes only two user parameters: `max_concurrency` and
`nodeodx_port`. The image, import roots, registration policy, cleanup policy,
and ClusterODM endpoint are launcher defaults rather than user-editable app
inputs.

## Shared filesystem inputs

NodeODX accepts a form field named `import_path`. The path must be under the
job working directory or the current user's `$SCRATCH` root, and the launcher
binds those roots at the same absolute paths inside Apptainer. Corral roots
must be added explicitly in a later runtime configuration. This avoids copying
large image sets over HTTP. All runtime
state, SIFs, task data, and logs are placed under Scratch.

The app does not build ODX on macOS, use Docker on LS6, or use `sudo`. The
separately validated ODX SIF is an engine acceptance artifact; this first
NodeODX app uses the combined upstream NodeODX image because NodeODX invokes
`/code/run.sh` inside its own container. A separate ODX-SIF execution adapter
is a later change if the combined image is not the desired production pin.

## Build locally

```bash
SKIP_UPLOAD=1 ./build-zip.sh
unzip -t nodeodx-ls6.zip
```

The default upload target is the BCS26030 Corral allocation. The upload must
run with effective group `G-829114`; the archive ACL grants read access to the
legacy group `G-820466`:

```text
tapis://cloud.data/corral-repl/utexas/BCS26030/NodeODX/1.0.18/nodeodx-ls6.zip
```

The build script never registers or updates the Tapis app. Register app
version `1.0.18` only after the ZIP and source/image pins have been reviewed.
ClusterODX injects the request-scoped `TAPIS_ACCESS_TOKEN` into each submitted
job; the launcher sends it as the bearer credential for both worker
registration and shutdown deregistration, without logging the token. Do not
use the historical `${_tapisAccessToken}` app-definition macro: current Tapis
leaves it literal. Launch files are not archived so the bearer token is not
retained in the job archive.

## LS6 acceptance checks

Run the Tapis job on `vm-small`, first with two nodes and then with four nodes, then
verify from a reachable client:

```bash
curl -fsS 'http://ls6.tacc.utexas.edu:<login-port>/info?token=<NodeODX-token>'
```

The job log should contain one `[MULTI] Launching NodeODX` line per allocated
host. ClusterODM should show one registered node per TAP endpoint. The app
definition keeps `nodeCount` at one by default; choose the requested node count
in the Tapis job configuration when testing multi-node behavior.

Submit a small `import_path` task using a directory under Scratch and verify
the NodeODX task UUID, status transitions, ODX artifacts, and cleanup. The
acceptance record must include the NodeODX commit, ODX image/SIF digest, SIF
path, Tapis job UUID, reverse-proxy port, and the absolute input path.

## Shared submodel input (opt-in)

`NODEODX_SHARED_SUBMODEL_V1=1` enables shared-image submodel submissions only
with a rebuilt ODX-derived image containing `opendm.remote.SHARED_SUBMODEL_V1`.
The launcher imports that module in the container before setting the engine
capability marker. An old image fails startup when opt-in is requested; the
deployed launcher now enables shared mode and pins the validated shared runtime
image recorded in `PINNED-SOURCE`. Set `NODEODX_SHARED_SUBMODEL_V1=0` to
disable it for rollback. The original 1.0.18 image tag remains unchanged.

The launcher maps `/var/www/data` to each child's host `runtime/data`, and
passes the allocation root and Tapis job UUID into worker configuration.
ClusterODX verifies the submitting token owns the parent task, then selects a
capable worker from the same allocation. Workers independently validate the
allocation identity and parent subtree. Seeds are read from the admin runtime;
images can resolve through the allocation or explicit `NODEODX_SHARED_IMAGE_ROOTS`
(colon-separated canonical roots, for example the authorized Corral media root).
The launcher defaults this explicit root to `/corral/utexas/BCS26030/webodm/media`.
These roots are separate from ordinary `importPathRoots`: mounting Scratch or
allowing ordinary image imports does not authorize other allocations for v1.

Shared mode transfers image and seed path references rather than image bodies.
Workers validate/copy the seed and copy source images into their own project
before publishing the task. This avoids HTTP image transfers while preserving
independent mutable task files; it still consumes shared-filesystem I/O and
worker disk space. Result archives continue through the normal download path.
The engine validates freshly downloaded stage outputs before marking a submodel
complete. Older deployments retain the upload protocol; rejected shared paths
or authorization do not silently downgrade to HTTP.

Local checks (run from the indicated repositories):

```bash
# nodeodx-ls6
python3 tools/test_nodeodx_capacity.py
python3 tools/test_nodeodx_multinode.py
# Requires the engine's pinned pyodm==1.5.12 and access to sibling checkouts:
python3 tools/test_shared_submodel_protocol.py
# NodeODX
python3 -m unittest discover -s tests/shared_submodel
node tests/shared_submodel/test_capability.js
node tests/shared_submodel/test_cancellation.js
# ODX
python3 -m unittest tests.test_shared_submodel
# ClusterODX
npm test
```

Rollout requires building the updated ODX image, building NodeODX with that
image as `FROM_REPO`, recording immutable image digests, and smoke-testing the
actual engine import. Update the launcher image pin and rebuild the ZIP only
after those checks. Publishing, updating Tapis, and running a small two-node
acceptance job are separate deployment actions. A ZIP built against the old
engine alone cannot enable this protocol.

### Shared-secret registration

The launcher accepts `NODEODX_REGISTRATION_SECRET`. When nonempty, it sends the
secret in registration and deregistration JSON and omits the Tapis bearer,
including when `TAPIS_ACCESS_TOKEN` is present but expired. The secret is added
only to the streamed HTTP request, not the saved `registration-payload.json`.
The printed manual retry command reads the secret from the environment. Do not paste secret values into logs.

ClusterODX can inject this environment variable when ASR
`worker.allowSharedSecretPrimaryRegistration` is `true` and a registration
secret is configured. This is a trusted-cluster opt-in: job owners receive a
cluster-wide credential. Primary registration must exactly match a pending
Tapis job with recorded ownership. This mode does not refresh the Tapis token
or repair expired-token cancellation. See `ClusterODX/docs/tapis.md` for setup.

The 2026-10-28 runtime image corrects `/code/run.sh` execute permissions. Image
builds now verify `test -x /code/run.sh` and invoke `/code/run.sh --help` directly
before publishing, matching NodeODX process startup.

Shared seed snapshots support file links and seed-directory root links only when
their targets resolve within the same parent task. Archive members contain
regular-file bytes; escaping links, broken links, nested directory links and
special files are rejected. The 2026-10-28 image build validates 12 engine tests
and 8 worker fixtures, plus direct `/code/run.sh --help` execution.
