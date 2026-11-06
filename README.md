# NodeODM-LS6

**NodeODM Tapis Application for TACC Lonestar6**

NodeODM-LS6 is a specialized Tapis application configuration for running NodeODM photogrammetry processing on TACC's Lonestar6 supercomputer. It provides a seamless integration between OpenDroneMap's NodeODM and high-performance computing resources through the Tapis API framework.

## Features

- **HPC Integration**: Native deployment on TACC Lonestar6 vm-small queue
- **Automatic Scaling**: Resource allocation based on dataset size
- **Web Interface**: Real-time access to NodeODM during processing
- **Split-Merge Support**: Distributed processing for large datasets
- **TAP Integration**: Secure web access via TACC Access Portal

## Requirements

- **TACC Account**: Valid account with Lonestar6 access
- **Tapis Authentication**: JWT token for API access
- **Allocation**: Active TACC allocation for compute resources
- **ClusterODM-Tapis**: For distributed processing coordination

## Architecture Overview

The application consists of three main components:

1. **`app.json`**: Tapis application definition with resource mappings and configuration
2. **`tapisjob_app.sh`**: Main execution script that runs NodeODM on Lonestar6
3. **`nodeodm.sh`**: Standalone SLURM script for direct NodeODM deployment

### Application Configuration

The `app.json` file defines resource allocation tiers based on dataset size:

```json
{
  "id": "nodeodm-ls62",
  "version": "1.0.14",
  "runtime": "ZIP",
  "containerImage": "tapis://ptdatax.project.PTDATAX-225/NodeODM/nodeodm-ls6.zip"
}
```

### Resource Mapping

Automatic resource selection based on image count:

| Images | Nodes | Cores/Node | Memory | Time Limit |
|--------|-------|------------|--------|------------|
| ≤50    | 1     | 16         | 30GB   | 2 hours    |
| ≤150   | 1     | 16         | 30GB   | 4 hours    |
| ≤300   | 2     | 16         | 30GB   | 6 hours    |
| ≤600   | 3     | 16         | 30GB   | 10 hours   |
| ≤1000  | 4     | 16         | 30GB   | 16 hours   |
| ≤1500  | 6     | 16         | 30GB   | 20 hours   |

### Processing Pipeline

The `tapisjob_app.sh` script handles the complete processing workflow:

1. **Environment Setup**: Load TACC modules and setup containerization
2. **TAP Integration**: Generate authentication tokens for web access
3. **NodeODM Launch**: Start NodeODM via Apptainer container
4. **Task Processing**: Create and monitor photogrammetry tasks
5. **Result Archival**: Package and transfer outputs to storage

## Usage

### Via ClusterODM-Tapis (Recommended)

NodeODM-LS6 is primarily designed to work with ClusterODM-Tapis for distributed processing:

1. **Configure ClusterODM-Tapis** with your Tapis credentials
2. **Submit tasks via WebODM** - datasets ≥50 images automatically trigger HPC processing
3. **Monitor progress** via ClusterODM web interface
4. **Download results** from WebODM once processing completes

### Direct Tapis Submission

For advanced users, you can submit jobs directly via Tapis API:

```bash
# Submit job with image inputs
curl -X POST "https://portals.tapis.io/v3/jobs" \
  -H "X-Tapis-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d @job_definition.json
```

### Local Development

For testing and development on Lonestar6:

```bash
# Direct SLURM submission
sbatch nodeodm.sh 4 3001
# Args: max_concurrency port

# Multi-instance cluster
sbatch single-node-multi-nodeodm.sh /path/to/images ProjectName 4
# Args: images_directory project_name nodeodm_count
```

## Configuration

### Resource Allocation

The application automatically selects resources based on input dataset size. Configuration is defined in the `imageSizeMapping` section of `app.json`.

### Network Access

NodeODM instances are accessible via:

- **TAP Portal**: Automatic web interface via TACC Access Portal
- **SSH Tunneling**: Manual port forwarding for local access
- **ClusterODM**: Load-balanced access through cluster coordinator

### File Management

- **Input**: Images uploaded via Tapis file staging
- **Processing**: Temporary storage on Lonestar6 scratch filesystem
- **Output**: Results archived to TACC cloud storage or specified location

### Terminal checkpoint and resume

When a task reaches COMPLETED, FAILED or CANCELED the worker can copy the task directory once to
Corral so a later job can resume it (for example `rerun-from odm_dem` with a new DEM resolution).
Design: `docs/design/2026-11-06-task-versions-and-resumable-reruns.md` (part A).

How it works:

1. `lib/task_watch.sh` starts a background status watch when the worker picks up a task. It polls
   the local NodeODX `/task/<uuid>/info` (port `NODEODM_PORT`, token = job owner) and, on the first
   terminal status, runs `checkpoint_sync terminal <uuid>`. The monitor loop waits for it
   (`task_watch_wait`) before reporting the task onward; the EXIT trap's `checkpoint_sync exit`
   is a safety net and does nothing when a `synced` manifest from this job exists.
2. The copy is atomic: `<root>/<uuid>/data.tmp/` is filled by `rsync` (never `--delete` into a live
   directory), `.complete` (byte and file counts) is written, then `data.tmp` is renamed to `data`
   and the manifest is written. A kill mid-copy leaves `data.tmp` and a `partial` manifest.
3. `<root>/<uuid>/manifest.json` is schema 2: `schemaVersion`, `state` (`synced`, `partial`,
   `write_failed`, `manifest_only`, `inconsistent`), `dataComplete`, `checkpointBytes`,
   `fileCount`, `engine`, `engineVersion`, `imageDigest` (+ `imageDigestKind`: `digest` when the
   image is pinned by `@sha256:` or `NODEODM_IMAGE_DIGEST`, otherwise `reference`, the image tag
   string), `stagesCompleted`, `optionsHash`, `optimizeDiskSpace`, `split`,
   `submodelCloudsPresent`, `nodeCount` (LS6 nodes in the job: `SLURM_JOB_NUM_NODES`, else `NODEODM_JOB_COUNT`, else 1), `imagesKind`, `taskStatus`, `writerJobUuid`, `expiresAt`. If the
   checkpoint root cannot be written, a `write_failed` manifest is written to
   `$OUTPUT_DIR/checkpoint-manifest.<uuid>.json` instead. `updatedAt` and `expiresAt` are epoch seconds.
4. Resume (`NODEODM_RESUME_TASK_UUID`) applies the resumability rule before restoring: manifest
   `synced` and `dataComplete`, `.complete` present, not expired, no `optimizeDiskSpace`, same
   engine version and image digest as this worker, and every stage directory the requested
   `rerun-from` needs (`odm_meshing` needs `odm_filterpoints/`; `odm_dem` needs
   `odm_filterpoints/` and `odm_georeferencing/`; `odm_orthophoto` needs `odm_texturing*`;
   `merge` needs `submodels/`). On refusal the worker registers with `resumeMode=failed` and
   `resumeFallbackReason=<code>` (for example `partial`, `expired`, `engine_version_mismatch`,
   `missing_stage_dir:odm_filterpoints`) and exits without starting NodeODM. The source checkpoint
   is only ever read.
