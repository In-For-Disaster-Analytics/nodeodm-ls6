# Shared-filesystem split/submodel submission for ODX and NodeODX

Status: Implemented

## Objective

Allow ODX split/submodel tasks to submit shared image references and seed inputs through ClusterODX to NodeODX, avoiding HTTP image uploads when both endpoints support the contract. Preserve the established HTTP submission and asset retrieval behavior for incompatible deployments. This is a proposal only; the shared-filesystem direction and requirements are approved; written design details, implementation and deployment approvals are pending.

## User need

**Primary user:** The LS6 WebODM/ClusterODX operator.

**Secondary users:** WebODM users waiting for split reconstructions.

**Job-to-be-done:** Run split reconstructions using allocated worker hosts without retransmitting images already visible on shared storage.

**Current pain:** Reported live state: admin port 60279 is busy, worker 60280 is idle, and remote submission for a 12-submodel run remains at approximately 9% upload progress. Admin/worker roles have already been corrected. That correction does not change ODX's upload protocol or make container-local paths valid on other hosts.

**Definition of success:** A compatible two-host run reconstructs remote submodels without HTTP image bodies, restores merge inputs into the submitting submodel, and leaves parent inputs unchanged; an incompatible worker still runs through the established upload path. Production acceptance requires separate approval.

## Current code/system summary

- ODX/opendm/remote.py creates seed.zip from task-specific seed files and marker files, adds images plus optional gcp_list.txt/geo.txt, calls pyodm Node.create_task with skip_post_processing=True and outputs, then waits and downloads assets into self.project_path before task cleanup.
- Reconstruction seeds include opensfm/exif, camera_models.json, reference_lla.json and the reconstruction-stop marker. Toolchain seeds include reconstruction/tracks/camera/reference files and empty feature/match/exif markers. These layouts differ intentionally.
- nodeodx-ls6/nodeodx/nodeodx-source/libs/taskNew.js treats import_path as an image directory: it links that directory at the new task's images path and copies support files. Its shared-import branch bypasses the normal seed.zip extraction branch. Passing a whole project creates the wrong images layout; placing seed files beside images does not reconstruct the project.
- ClusterODX/libs/taskNew.js parses import_path, translates it for the chosen worker, and forwards options, outputs, skipPostProcessing and uploaded files. ClusterODX/libs/tapisWorker.js handles deferred Tapis submissions separately and skips uploaded files when path import is selected. New fields must survive both routes and the pending-task persistence/retry route.
- nodeodx-ls6/nodeodx/tapisjob_app.sh binds each child WORK_ROOT/runtime at /var/www and identity-binds Scratch and allowed import roots. Therefore /var/www/data on the submitting host means that child's actual WORK_ROOT/runtime/data, not another child's /var/www/data. Mount visibility and authorization are separate checks.
- nodeodx-ls6/odm-patches/remote.py is a legacy NodeODM reference with path discovery, flattened views and output relocation workarounds. Do not copy it wholesale; its fallback/no-op task behavior is unsuitable as the new contract.
- ODX/tests/test_remote.py covers executor queue/retry behavior. ClusterODX/test/test-tapis-local-handoff.js and test-tapis-observability.js cover deferred submissions. NodeODX/tests contains processing fixtures.
- Read nodeodx-ls6/.wolf/OPENWOLF.md and anatomy.md; anatomy predates the current NodeODX layout, so current code takes precedence. .wolf remains read-only. The required DSO architecture path /Volumes/Macintosh HD - Data/Github/DSO-Architecture/docs/Codex-context/how-to-use.md is unavailable (ENOENT). Record this documentation limitation and verify deployment facts against current code and runtime configuration; do not infer a new approval gate from the missing checkout.

## Proposed design

### Versioned capability and mode selection

Scope covers remote ReconstructionTask and ToolchainTask, ordinary import/upload compatibility, current static worker dispatch and existing Tapis autoscaling/deferred dispatch. No scheduler or authentication-system redesign.

Add an optional versioned capability, shared_submodel_v1, to NodeODX /info and the cluster's capability response. It means shared image import plus safe seed reconstruction, preserved task flags, and normal asset retrieval; existing import_path support alone is insufficient. ClusterODX advertises it only when it can route a request to a capable eligible worker and preserve the complete contract. A selected worker must be checked again before forwarding or retrying.

