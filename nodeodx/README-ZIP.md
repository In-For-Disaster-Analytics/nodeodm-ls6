# NodeODX LS6 Tapis app

This package launches the pinned NodeODX source on a TACC LS6 allocation. It
uses the official `webodm/nodeodx` OCI image pulled into a per-job Apptainer
SIF on `$SCRATCH` by default. Set `NODEODX_SIF_PATH` to a preseeded Scratch
cache only after making that cache immutable and concurrency-safe. The image
supplies the Node runtime, dependencies, and the ODX
engine at `/code`; the package overlays the NodeODX source so the shared
filesystem `import_path` extension under test is the code that runs.

## Why the reverse proxy is part of the app

LS6 compute nodes are not directly reachable from ClusterODM or WebODM. When
TAP functions are available, the launcher:

1. starts NodeODX on the compute node's private port;
2. obtains the TAP login-node port;
3. opens reverse SSH tunnels on `login1` and `login2` to the compute node;
4. registers `ls6.tacc.utexas.edu:<login-port>` with the configured cluster;
5. keeps the tunnels alive until the Tapis job exits.

No direct compute-node hostname is registered. If the TAP setup or cluster
registration fails and `NODEODX_REQUIRE_REGISTRATION=1`, the job exits rather
than presenting an unusable node.

## Shared filesystem inputs

NodeODX accepts a form field named `import_path`. The path must be under
`NODEODX_IMPORT_PATH_ROOTS`, and the launcher binds the configured roots at the
same absolute paths inside Apptainer. On LS6 the job working directory and the
current user's `$SCRATCH` root are allowed by default; Corral roots must be
added explicitly. This avoids copying large image sets over HTTP. All runtime
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
tapis://ptdatax.project.BCS26030/NodeODX/nodeodx-ls6.zip
```

The build script never registers or updates the Tapis app. Register the app
only after the ZIP and source/image pins have been reviewed.

## LS6 acceptance checks

Run the Tapis job on `vm-small` with `NODEODX_REQUIRE_REGISTRATION=1`, then
verify from a reachable client:

```bash
curl -fsS 'http://ls6.tacc.utexas.edu:<login-port>/info?token=<NodeODX-token>'
```

Submit a small `import_path` task using a directory under Scratch and verify
the NodeODX task UUID, status transitions, ODX artifacts, and cleanup. The
acceptance record must include the NodeODX commit, ODX image/SIF digest, SIF
path, Tapis job UUID, reverse-proxy port, and the absolute input path.
