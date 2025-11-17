# NodeODM LS6 ZIP Package (Source Overlay)

This ZIP runtime pulls a NodeODM container (default: `ghcr.io/ptdatax/nodeodm:latest`, override with `NODEODM_IMAGE`) for the heavy ODM dependencies, but replaces the application code with a local checkout of the NodeODM repository. This approach lets you run from any commit without waiting for a prebuilt container and keeps us independent of upstream image changes.

## 1. Populate `nodeodm-source/`

Before building the ZIP, copy the NodeODM source into `nodeodm-ls6/nodeodm-source`:

```bash
# Option A: reuse the copy that ships with WebODM
rsync -a --delete ../WebODM/nodeodm/external/NodeODM/ nodeodm-ls6/nodeodm-source/

# Option B: clone a specific commit
git clone https://github.com/OpenDroneMap/NodeODM.git nodeodm-ls6/nodeodm-source
cd nodeodm-ls6/nodeodm-source
git checkout <commit>
cd -
```

The runtime installs dependencies on first launch, so do **not** commit `node_modules/` into this directory.

## 2. Build the ZIP package

```bash
cd nodeodm-ls6
./build-zip.sh
```

The script verifies that `nodeodm-source/` exists and then packages:

```
tapisjob_app.sh
app.json
register-node.sh
deregister-node.sh
README-ZIP.md
nodeodm-source/
```

`nodeodm-ls6.zip` is created in the same directory with `.git/` and `node_modules/` automatically excluded.

## 3. Upload and register

1. Upload `nodeodm-ls6.zip` to a location reachable by the Tapis execution system (for example a GitHub release or object store).
2. Update the `containerImage` URL in `app.json` if it changed.
3. Re-register the app with Tapis.

## 4. How the runtime works

- When the job starts, `tapisjob_app.sh` copies `nodeodm-source/` into a writable work directory and binds it to `/var/www` inside the Apptainer container.
- If `node_modules/` is missing, the script runs `npm install --production` once before launching `node index.js`.
- Outputs, submodels, and logs are written to the bound `data/`, `tmp/`, and `logs/` directories under the work directory, preserving the same layout expected by ClusterODM. NodeODM’s internal logger now targets `/var/www/logs`, so you can inspect `nodeodm_workdir/runtime/logs/` on LS6 for per-run files.
- Logging defaults to the most verbose `silly` level; override by exporting `NODEODM_LOG_LEVEL` (e.g. `export NODEODM_LOG_LEVEL=debug`) before launching the job.

## 5. Runtime requirements on LS6

- `module load tacc-apptainer` (already performed by the script)
- Network access for ClusterODM/Tapis callbacks
- Sufficient scratch space for the copied NodeODM source and build artifacts

## 6. Validation

Before uploading, you can smoke-test locally (requires apptainer access):

```bash
cd nodeodm-ls6
./tapisjob_app.sh 4 3001
```

This will start NodeODM with the local source overlaid. Stop it with `pkill -f "node index.js --config"` when finished.
