"""Validate and materialize v1 shared inputs into an exclusively owned staging tree."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import zipfile

MAX_ENTRIES = 100000
MAX_COMPRESSED = 8 * 1024**3
MAX_EXPANDED = 32 * 1024**3
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-7][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', re.I)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def within(candidate, root):
    return candidate == root or root in candidate.parents


def safe_name(name):
    require(isinstance(name, str) and name and '\\' not in name and '\x00' not in name, 'Invalid seed name')
    p = PurePosixPath(name)
    require(not p.is_absolute() and all(x not in ('', '.', '..') for x in name.split('/')), 'Invalid seed path')
    return name


def copy_regular(source, destination, limit=None):
    # Resolve permitted symlinks first; O_NOFOLLOW rejects replacement before open.
    source = Path(source)
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in source.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(source.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(descriptor, 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'Non-regular source')
        require(limit is None or os.fstat(stream.fileno()).st_size <= limit, 'Source size limit exceeded')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as output:
            copied = 0
            while True:
                block = stream.read(1024**2)
                if not block:
                    break
                copied += len(block)
                require(limit is None or copied <= limit, 'Source size limit exceeded')
                output.write(block)


def materialize(c):
    b = c['body']
    require(b.get('shared_submodel_version') == '1', 'Unsupported shared submodel version')
    require(b.get('shared_source_job_uuid') == c['job'], 'Shared source allocation mismatch')
    for key in ('parent_task_uuid', 'attempt_id'):
        require(isinstance(b.get(key), str) and UUID.fullmatch(b[key]), 'Invalid ' + key)
    require(b['attempt_id'] == c['id'], 'Attempt UUID mismatch')
    require(b.get('skipPostProcessing') == 'true', 'Shared tasks require skipPostProcessing')
    require(not b.get('zipurl'), 'Shared tasks cannot include zipurl')
    root = Path(c['root']).resolve(strict=True)
    images_lexical = Path(b['import_path']).absolute()
    # Source runtime belongs to a sibling child of this allocation, never an arbitrary data tree.
    ancestors = [p for p in images_lexical.parents if p.name == b['parent_task_uuid'] and p.parent.name == 'data' and p.parent.parent.name == 'runtime']
    require(len(ancestors) == 1, 'Missing parent task source subtree')
    parent = ancestors[0].resolve(strict=True)
    require(parent in (root / '1-admin/runtime/data' / b['parent_task_uuid'], root / 'runtime/data' / b['parent_task_uuid']), 'Parent task outside admin allocation scope')
    require(images_lexical.parent.name.startswith('submodel_') and images_lexical.parent.parent.name == 'submodels' and images_lexical.name == 'images', 'Invalid submodel image path')
    seed = Path(b['seed_path']).resolve(strict=True)
    require(within(seed, parent) and within(seed, root), 'Seed outside parent allocation subtree')
    images = images_lexical.resolve(strict=True)
    roots = [root] + [Path(p).resolve(strict=True) for p in c['imageRoots']]
    require(images.is_dir() and any(within(images, p) for p in roots), 'Images outside authorized roots')
    staging = Path(c['staging'])
    require(staging.is_dir() and not any(staging.iterdir()), 'Invalid task staging')
    snapshot = staging / 'seed.zip'
    copy_regular(seed, snapshot, MAX_COMPRESSED)
    require(snapshot.stat().st_size <= MAX_COMPRESSED, 'Seed compressed limit exceeded')
    with zipfile.ZipFile(snapshot) as z:
        infos = z.infolist()
        require(len(infos) <= MAX_ENTRIES and sum(i.file_size for i in infos) <= MAX_EXPANDED, 'Seed limits exceeded')
        members = {}
        folded = set()
        for i in infos:
            name = safe_name(i.filename.rstrip('/'))
            require(name.casefold() not in folded, 'Duplicate seed member')
            folded.add(name.casefold())
            mode = i.external_attr >> 16
            require(not i.flag_bits & 1 and (stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR)), 'Unsupported seed member type')
            require(not i.is_dir(), 'Seed must contain regular files only')
            members[name] = i
        for name in members:
            require(not any(str(p) in members for p in PurePosixPath(name).parents if str(p) != '.'), 'Seed file directory collision')
        require('shared_submodel.json' in members and members['shared_submodel.json'].file_size <= 1024**2, 'Missing or oversized manifest')
        m = json.loads(z.read(members['shared_submodel.json']))
        require(m.get('version') == 1 and m.get('attempt_id') == b['attempt_id'] and m.get('parent_task_uuid') == b['parent_task_uuid'], 'Manifest identity mismatch')
        outputs = json.loads(b['outputs']) if isinstance(b.get('outputs'), str) else b.get('outputs')
        require(isinstance(outputs, list) and m.get('outputs') == outputs, 'Manifest outputs mismatch')
        stage = m.get('stage')
        markers = ['opensfm/split_merge_stop_at_reconstruction.txt'] if stage == 'reconstruction' else ['opensfm/features/empty', 'opensfm/matches/empty', 'opensfm/exif/empty']
        require(stage in ('reconstruction', 'toolchain') and sorted(m.get('markers', [])) == sorted(markers), 'Invalid stage markers')
        files = m.get('files')
        require(isinstance(files, dict) and set(members) == set(files) | {'shared_submodel.json'}, 'Manifest member mismatch')
        require(set(markers) <= set(files), 'Missing markers')
        options = json.loads(b['options']) if isinstance(b.get('options'), str) else b.get('options')
        require(isinstance(options, list) and all(isinstance(o, dict) and isinstance(o.get('name'), str) and 'value' in o for o in options), 'Invalid options')
        opts = {o['name']: o['value'] for o in options}
        require(not opts.get('split') and not opts.get('split-image-groups'), 'Nested split forbidden')
        require(not opts.get('rerun') and not opts.get('rerun-all') and not opts.get('rerun-from'), 'Seed-invalidating rerun forbidden')
        common = {'opensfm/camera_models.json', 'opensfm/reference_lla.json', 'gcp_list.txt', 'geo.txt'}
        allowed = common | set(markers)
        if stage == 'toolchain':
            allowed |= {'opensfm/reconstruction.json', 'opensfm/tracks.csv'}
        for name, digest in files.items():
            require(name in allowed or (stage == 'reconstruction' and name.startswith('opensfm/exif/')), 'Seed stage allowlist violation')
            require(isinstance(digest, str) and re.fullmatch('[0-9a-f]{64}', digest), 'Invalid seed hash')
            destination = staging / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            h = hashlib.sha256()
            with z.open(members[name]) as src, destination.open('xb') as dst:
                while True:
                    block = src.read(1024**2)
                    if not block:
                        break
                    h.update(block)
                    dst.write(block)
            require(h.hexdigest() == digest, 'Seed hash mismatch')
            require(name not in markers or destination.stat().st_size == 0, 'Marker must be empty')
    snapshot.unlink()
    (staging / 'images').mkdir()
    (staging / 'gcp').mkdir()
    count = 0
    for entry in images.iterdir():
        target = entry.resolve(strict=True)
        require(any(within(target, p) for p in roots), 'Image target outside authorized roots')
        require(target.is_file(), 'Images must be regular files')
        support = entry.suffix.lower() == '.txt' or re.fullmatch(r'align\.(las|laz|tif)', entry.name, re.I)
        destination = staging / ('gcp' if support else 'images') / entry.name
        if support and (staging / entry.name).exists():
            require(hashlib.sha256(target.read_bytes()).digest() == hashlib.sha256((staging / entry.name).read_bytes()).digest(), 'Conflicting support file')
        copy_regular(target, destination)
        if not support:
            require(re.search(r'\.(jpe?g|png|gif|bmp|tiff?)$', entry.name, re.I), 'Unsupported image entry')
            count += 1
    for name in ('gcp_list.txt', 'geo.txt'):
        source = staging / name
        if source.exists() and not (staging / 'gcp' / name).exists():
            shutil.copyfile(source, staging / 'gcp' / name)
    require(count > 0 and (not c.get('maxImages') or count <= c['maxImages']), 'Invalid image count')
    require(not os.path.lexists(c['destination']), 'Task destination exists')
    # Publication is performed by the Node owner under its cancellation guard.


if __name__ == '__main__':
    try:
        materialize(json.load(sys.stdin))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
