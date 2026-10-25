# NodeODX LS6 Tapis app

This package launches the pinned NodeODX source on a TACC LS6 allocation. It
uses the official `webodm/nodeodx` OCI image pulled into a per-job Apptainer
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
metadata. A one-host allocation follows the normal single-service path.

## Why the reverse proxy is part of the app

LS6 compute nodes are not directly reachable from ClusterODM or WebODM. When
TAP functions are available, the launcher:

1. starts NodeODX on the compute node's private port;
2. obtains the TAP login-node port;
3. opens reverse SSH tunnels on `login1` and `login2` to the compute node;
4. registers `ls6.tacc.utexas.edu:<login-port>` with the configured cluster;
5. keeps the tunnels alive until the Tapis job exits.

No direct compute-node hostname is registered. If the TAP setup or cluster
registration fails, the job exits rather than presenting an unusable node.

Registration diagnostics are written beneath the job work root. The launcher
records the HTTP status, curl status, endpoint, response headers, and a redacted
response summary in `registration-response.txt`, `registration-headers.txt`,
and the launch log. The ClusterODM reverse proxy must route `/webhook` to the
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
