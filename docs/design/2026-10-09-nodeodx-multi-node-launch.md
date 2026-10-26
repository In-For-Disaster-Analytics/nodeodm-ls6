# NodeODX multi-node Tapis launch

Status: Implemented

## Objective

Make the registered `nodeodx-ls6` Tapis ZIP runtime start one NodeODX service
per allocated LS6 host, so a job configured with four nodes produces four
independently reachable and registered NodeODX nodes.

## User need

**Primary user:** WebODM/ClusterODX operator running NodeODX on LS6.

**Secondary users:** WebODM users submitting reconstruction tasks through the
registered processing cluster.

**Job-to-be-done:** Request a multi-node Tapis allocation and have every
allocated host participate in the NodeODX processing pool without manually
starting or registering child services.

**Current pain:** The current registered `nodeodx-ls6:0.1.1` package starts one
NodeODX process on the primary host even when Tapis allocates multiple hosts,
so only one node appears in ClusterODM/ClusterODX.

**Definition of success:** A two-node acceptance job registers two nodes; a
four-node job registers four nodes; each node has a unique TAP endpoint, port,
Scratch work root, and registration identity; a one-node job continues to work
as before.

## Current code/system summary

The registered app is `nodeodx-ls6:0.1.1` and packages
`nodeodx-ls6/nodeodx/tapisjob_app.sh`. That launcher starts a single NodeODX
process, opens one pair of TAP reverse tunnels, and sends one registration to
ClusterODM.

The repository also contains an older NodeODM-style launcher with a
multi-node `srun` helper, but that helper is not included in the registered
NodeODX package and is not reused by this change.

The first LS6 acceptance run reached the compute node and pulled
`webodm/nodeodx:latest`, but NodeODX exited before health-checking because the
image/source overlay startup path reported a Bash-only `source` invocation and
the overlaid runtime could not resolve the production dependency `multer`.

## Proposed design

1. Add a multi-node dispatch phase to the actual NodeODX launcher.
2. On the primary process, enumerate `SLURM_NODELIST` with
   `scontrol show hostnames`.
3. For each host, launch one child through `srun --nodes=1 --ntasks=1 -w`.
4. Pass each child a stable child index, host index, and unique local service
   port. Children skip the dispatch phase and execute the existing startup
   path.
5. Derive a host-specific work root beneath the job Scratch root so SIFs,
   runtime trees, logs, and NodeODX data cannot race across hosts.
6. Let each child obtain its own TAP port, establish its own reverse tunnels,
   and register its own endpoint. Registration includes child/host metadata
   where supported, while retaining the existing `admin` role contract.
7. The parent waits for every child and returns failure if any child fails.
8. Keep the existing single-node path when the scheduler exposes one host or
   when the launcher is run outside Slurm.
9. Make startup fail closed with diagnostics if the extracted runtime does not
   resolve the required production dependency tree. Dependencies must come
   from the validated image/runtime artifact; the LS6 job must never install
   npm packages at runtime.
10. Invoke the image's Node runtime without relying on a POSIX `sh` wrapper
    that uses Bash-only syntax, while preserving the container environment.
11. Pin the runtime image or record its immutable digest before acceptance so
    the source and dependency tree cannot drift under the `latest` tag.
12. Bump the app version to `1.0.15`, rebuild the ZIP, upload it to the existing
   Corral URI, update/register the app, and run a two-node acceptance test
   before testing four nodes.

## Files likely affected

- `nodeodx/tapisjob_app.sh` — multi-node dispatcher and child environment.
- `nodeodx/app.json` — app version and user-facing multi-node description.
- `nodeodx/README-ZIP.md` — launch behavior and acceptance checks.
- `nodeodx/build-zip.sh` — only if packaging or validation needs adjustment.
- `nodeodx/PINNED-SOURCE` — if the accepted runtime image/source pin changes.
- `nodeodx/docs/design/2026-10-09-nodeodx-multi-node-launch.md` — this design
  and final implementation notes.

## API/schema changes

No NodeODX HTTP API or database schema changes are planned. The existing
ClusterODM registration endpoint is reused with additional optional node
metadata.

