"""Versioned shared inputs for split/merge tasks (never shared mutable outputs)."""
import hashlib
import json
import os
import shutil
import stat
import tempfile
import uuid
import zipfile


def enabled(node):
    if os.environ.get('ODX_SHARED_SUBMODEL_V1') != '1':
        return False
    # NodeInfo in older PyODM releases discards unknown capability fields.
    info = node.get('/info')
    return info.get('capabilities', {}).get('shared_submodel_v1') is True


def translate(path):
    container = os.path.abspath(os.environ.get('ODX_SHARED_CONTAINER_ROOT', '/var/www/data'))
    host = os.environ.get('ODX_SHARED_DATA_ROOT')
    if not host or not os.path.isabs(host):
        raise ValueError('Shared submodel data root must be explicitly configured')
    host = os.path.normpath(host)
    path = os.path.abspath(path)
    for root in (container, host):
        if os.path.commonpath([root, path]) == root:
            return os.path.join(host, os.path.relpath(path, root))
    raise ValueError('Shared submodel path is outside configured data root')


def snapshot(project, stage, seed_files, markers, outputs):
    """Create an exclusive immutable archive; hash the exact bytes written."""
    project = os.path.abspath(project)
    mapped = translate(project)
    host = os.path.normpath(os.environ['ODX_SHARED_DATA_ROOT'])
    parts = os.path.relpath(mapped, host).split(os.sep)
    if len(parts) < 3 or parts[1] != 'submodels':
        raise ValueError('Shared submodel must belong to a parent task submodels directory')
    parent = str(uuid.UUID(parts[0]))
    if not os.path.isdir(os.path.join(project, 'images')):
        raise ValueError('Shared submodel images directory is missing')
    attempt = str(uuid.uuid4())
    archive = os.path.join(project, '.shared-submodel-%s.zip' % attempt)
    files = {}
    members = []
    for relative in list(seed_files) + ['gcp_list.txt', 'geo.txt']:
        source = os.path.join(project, relative)
        if not os.path.exists(source):
            continue
        if os.path.isdir(source):
            for root, dirs, names in os.walk(source, followlinks=False):
                if any(os.path.islink(os.path.join(root, d)) for d in dirs):
                    raise ValueError('Seed directories cannot contain symlinks')
                members.extend(os.path.relpath(os.path.join(root, n), project) for n in names)
        else:
            members.append(relative)
    if len(set(markers)) != len(markers) or set(markers).intersection(members):
        raise ValueError('Seed markers conflict with seed files')
    try:
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
            for relative in sorted(set(members)):
                path = os.path.join(project, relative)
                # Reject all seed symlinks and special files, including a replaced file.
                fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
                with os.fdopen(fd, 'rb') as src:
                    if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
                        raise ValueError('Seed inputs must be regular files')
                    digest = hashlib.sha256()
                    with zf.open(relative.replace(os.sep, '/'), 'w', force_zip64=True) as dst:
                        while True:
                            block = src.read(1024 * 1024)
                            if not block:
                                break
                            digest.update(block)
                            dst.write(block)
                    files[relative.replace(os.sep, '/')] = digest.hexdigest()
            for relative in markers:
                zf.writestr(relative, b'')
                files[relative] = hashlib.sha256(b'').hexdigest()
            zf.writestr('shared_submodel.json', json.dumps({
                'version': 1, 'stage': stage, 'attempt_id': attempt,
                'parent_task_uuid': parent, 'outputs': outputs,
                'files': files, 'markers': markers,
            }, sort_keys=True))
        os.chmod(archive, 0o400)
    except Exception:
        if os.path.exists(archive):
            os.unlink(archive)
        raise
    return archive, {
        'shared_submodel_version': '1', 'attempt_id': attempt,
        'parent_task_uuid': parent, 'import_path': translate(os.path.join(project, 'images')),
        'seed_path': translate(archive), 'outputs': json.dumps(outputs),
        'skipPostProcessing': 'true', 'name': os.path.basename(project),
    }


def submit(node, fields, options, connection_error, failed_error):
    """Use PyODM's authenticated transport and return its genuine Task object."""
    from pyodm.utils import MultipartEncoder
    fields = dict(fields, options=json.dumps([{'name': k, 'value': v} for k, v in options.items()]))
    body = MultipartEncoder(fields=fields)
    try:
        response = node.post('/task/new', data=body,
                             headers={'Content-Type': body.content_type, 'set-uuid': fields['attempt_id']})
    except connection_error:
        # The coordinator may have accepted the request. Never submit another UUID.
        task = node.get_task(fields['attempt_id'])
        try:
            task.info()
        except Exception:
            raise failed_error('Shared submission acknowledgment lost; reconcile attempt %s before retrying' % fields['attempt_id'])
        return task
    if not isinstance(response, dict) or response.get('uuid') != fields['attempt_id']:
        raise failed_error('Shared submission did not acknowledge the requested attempt UUID')
    return node.get_task(response['uuid'])


def restore(task, project, stage, outputs, options, progress_callback):
    """Validate freshly downloaded outputs before restoring any parent state."""
    with tempfile.TemporaryDirectory(prefix='.shared-result-', dir=project) as staging:
        task.download_assets(staging, progress_callback=progress_callback)
        if stage == 'reconstruction':
            required = ['opensfm/reconstruction.json', 'opensfm/tracks.csv', 'cameras.json',
                        'opensfm/features', 'opensfm/matches']
        else:
            required = []
            if not options.get('skip-orthophoto', False):
                required.extend(['odm_orthophoto/cutline.gpkg', 'odm_orthophoto/odm_orthophoto_cut.tif',
                                 'odm_orthophoto/odm_orthophoto_feathered.tif'])
            for product in ('dsm', 'dtm'):
                if options.get(product):
                    required.extend(['odm_dem/%s.tif' % product, 'odm_dem/%s.euclideand.tif' % product])
            if options.get('merge', 'all') in ('all', 'pointcloud'):
                required.append('odm_georeferencing/odm_georeferenced_model.laz')
            # Split/merge submodels always pass skip-report; optional products stay optional.
            if not options.get('skip-report', True):
                required.append('odm_report')
        for relative in required:
            path = os.path.join(staging, relative)
            if not os.path.exists(path) or (os.path.isfile(path) and os.path.getsize(path) == 0):
                raise ValueError('Missing fresh shared submodel result: %s' % relative)
        for relative in outputs:
            source = os.path.join(staging, relative)
            if not os.path.exists(source):
                continue
            destination = os.path.join(project, relative)
            for root in (staging, project):
                candidate = os.path.join(root, relative)
                while candidate != root:
                    if os.path.islink(candidate):
                        raise ValueError('Cannot restore results through a symlink')
                    candidate = os.path.dirname(candidate)
            for tree in (source, destination):
                if os.path.isdir(tree):
                    for current, dirs, names in os.walk(tree, followlinks=False):
                        if any(os.path.islink(os.path.join(current, n)) for n in dirs + names):
                            raise ValueError('Result tree contains a symlink')
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            if os.path.isdir(source):
                shutil.copytree(source, destination, dirs_exist_ok=True)
            else:
                shutil.copy2(source, destination)