Use an explicit request field shared_submodel_version=1, the existing import_path pointing directly to the submodel images directory, and a new seed_path pointing to an immutable per-attempt seed archive on shared storage. Keep outputs and skipPostProcessing in their existing formats. No whole-project import or shared mutable working directory is introduced. Recommend NODEODX_SHARED_SUBMODEL_V1=0 by default and explicit opt-in after acceptance; seed limits: 100,000 entries, 8 GiB compressed, 32 GiB expanded, enforced at inspection and extraction.

ODX chooses this mode only when enabled, the coordinator advertises v1, and an explicit mount mapping resolves the task's image and seed paths. Otherwise it uses its existing create_task upload call. Missing/unsupported capability may select HTTP only before any submission; LS6 shared-path mapping/visibility errors fail directly; invalid paths, authorization failures, malformed seeds and processing failures must surface as errors. Never silently bypass a rejection by retrying with broader paths. A timeout after acceptance requires UUID reconciliation before any new task to avoid duplicate processing.

### Explicit path mapping and isolated reconstruction

The launcher exports an explicit engine data-root mapping: container /var/www/data maps to this child's canonical host RUNTIME_DIR/data. ODX translates only descendants of that root, preserving the relative task/submodel suffix; already canonical identity-mounted paths remain unchanged after validation. No glob-based search across arbitrary sibling runtimes. Each participating worker must see the translated source paths through configured mounts.

ODX snapshots the task's existing seed_files and seed_touch_files into a unique per-attempt seed archive on shared storage and retains it through worker initialization and retries. Include a v1 manifest identifying reconstruction/toolchain stage, attempt ID, seed file hashes, marker paths and requested outputs; validate stage/options/marker agreement. Allowed reconstruction entries are opensfm/exif/**, opensfm/camera_models.json, opensfm/reference_lla.json and opensfm/split_merge_stop_at_reconstruction.txt. Allowed toolchain entries are opensfm/camera_models.json, opensfm/reference_lla.json, opensfm/reconstruction.json, opensfm/tracks.csv and opensfm/{features,matches,exif}/empty. Both stages may include project-root gcp_list.txt and geo.txt. Copy project-root support files into the seed; preserve existing worker GCP/geo/align placement. Explicit seed support files take precedence over identical image-directory support files; reject conflicting contents rather than selecting silently. NodeODX validates the v1 fields, creates a fresh task-owned staging directory, copies the seed into an exclusive task-owned file, then inspects and extracts that same immutable copy into that directory. It materializes an image view at staging/images from validated shared source images. Copy support files into task-owned locations using existing GCP/geo/align handling. All mutable OpenSfM and downstream outputs belong to the new worker task. Publish the initialized task atomically only after validation succeeds.

Keep ordinary import_path image-directory behavior unchanged. Do not place a seed archive inside a symlinked shared images directory or extract into parent inputs. Validate nested image symlinks against authorized canonical roots; source images must be enforced read-only by a mount or immutable snapshot, otherwise copy them into task-owned storage with safe-open/no-follow handling. Do not rely on a writable symlink plus a prior realpath check: inputs must remain stable through use. Where an engine stage mutates images or support data, use task-owned copies.

### Validation and authorization

Require existing task authentication for the new mode. Preserve trusted authenticated job ownership from ClusterODX to NodeODX through the existing service identity/registration context; client-supplied job IDs or path fields never grant access. Persist that trusted context with pending requests and reauthorize/revalidate every retry and node switch. Resolve canonical roots, image entries and seed paths; use component-aware containment, reject traversal, null bytes, non-directory image roots, non-regular seed files, escaping symlinks and special files. The capability must be disabled unless the server can restrict sources to the authenticated submitting job/task's configured source scope. A broad Scratch mount or root allowlist alone is not a grant to read other jobs. Use allocation BASE_WORK_ROOT (nodeodx_ SLURM job root shared by sibling hosts) as the v1 source scope, narrower than ordinary broad Scratch imports. Seed paths must be under that allocation root/current parent-task data subtree; canonical image targets may also use explicitly configured existing Corral image roots. ClusterODX derives the parent route/job identity server-side and matches worker registration tapisJobUuid; exclude cross-allocation workers unless an explicit trusted scope is configured. Verify this existing ownership mapping during implementation and disable v1 when the trusted context is unavailable. No broader authentication redesign is in scope.

