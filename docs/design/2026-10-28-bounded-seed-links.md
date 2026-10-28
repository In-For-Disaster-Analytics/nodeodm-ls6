# Bounded shared-submodel seed links

## Status
Implemented — reviewed, tested and approved for deployment on 2026-10-28.

## Objective
Support legitimate linked seed inputs created during ODX splitting.

## User need
Remote reconstruction must accept camera model and support files linked from their parent task.

## Current code/system summary
The owned NodeODX runtime source overlay rejects every seed file symlink using O_NOFOLLOW. A real split run failed on opensfm/camera_models.json after a local submodel succeeded. Snapshot archives hash copied bytes and receivers validate regular archive members. Source hashes are pinned in SOURCE.json.

## Proposed design
Resolve seed source links only within the canonical parent task root (the UUID directory above submodels). Validate relative seed member paths. Open the canonical task root once and traverse resolved components with dir_fd and O_NOFOLLOW to reject a symlink swapped after resolution. Copy only regular-file bytes into archives under original member names. Reject escapes, loops, special files, and symlink directories; support directory seed roots only if resolved inside the parent and enumerate without following nested directory links. Preserve partial-archive cleanup and receiver checks. Update owned source overlay provenance hashes.

## Files likely affected
nodeodx/odx-source/opendm/shared_submodel.py; nodeodx/odx-source/tests/test_shared_submodel.py; nodeodx/odx-source/SOURCE.json; nodeodx/tapisjob_app.sh; nodeodx/nodeodx-ls6.zip; this spec.

## API/schema changes
None; archives still contain regular file bytes and hashes.

## Data flow
Submodel seed path resolves to bounded parent-task data, safely opened bytes are copied and hashed into an immutable attempt archive, existing authenticated submission and worker validation continue unchanged.

## Risks and tradeoffs
Do not follow arbitrary links. Resolved component traversal must fail closed on races; parent task is the intentional trust boundary. Existing directory symlink enumeration requires care to preserve original archive-relative names.

## Alternatives considered
Removing O_NOFOLLOW without boundary checks rejected. Copying every parent seed during split duplicates inputs and does not fix the snapshot contract. Upstream ODX edits deferred; use existing owned source-overlay release path.

## Test plan
Valid parent camera-file link and support directory link archive exact bytes; external and cross-task links rejected; loops and special files rejected; replaced resolved components rejected; partial archive removed. Run engine and protocol tests, build direct launcher smoke and runtime fixtures, launcher tests, ZIP integrity/hash checks.

## Documentation plan
Record fix, provenance, image digest, verification and rollout here and in package README.

## Rollout/rollback plan
Push owned upgrade branch, build shared image using existing workflow, pin successful digest, back up remote ZIP, upload new package atomically and verify hash. Existing jobs untouched. Roll back via backup ZIP/image pin. No production processing job submission.

## Open questions
None blocking; review required to confirm bounded link handling.

## Decisions
- Security/design review accepted bounded resolution with anchored nofollow opens, safe member names, nonblocking regular-file checks and explicit adversarial tests. Concurrent ancestor-directory renames by the trusted same-user task owner remain outside this symlink threat model.
- 2026-10-28: User approved fix and runtime deployment. Preserve the parent-task boundary and immutable archive contract.

- 2026-10-28: QA accepted implementation; added NUL-member rejection and fail-closed os.walk error handling. Owned overlay hashes verified. Local tests: 12 engine, 6 launcher, 4 capacity passed. GitHub build 40697177566 passed direct run.sh execution, 12 engine tests and 8 worker fixtures. Published image digest sha256:be2990c8fb3484145a2bc690993703517854f7767ca50620dd5791cf556187b9. Existing upstream ODX checkout unchanged; overlay manifest records modified hashes.
- Rollout uses existing app 1.0.18 package URI; prior ZIP retained as nodeodx-ls6.zip.pre-seed-links-20261028. Existing jobs untouched; no live photogrammetry task submitted during validation.

## User feedback / decisions
User: “ok do it” after bounded-link fix and rebuild/deployment were described.
