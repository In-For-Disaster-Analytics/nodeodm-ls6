# NodeODX image publishing

Status: Implemented

## Objective

Make the NodeODX container release reproducible through GitHub Actions so the
LS6 Tapis ZIP consumes an image built from the same NodeODX source tree and
with the complete production dependency tree included.

## User need

NodeODX jobs must start from a published image that already contains the
production dependencies, including `multer`. LS6 jobs must not install npm
packages at runtime.

## Current code/system summary

The NodeODX source is nested at `nodeodx/nodeodx-source` inside the
`nodeodx-ls6` repository. Existing workflows use repository-root Docker
context and `./Dockerfile`, so they do not target that nested source tree.
The Tapis launcher uses `webodm/nodeodx:1.0.18` and fails closed when the image
does not provide the production dependency tree.

## Proposed design

- Build the CPU image from `nodeodx/nodeodx-source/Dockerfile` with that
  directory as the Docker build context.
- Build the GPU image from the corresponding GPU Dockerfile and context.
- Publish only from `v*` release tags or an explicit manual workflow run.
- Publish the versioned image tag and `latest` for CPU; publish the versioned
  GPU tag and `gpu` for GPU.
- Run a PR build against the nested context and verify Node, npm, and
  `require.resolve('multer')` inside the built image.
- Keep the Tapis ZIP packaging separate; its upload remains an explicit
  release step after the image is published.

## Files affected

- `nodeodx/nodeodx-source/.github/workflows/publish-docker.yml`
- `nodeodx/nodeodx-source/.github/workflows/publish-docker-gpu.yml`
- `nodeodx/nodeodx-source/.github/workflows/test-build-prs.yml`
- `nodeodx/nodeodx-source/Dockerfile`
- `nodeodx/nodeodx-source/Dockerfile.gpu`

## Test plan

- Validate YAML and shell syntax locally.
- Confirm the Docker build context and Dockerfile paths point to the nested
  NodeODX source.
- Confirm the Docker build verifies all production dependencies and `multer`
  using the installed NVM Node runtime.
- Confirm the PR workflow runs the same image smoke test.
- After the release tag is pushed, verify the published image digest and pull
  a fresh SIF on LS6 before running the Tapis acceptance job.

## Rollout/rollback plan

Publish `v1.0.18` and keep the previous NodeODX image/app version available.
If the new image fails the LS6 smoke test, point the Tapis app back to the
previous version and do not remove the new image until diagnosis is complete.

## Decisions

- The CPU release is the image consumed by the current LS6 app.
- Release publishing is tag/manual only to avoid publishing every source push.
- Runtime npm installation is not permitted; dependency installation belongs
  to the container build.

## User feedback / decisions

- User requested that NodeODX be built in GitHub like NodeODM.
- User confirmed implementation should proceed.

## Implementation notes

- CPU and GPU publishing workflows now use the nested NodeODX Docker context.
- Release publishing is triggered by `v*` tags and uses current Docker Actions.
- The CPU release targets `linux/amd64`, matching LS6.
- PR builds verify the installed Node/npm runtime and `multer` before running
  the powercycle smoke test.
- The ZIP was rebuilt locally and validated, but has not been uploaded and no
  GitHub push has been performed in this session.
