# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

NodeODM-LS6 is a specialized Tapis application configuration for running NodeODM photogrammetry processing on TACC's Lonestar6 (LS6) supercomputer. It provides multiple deployment strategies for integrating OpenDroneMap's NodeODM with high-performance computing resources through the Tapis API framework.

## Architecture

This repository contains configurations and scripts for running NodeODM on TACC systems in different modes:

**Core Components:**
- **app.json**: Tapis application definition with ZIP runtime configuration
- **tapisjob_app.sh**: Main execution script for Tapis ZIP runtime jobs
- **nodeodm.sh**: Standalone SLURM script for direct NodeODM deployment
- **Dockerfile**: Simple container definition for legacy container-based deployments

**Deployment Strategies:**

1. **ZIP Runtime (Primary)**: Uses Tapis ZIP runtime to avoid nested container issues
   - Downloads and extracts ZIP package on compute nodes
   - Runs NodeODM via Apptainer with direct access to TACC modules
   - Integrates with TAP (TACC Access Portal) for web access

2. **SLURM Direct**: Traditional HPC batch job submission
   - Direct SLURM job submission for NodeODM instances
   - Support for single-node and multi-node cluster configurations
   - Manual SSH tunneling for external access

3. **Multi-Instance Clusters**: Advanced configurations for distributed processing
   - Multiple NodeODM instances managed by ClusterODM
   - Load balancing across multiple compute resources
   - Automatic resource allocation based on available cores

## Common Commands

### Tapis Application Management
```bash
# Build ZIP package for Tapis deployment
./build-zip.sh

# The ZIP contains:
# - tapisjob_app.sh (main execution script)
# - app.json (Tapis app definition)
# - README-ZIP.md (deployment documentation)
```

### Direct SLURM Deployment
```bash
# Single NodeODM instance
sbatch nodeodm.sh 4 3001
# Args: max_concurrency port

# Multi-NodeODM single node cluster
sbatch single-node-multi-nodeodm.sh /path/to/images ProjectName 4
# Args: images_directory project_name nodeodm_count

# Multi-node cluster with ClusterODM
sbatch cluster-improved.sh /path/to/images ProjectName 50
# Args: images_directory project_name batch_size
```

### Configuration Updates
```bash
# Update Tapis app configuration
# Edit app.json parameters:
# - containerImage: URL to ZIP package
# - maxMinutes: Job timeout
# - coresPerNode, memoryMB: Resource allocation
# - imageSizeMapping: Resource scaling based on image count
```

## Key Configuration Patterns

### Tapis App Definition (app.json)
The application uses ZIP runtime with key settings:
- **Runtime**: "ZIP" (avoids nested container issues)
- **Execution System**: "ls6" (Lonestar6)
- **Archive System**: "cloud.data" (TACC cloud storage)
- **Queue**: "vm-small" (for smaller jobs) or "normal"

### Resource Mapping
The configuration includes `imageSizeMapping` for automatic resource allocation:
```json
{
  "maxImages": 50,
  "nodeCount": 1, 
  "coresPerNode": 2,
  "memoryMB": 8192,
  "maxJobTime": "02:00:00"
}
```

### TAP Integration
Scripts integrate with TACC Access Portal (TAP) for web access:
- **TAP Functions**: Load `/share/doc/slurm/tap_functions`
- **Token Management**: Generate and use TAP tokens for authentication
- **Port Forwarding**: Reverse SSH tunneling for external web access
- **Certificate Management**: TLS certificates for secure sessions

## Deployment Workflows

### ZIP Runtime Deployment
1. **Package Creation**: Build ZIP with application files
2. **Upload**: Deploy ZIP to accessible URL (GitHub releases, etc.)
3. **Configuration**: Update `containerImage` in app.json
4. **Submission**: Submit via Tapis API or web interface
5. **Execution**: Tapis extracts ZIP and runs `tapisjob_app.sh`

### Processing Pipeline (tapisjob_app.sh)
1. **Environment Setup**: Load TACC modules (tacc-apptainer)
2. **TAP Authentication**: Generate tokens and setup certificates
3. **NodeODM Launch**: Start NodeODM container via Apptainer
4. **Port Forwarding**: Setup reverse SSH tunnels for web access
5. **Task Processing**: Create and monitor processing tasks
6. **Result Archival**: Download and archive processing outputs

### Multi-Node Cluster Setup
1. **Node Allocation**: Distribute processing across multiple SLURM nodes
2. **NodeODM Instances**: Start NodeODM on each allocated node
3. **ClusterODM**: Deploy load balancer on master node
4. **Node Registration**: Auto-register NodeODM instances with ClusterODM
5. **External Access**: Setup web access via TAP or SSH tunneling

## TACC-Specific Features

### Module System Integration
Scripts utilize TACC's module system:
```bash
module load tacc-apptainer  # For container runtime
```

### Storage Systems
- **Scratch Storage**: `$SCRATCH` for temporary processing data
- **Work Directory**: Job-specific directories for isolation
- **Archive System**: Tapis cloud.data for persistent storage

### Queue Systems
- **vm-small**: For smaller jobs (< 4 hours, limited resources)  
- **normal**: For larger production jobs
- **development**: For testing (2-hour limit)

### External Access Methods
1. **TAP Portal**: Automatic web access via reverse tunneling
2. **SSH Tunnels**: Manual port forwarding for local access
3. **Direct Access**: Internal TACC network access

## Development Notes

### File Structure
```
├── app.json                      # Tapis application definition
├── tapisjob_app.sh              # Main ZIP runtime execution script
├── nodeodm.sh                   # Direct SLURM NodeODM script  
├── build-zip.sh                 # ZIP package build script
├── cluster-improved.sh          # Multi-node cluster setup
├── single-node-multi-nodeodm.sh # Multi-instance single node
└── images/                      # Documentation screenshots
```

### Resource Management
- **Memory Allocation**: Based on image count and processing complexity
- **Core Assignment**: Automatic distribution based on available resources
- **Time Limits**: Configurable job timeouts with automatic cleanup
- **Storage Management**: Temporary directories with cleanup on exit

### Error Handling
- **Process Monitoring**: Health checks for NodeODM instances
- **Automatic Cleanup**: Trap functions for graceful shutdown
- **Retry Logic**: Multiple attempts for service startup
- **Logging**: Comprehensive logging to separate files per component

### Security Considerations
- **Token Management**: TAP tokens with limited lifetime
- **Network Security**: TLS certificates for secure web access  
- **File Permissions**: Proper directory permissions for container access
- **Authentication**: Integration with TACC authentication systems

## Tapis Integration Specifics

### Job Lifecycle
1. **Submission**: Job submitted via Tapis API with input files
2. **Staging**: Input images staged to compute node storage
3. **Execution**: ZIP extracted and tapisjob_app.sh executed
4. **Processing**: NodeODM processes images to generate outputs
5. **Archival**: Results archived to specified Tapis storage system
6. **Cleanup**: Temporary files and processes cleaned up

### Input/Output Management
- **Input Directory**: `$_tapisExecSystemInputDir` (Tapis-managed)
- **Output Directory**: `$_tapisExecSystemOutputDir` (Tapis-managed) 
- **Archive Location**: Configurable via `archiveSystemDir` in app.json
- **File Transfer**: Automatic staging and archival by Tapis

### Monitoring and Status
- **Job Status**: Tracked through Tapis job management
- **Progress Reporting**: NodeODM task progress via API endpoints
- **Log Collection**: Centralized logging for debugging
- **Web Access**: Real-time access to NodeODM web interface during processing