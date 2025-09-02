# NodeODM LS6 ZIP Package Instructions

This app has been converted from SINGULARITY to ZIP runtime to avoid nested container issues on Tapis.

## Creating the ZIP Package

To create the ZIP package for this Tapis app, you need to:

1. **Download NodeODM source code**:
   ```bash
   wget https://github.com/OpenDroneMap/NodeODM/archive/refs/tags/v2.2.6.zip -O nodeodm-source.zip
   unzip nodeodm-source.zip
   mv NodeODM-2.2.6 nodeodm
   ```

2. **Install NodeODM dependencies** (do this on a system with Node.js):
   ```bash
   cd nodeodm
   npm install --production
   cd ..
   ```

3. **Create the final ZIP package**:
   ```bash
   zip -r nodeodm-ls6.zip run.sh nodeodm/ app.json
   ```

4. **Upload to a publicly accessible location** (e.g., GitHub releases):
   - The `containerImage` in app.json should point to this ZIP file
   - Currently set to: `https://github.com/wmobley/ClusterODM/releases/download/v1.0.5/nodeodm-ls6.zip`

## ZIP Package Structure

The ZIP file should contain:
```
nodeodm-ls6.zip
├── run.sh              # Main execution script
├── app.json            # Tapis app definition (optional in ZIP)
└── nodeodm/            # NodeODM application directory
    ├── index.js        # NodeODM main script
    ├── package.json    # NodeODM dependencies
    ├── node_modules/   # Installed dependencies
    └── ...             # Other NodeODM files
```

## Dependencies Required on Execution System

The execution system (LS6) needs:
- Node.js (available via modules)
- Basic Unix utilities (curl, ps, netstat)
- Network access for downloading the ZIP

## Changes from Container Version

1. **Runtime**: Changed from SINGULARITY to ZIP
2. **Execution**: NodeODM runs directly with `node index.js` instead of in container
3. **Dependencies**: NodeODM and its dependencies are included in the ZIP package
4. **No nested containers**: Avoids the issue of running containers within Tapis containers

## Testing

Test the ZIP package locally:
```bash
unzip nodeodm-ls6.zip
./run.sh 4 3001
```