Validate archives before extraction: no absolute or parent-relative entries, normalized duplicate/case or separator collisions and file/directory conflicts, symlinks/hardlinks/special files, or overwrites of images, task metadata or runtime controls. Enforce entry-count and expanded-byte limits; extract only allowed seed artifact paths needed by the requested submodel stage. Safe-open and task-owned copies or enforced immutable mounts must close the validation/use race; if the runtime cannot enforce this, disable v1. Fail closed before scheduling on validation failure, cleaning only task-owned staging data.

### Forwarding, results and lifecycle

Use one normalized submission descriptor across immediate init/upload/commit, deferred submitPendingTask, autoscaler pending storage, retry and node-switch paths. Preserve version, translated image/seed references, options, outputs, skipPostProcessing, name, date and webhook. Never drop a seed because path import is present. Choose eligible workers by capability and source visibility; reject incompatible retries or renegotiate before acceptance. Apply the splitmerge-disabled guard to v1 requests as well as uploaded seed.zip.

Keep real pyodm Task lifecycle semantics (info, output, wait_for_completion, download_assets, remove), using the supported request helper or a focused adapter that returns the genuine Task object. No partial SimpleTask wrapper and no no-op download. Shared submission changes inputs only: NodeODX packages requested outputs normally and ODX downloads/extracts them into the original submodel directory before reporting success. Retrieve into a fresh per-attempt result staging directory and validate there before restoring the submodel, so stale previous outputs cannot satisfy success. Reconstruction requires reconstruction.json, tracks.csv and cameras.json plus the requested feature/match directories. Toolchain validation follows existing handle_result and enabled output options: require the cutline/cut/feathered orthophoto products when orthophoto generation is enabled, and required DEM/report/georeferencing products only when their producing options/stages are enabled. Preserve relative paths and optional-product semantics from existing output handling; add the toolchain completion marker only after successful retrieval, validation and restoration. Never scan arbitrary worker task folders to recover missing results. Clean remote tasks only after retrieval/validation; release per-attempt seeds after initialization/retries no longer need them, including failure/cancel paths. Retain seed ownership per accepted task UUID/attempt; on ambiguous submission reconcile that UUID before retry, keep seeds until initialization acknowledgment or terminal cleanup, and cancel/remove the accepted task before deleting its seed. Retried submissions must not reuse a mutable seed filename. Cleanup must never follow image links or remove parent data.

## Files likely affected

- ODX/opendm/remote.py; ODX/tests/test_remote.py; ODX/Dockerfile and existing image build configuration as required.
- NodeODX/libs/taskNew.js, NodeODX/index.js (/info), NodeODX/config.js, NodeODX/libs/ziputils.js and their bundled nodeodx-ls6/nodeodx/nodeodx-source counterparts; in particular nodeodx-ls6/nodeodx/nodeodx-source/libs/taskNew.js; existing info/config/zip utilities and tests supporting the contract. Keep source and packaged runtime parity explicit.
- ClusterODX/libs/taskNew.js, libs/tapisWorker.js, libs/tapisRegistration.js, libs/asrProvider.js and the existing Tapis autoscaler pending descriptor/provider, capability/info and node selection code; ClusterODX/test/ handoff tests.
- nodeodx-ls6/nodeodx/tapisjob_app.sh, README-ZIP.md, PINNED-SOURCE, packaging/app metadata and launcher tests where required.
- NodeODX/Dockerfile and supported CPU/GPU image build workflows; this design document.

## API/schema changes

Optional /info capability shared_submodel_v1; optional multipart fields shared_submodel_version and seed_path. Existing import_path remains an image directory. Existing upload routes and response UUID/task lifecycle stay intact. Extend the cluster's internal pending submission descriptor with these optional fields and all existing output/processing flags; older descriptors remain readable. Use the names and limits recommended above; review concerns should revise this document before approval.

## Data flow

ODX submodel → snapshot seed archive and translate image/seed paths using the submitting runtime mapping → authenticated v1 submission → ClusterODX validates/preserves descriptor and chooses compatible worker → NodeODX validates source scope, reconstructs isolated project and queues processing → worker packages outputs → ODX retrieves assets into its original submodel → validate merge inputs → normal merge and cleanup. Without compatible v1 support, submission starts with existing HTTP images plus seed.zip.

## Risks and tradeoffs