5. At job start `checkpoint_prune` removes expired checkpoints, `data.tmp` older than a day, and
   oldest checkpoints beyond `NODEODM_CHECKPOINT_MAX_BYTES` (skipping live-locked directories and
   this job's resume source). A `<uuid>/lock` file (`writerJobUuid`, `createdAt`, `pid`, `host`)
   is held during a copy; it is stale when older than the job's max run time + 10 minutes or when
   its process no longer exists on the same host.

| Variable | Default | Meaning |
|---|---|---|
| `NODEODM_CHECKPOINT_ROOT` | `/corral/utexas/BCS26030/webodm/media/.nodeodm-checkpoints` | Checkpoint root |
| `NODEODM_CHECKPOINT_COPY_DATA_ON_TERMINAL` | `0` | `1` copies the task directory at the terminal state (ops turn this on after staging acceptance); `0` writes manifests only |
| `NODEODM_CHECKPOINT_EXCLUDE` | `*.zip odm_orthophoto/*.mbtiles *_tiles/ entwine_pointcloud/ potree_pointcloud/` | Whitespace-separated rsync exclude patterns. `3d_tiles/` is always kept; `images/` is excluded only when it is an import-path symlink (recreated on resume) |
| `NODEODM_CHECKPOINT_MAX_BYTES` | `1099511627776` (1 TB) | Root size cap enforced by the job-start prune; `0` disables |
| `NODEODM_CHECKPOINT_RETENTION_SECONDS` | `604800` | Manifest `expiresAt` offset |
| `NODEODM_CHECKPOINT_INTERVAL_SECONDS` | `900` | Periodic manifest-only sync interval |
| `NODEODM_RESUME_TASK_UUID` | empty | Task to resume from its checkpoint |
| `NODEODM_RESUME_AS_UUID` | empty | After restore, rename `data/<old>` to `data/<new>` and rewrite the uuid in `tasks.json` |
| `NODEODM_RESUME_ALLOW_COLD_START` | `0` | `1` allows a cold start from `NODEODM_RESUME_IMPORT_PATH` when the restore fails; default is to fail the resume |
| `NODEODM_IMAGE_DIGEST` | empty | Overrides the recorded/compared image digest. Pin `NODEODM_IMAGE` by `@sha256:` for the digest guard to be meaningful |
| `NODEODM_ENGINE_VERSION` | empty | Overrides engine version detection (`/info` `engineVersion`, else `/code/VERSION` in the SIF) |
| `NODEODM_TASK_WATCH_INTERVAL_SECONDS` | `5` | Status watch poll interval |
| `NODEODM_TASK_WATCH_WAIT_SECONDS` | `3600` | Max time the monitor loop waits for the terminal checkpoint |
| `NODEODM_RESUME_FAILED_GRACE_SECONDS` | `30` | Pause after registering a failed resume, before exit/deregistration |

`NODEODM_CHECKPOINT_COPY_DATA` (the old in-place `rsync --delete` copy) is deprecated and ignored.

Tests: `bash tests/test_checkpoint.sh` (no LS6 required; needs bash, python3, rsync).

## Integration with Distributed Processing

NodeODM-LS6 works seamlessly with the broader ODM-Suite ecosystem:

1. **WebODM**: User interface for task creation and management
2. **ClusterODM-Tapis**: Coordination and load balancing
3. **NodeODM-LS6**: HPC processing backend (this application)

### Split-Merge Processing

For large datasets, the system automatically:

1. **Splits** images into overlapping submodels
2. **Distributes** processing across multiple NodeODM instances
3. **Merges** results with photogrammetric accuracy
4. **Delivers** final outputs via WebODM interface

## Monitoring and Debugging

### Log Files
- **SLURM logs**: Standard SLURM output files
- **NodeODM logs**: Application-specific processing logs
- **TAP logs**: Web access and tunneling logs

### Common Issues
- **Memory limits**: Increase `memoryMB` for large datasets
- **Time limits**: Adjust `maxJobTime` for complex processing
- **Network access**: Verify TAP configuration for web interface

## Support

For issues and questions:
- **TACC Help Desk**: help@tacc.utexas.edu
- **ODM Community**: [OpenDroneMap GitHub](https://github.com/OpenDroneMap)
- **Documentation**: See `CLAUDE.md` for detailed technical information

## Authors

**William Mobley** - wmobley@tacc.utexas.edu
*Research Associate, Texas Advanced Computing Center*
