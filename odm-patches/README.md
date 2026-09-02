# ODM Patches

This directory contains patched versions of ODM Python modules that get bind-mounted over the upstream code at runtime.

## How it works

1. `ODM/opendm/remote.py` and `ODM/opendm/osfm.py` are the **source of truth** (upstream ODM)
2. This directory holds the patched versions that actually run in the container
3. At runtime, `tapisjob_app.sh` bind-mounts these over `/code/opendm/`:
   ```bash
   --bind odm-patches/remote.py:/code/opendm/remote.py:ro
   --bind odm-patches/osfm.py:/code/opendm/osfm.py:ro
   ```

## Workflow

### Making changes

1. **Edit the upstream source first**: `ODM/opendm/remote.py` (or `osfm.py`)
2. **Sync to patches**: `cp ODM/opendm/remote.py nodeodm-ls6/odm-patches/remote.py`
3. **Rebuild ZIP**: `./build-zip.sh`
4. **Verify**: The patch file and upstream file should be identical after sync

### Why patches instead of forking?

- **Easy rebase**: When upstream ODM releases new versions, we can diff/merge just our changes
- **Visibility**: `odm-patches/` makes it obvious what's customized vs. upstream
- **Minimal surface**: We only touch the files we need

### Current patches

| File | Purpose | Key changes |
|------|---------|-------------|
| `remote.py` | Split-merge task dispatch | `NODEODM_MAX_REMOTE_TASKS` env var override, import_path mode, enhanced logging |
| `osfm.py` | OpenSfM integration | (minimal changes) |

## Verification

After syncing, verify the files are identical:

```bash
diff ODM/opendm/remote.py nodeodm-ls6/odm-patches/remote.py
diff ODM/opendm/osfm.py nodeodm-ls6/odm-patches/osfm.py
```

Both should produce no output (identical files).