- Existing shared import ignores seed extraction: extending it without separate v1 handling could appear successful while silently losing reconstruction state.
- Scratch is broadly mounted today; filesystem reachability cannot substitute for tenant/job authorization. Resolving that scope is required before enabling v1.
- Symlinked submodel images may point into parent images; lexical containment alone fails. Canonical validation and read-only input behavior are required, with copy cost for mutable inputs.
- Seeds may be large; shared staging removes network uploads but consumes shared I/O and storage. Retaining standard output download limits the initial change while still transferring result bytes.
- Cluster immediate and deferred routes differ; incomplete persistence/forwarding can lose flags after autoscaling or restart.
- Live image code reportedly resides at /code/modules/remote.py while this checkout uses opendm.remote. Build provenance and imported-module checks must establish the actual runtime contract; a ZIP-only change cannot fix the engine.

## Alternatives considered

- Existing HTTP image upload: retain as compatibility baseline; it is the observed stalled path and does not meet the shared-input goal on capable deployments.
- Pass the whole parent/submodel project as import_path: reject because the current API expects an image directory and worker writes would race shared parent state.
- Copy the legacy odm-patches/remote.py wholesale: reject because it mixes NodeODM-specific discovery, flattened mutable views and fallback result handling with a different ODX runtime.
- Share outputs directly back into the parent tree: defer; the existing download contract provides an explicit completion boundary and avoids shared mutable results.
- Replace only the launcher ZIP: reject as insufficient; the engine remote submission code is built into the ODX-derived image.

## Test plan

1. ODX unit tests with real filesystem fixtures and mocked HTTP/pyodm: v1 request contains zero image bodies, correct canonical paths, seed members/markers and preserved options/outputs; unsupported capability uses existing upload; auth/validation errors do not downgrade; ambiguous acceptance does not duplicate tasks.
2. NodeODX integration fixtures for reconstruction and toolchain: seed artifacts land under worker project/opensfm, images remain directly under images, support files are correct, and parent input hashes are unchanged after processing/cleanup. Cover existing ordinary import_path and uploaded seed.zip regressions; verify project-root GCP/geo parity and conflicting support-file rejection.
3. Security negative fixtures: traversal, prefix collisions, nested escaping symlinks, replaced seed, special files, archive traversal/links/conflicts/expansion limits, unauthorized cross-job sources and cleanup containment.
4. Cluster HTTP-stub tests for immediate and deferred handoff, pending persistence/reload, node switching, retries/cancel: all fields survive, unsupported workers are excluded, zero image upload in v1, splitmerge-disabled rejects v1, tokens are absent from diagnostics.
5. Result tests: requested stage outputs restored to the original submodel; missing required merge inputs fail without completion marker; optional absent outputs follow existing semantics; failed/incomplete retrieval over a submodel containing old outputs must fail and never create a completion marker; failure output remains retrievable and cleanup occurs in the right order.
6. Launcher mapping/package parity checks plus pinned-image smoke test: import the actual remote module, report version/hash, confirm capability and source mount visibility on two children. Capability eligibility additionally requires a verified engine contract version, actual imported remote-module hash/path, pinned engine image digest and matching launcher/package version for each supported CPU/GPU variant; a server-only capability is insufficient. No production execution is authorized by this document.
Local acceptance: all targeted ODX, NodeODX, ClusterODX, launcher and package checks pass with no external services or jobs required; fixture checks assert zero image bodies, correct state, and unchanged parent hashes.
7. After deployment approval: small two-host split job exercising reconstruction and toolchain, remote worker activity, zero image-upload bytes, successful merge, then mixed-version fallback and one-host regression. Do not restart the current long-running job for this proposal.

## Documentation plan

Update NodeODX task API docs, ClusterODX shared-path/pending-task behavior and nodeodx-ls6 README-ZIP with capability negotiation, path mapping, authorization, seed lifetime, output retrieval and fallback diagnostics. Locate DSO architecture docs and update relevant service, environment-variable and auth pages for final accepted changes. Do not guess service URLs, ports or auth patterns.

## Rollout/rollback plan

Proposed sequence, requiring approval: finish reviews and unresolved auth/runtime decisions; implement and run local tests; build/pin an ODX-derived NodeODX engine image including the actual imported remote module, updating supported CPU/GPU variants as applicable; package matching NodeODX source/launcher; deploy capability-aware servers first with v1 disabled; smoke-test pinned runtime; enable opt-in submission for a small approved acceptance job. A mixed deployment must retain upload compatibility. Roll back by disabling v1 for new tasks and selecting the prior pinned image/package; retain seed/task state until active attempts finish. Image publication, Tapis changes and execution remain external-write gates.