## Data flow

Tapis allocates N LS6 hosts → primary launcher enumerates hosts → one child
launcher starts per host → each child pulls/reuses the OCI SIF and starts
NodeODX on a unique local port → each child creates TAP reverse tunnels → each
child registers its public endpoint with ClusterODM → ClusterODM distributes
NodeODX-compatible work across the registered nodes.

## Risks and tradeoffs

- TAP must provide a distinct externally reachable port for each child. The
  acceptance test must verify that ports do not collide.
- Each child has its own SIF and runtime path, which increases Scratch usage
  but prevents unsafe concurrent writes.
- Child registration failure should fail the Tapis job when
  `NODEODX_REQUIRE_REGISTRATION=1`; this is safer than silently running with a
  partial cluster.
- NodeODX services share the configured import-path roots. Those roots must be
  visible at the same absolute paths on every host.

## Alternatives considered

- Reuse the older NodeODM multi-node launcher: rejected because it runs a
  different service contract and is not the package registered as NodeODX.
- Start one NodeODX process and rely on Tapis `nodeCount`: rejected because
  allocation does not automatically create service processes or registrations.
- Run one Tapis job per node: deferred because it loses a single job lifecycle
  and coordinated registration identity.

## Test plan

- Run shell syntax checks and JSON validation.
- Verify the ZIP contains the actual NodeODX launcher and app version.
- Verify the launcher uses a shell-compatible runtime path and checks that
  `require.resolve('multer')` succeeds before starting the service.
- Run a two-node Tapis acceptance job and confirm two registration records,
  distinct public ports, `/info` health for both nodes, and clean deregistration.
- Run a four-node Tapis acceptance job and confirm four registrations.
- Run a one-node regression job and confirm the original behavior remains.
- Confirm shared `import_path` processing still works through the registered
  multi-node pool.

## Documentation plan

Document node-count behavior, the one-admin-style registration contract,
per-node TAP endpoints, Scratch layout, expected log markers, and the
two-node/four-node acceptance procedure in `README-ZIP.md`.

## Rollout/rollback plan

Build and upload the new ZIP under the existing Corral path, register version
`1.0.15`, and test it explicitly. Keep `1.0.14` available for rollback. If
multi-node registration or TAP port allocation fails, revert job submissions to
`0.1.1` and do not remove the prior ZIP.

## Open questions

- Does the LS6 TAP environment allocate unique reverse-proxy ports when
  `tap_get_port` is called concurrently by child processes in one Tapis job?
- Does the deployed ClusterODM instance preserve the optional child metadata?

## Decisions

- The actual registered NodeODX package is the implementation target.
- OpenSplat remains a separate post-reconstruction Tapis job.
- The first acceptance sequence is two nodes, then four nodes, then one-node
  regression.
- The host enumeration uses portable `while read` logic instead of Bash
  `mapfile`, so local syntax/runtime checks also work on macOS Bash 3.2.

## User feedback / decisions

- User requested that the NodeODX startup be fixed and deployed, followed by
  testing.
- User approved implementation of the startup fix with "ok fix it" after the
  first LS6 run exposed the shell/dependency failure.

## Decisions from startup failure review

- Treat the shell-wrapper failure and missing `multer` as separate defects.
- Do not make registry access and `npm install` a normal production startup
  dependency; validate the image-provided dependency tree instead.
- Add an explicit dependency-resolution check so future image drift produces a
  clear error before NodeODX starts.

## Implementation notes

- The launcher now re-execs itself with Bash when invoked through `sh`, uses a
  real Node binary from the image instead of the `/usr/bin/node` shell wrapper,
  and uses POSIX `.` in the bundled Node wrapper scripts.
- Startup validates the complete production dependency manifest. If the
  image is incomplete, it fails before starting NodeODX and directs the
  operator to rebuild and republish the image.
- Local validation passed for shell syntax, Node syntax, JSON, ZIP integrity,
  ZIP/source parity, and whitespace. An Apptainer/SIF smoke test remains
  pending on LS6 because Apptainer is unavailable in the development workspace.
