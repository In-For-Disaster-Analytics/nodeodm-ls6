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
  "version": "1.0.8-clusterodm-integration",
  "runtime": "ZIP",
  "runtimeOptions": ["SINGULARITY_RUN"],
  "containerImage": "https://github.com/wmobley/nodeodm-ls6/releases/download/v1.0.8/nodeodm-ls6-v1.0.8.zip"
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