## Open questions

- No additional user requirement questions. Design approval is pending review of the concrete contract above.
- Implementation verification must establish actual deployed remote module/import path, PyODM authenticated request primitive returning a genuine Task, supported CPU/GPU image variants, exact existing pending-provider file, and option-dependent merge products before enabling capability. These are engineering checks, not user naming decisions.
- Required DSO docs were unavailable at the mandated path; locate them before final implementation/deployment verification.

## Decisions

### 2026-10-27 — Investigate shared submission separately from node roles

- **Decision:** Produce a proposal only; preserve the corrected admin/worker role contract.
- **Reason:** The current remote executor still uploads images; worker eligibility alone does not repair path translation or seed reconstruction.
- **Alternatives rejected:** Reopening the role fix as the explanation for the observed upload stall.
- **User feedback:** User approved the shared-filesystem fix direction and requirements with “yes”; written design approval is pending.
- **Impact on implementation:** No source changes, jobs, image publication or deployment in this phase.

### 2026-10-27 — Proposed v1 contract for review

- **Decision:** Recommend explicit capability negotiation, image-directory import plus separate seed reference, isolated worker state and standard asset retrieval.
- **Reason:** These preserve existing task semantics while addressing the observed image upload and seed-handling gaps.
- **Alternatives rejected:** Whole-project linking, wholesale legacy patch copying and no-op result downloads.
- **User feedback:** Pending; this entry records the proposal, not user approval.
- **Impact on implementation:** Requires coordinated ODX, NodeODX, ClusterODX and packaged-runtime changes after approval.

## User feedback / decisions

- The user approved the shared-filesystem fix direction and requirements. This written design and its implementation plan are presented for approval. Image publication, deployment and job execution require separate explicit approval.

### 2026-10-27 — Implementation approved

- **Decision:** Implement the reviewed shared-submodel contract locally.
- **User feedback:** User approved with “ok do it”.
- **Impact:** ODX engine, NodeODX initializer, ClusterODX forwarding and launcher
  are implementation targets. Existing unrelated working-tree changes are preserved.
  Publication, deployment and production job execution remain separate gates.

### 2026-10-27 — Implementation validation and bounded rollout

- **Decision:** Implement capability-gated shared inputs with explicit image and
  seed references. Preserve normal uploads and result downloads.
- **Implementation:** ODX snapshots seeds and restores fresh verified outputs;
  NodeODX copies source inputs into isolated staging and uses a cancellation
  tombstone plus synchronous publication; ClusterODX verifies parent token and
  allocation, forwards fields and reconciles the same UUID on acknowledgment loss.
- **Deviation:** V1 cannot autoscale across allocations. Deferred descriptors
  preserve fields for compatibility, but new v1 tasks require an existing capable
  same-allocation worker. Ambiguous v1 forwarding does not switch workers.
- **Security review:** V1 image roots are explicitly configured separately from
  broad import mounts. Restore rejects nested destination symlinks. Cancellation
  during copying cannot publish the task afterward.
- **Validation:** Full cluster suite, engine and worker fixtures, launcher tests,
  bundled-source parity, and pinned PyODM 1.5.12 HTTP input/result protocol test.
- **Limit:** Docker Desktop is paused; container image and live two-host LS6
  processing acceptance have not run. Mode remains off by default; no publication,
  commits, deployment or live task changes are authorized/performed for this work.

### 2026-10-27 — Owned repository runtime release

- **User feedback:** User requested deploying NodeODX and fixing disabled shared mode.
- **Decision:** Build a versioned source-overlay runtime in the existing owned
  release repository, without attempting the read-only upstream ODX push.
- **Provenance:** `nodeodx/odx-source/SOURCE.json` records approved ODX commit
  0d8384a6, source hashes, and immutable existing native-tool image digest.
  Native binaries/dependencies are reused; the entire Python engine runtime and
  NodeODX source are replaced together and validated inside the final image.
- **Validation:** Source hashes, actual imported module paths, PyODM 1.5.12,
  engine/worker/cancellation fixtures and Node dependencies are build gates.
- **Limit:** A native photogrammetry two-host acceptance run remains distinct
  from these protocol checks. Existing workers retain their running image.
- **Rollout:** Publish a separate versioned tag, pin its digest in the launcher,
  preserve prior ZIP, enable the guarded mode and explicit Corral image roots,
  upload package only after image checks succeed. No upstream write required.
