import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('shared', Path(__file__).parents[2] / 'helpers/shared_submodel.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
PARENT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
ATTEMPT = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'


class MaterializeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.submodel = self.root / '1-admin/runtime/data' / PARENT / 'submodels/submodel_0000'
        self.images = self.submodel / 'images'
        self.images.mkdir(parents=True)
        (self.images / 'one.jpg').write_bytes(b'image')
        self.seed = self.submodel / 'seed.zip'
        self.staging = self.root / 'staging'
        self.staging.mkdir()
        self.config = dict(root=str(self.root), job='job-1', imageRoots=[], id=ATTEMPT,
                           staging=str(self.staging), destination=str(self.root / 'task'), maxImages=1,
                           body=dict(shared_submodel_version='1', shared_source_job_uuid='job-1',
                                     parent_task_uuid=PARENT, attempt_id=ATTEMPT, skipPostProcessing='true',
                                     import_path=str(self.images), seed_path=str(self.seed), outputs='[]', options='[]'))
        self.write_seed()

    def write_seed(self, stage='reconstruction', extra=None, corrupt=False):
        markers = ['opensfm/split_merge_stop_at_reconstruction.txt'] if stage == 'reconstruction' else ['opensfm/features/empty', 'opensfm/matches/empty', 'opensfm/exif/empty']
        files = {name: b'' for name in markers}
        files['opensfm/camera_models.json'] = b'{}'
        if stage == 'toolchain':
            files['opensfm/reconstruction.json'] = b'[]'
            files['opensfm/tracks.csv'] = b'tracks'
        files.update(extra or {})
        manifest = dict(version=1, stage=stage, attempt_id=ATTEMPT, parent_task_uuid=PARENT,
                        outputs=[], markers=markers,
                        files={name: hashlib.sha256(data).hexdigest() for name, data in files.items()})
        if corrupt:
            manifest['files']['opensfm/camera_models.json'] = '0' * 64
        with zipfile.ZipFile(self.seed, 'w') as archive:
            archive.writestr('shared_submodel.json', json.dumps(manifest))
            for name, content in files.items():
                archive.writestr(name, content)

    def test_stages_copy_inputs_and_preserve_source(self):
        for stage in ('reconstruction', 'toolchain'):
            with self.subTest(stage=stage):
                self.write_seed(stage)
                destination = self.root / ('task-' + stage)
                self.config['destination'] = str(destination)
                if not self.staging.exists():
                    self.staging.mkdir()
                original = self.seed.read_bytes()
                shared.materialize(self.config)
                self.staging.rename(destination)
                image = destination / 'images/one.jpg'
                self.assertFalse(image.is_symlink())
                image.write_bytes(b'worker mutation')
                self.assertEqual((self.images / 'one.jpg').read_bytes(), b'image')
                self.assertEqual(self.seed.read_bytes(), original)
                self.assertTrue((destination / 'opensfm/camera_models.json').is_file())
                self.assertFalse((destination / 'seed.zip').exists())

    def test_rejects_cross_job(self):
        self.config['body']['shared_source_job_uuid'] = 'job-2'
        with self.assertRaisesRegex(ValueError, 'allocation mismatch'):
            shared.materialize(self.config)

    def test_rejects_traversal_and_stage_overwrite(self):
        for name in ('../escape', 'images/payload.jpg', 'opensfm/../camera_models.json'):
            self.write_seed(extra={name: b'bad'})
            with self.assertRaises(ValueError):
                shared.materialize(self.config)
            for child in self.staging.iterdir():
                if child.is_file():
                    child.unlink()

    def test_rejects_hash_mismatch(self):
        self.write_seed(corrupt=True)
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            shared.materialize(self.config)

    def test_rejects_escaping_image_link(self):
        outside = self.root.parent / (self.root.name + '-outside.jpg')
        outside.write_bytes(b'outside')
        self.addCleanup(outside.unlink)
        (self.images / 'one.jpg').unlink()
        (self.images / 'one.jpg').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'outside authorized'):
            shared.materialize(self.config)

    def test_rejects_other_allocation_image_even_when_scratch_is_mounted(self):
        with tempfile.TemporaryDirectory() as other:
            image = Path(other) / 'other.jpg'
            image.write_bytes(b'other allocation')
            (self.images / 'one.jpg').unlink()
            (self.images / 'one.jpg').symlink_to(image)
            # Mount visibility does not extend the v1-specific authorization roots.
            with self.assertRaisesRegex(ValueError, 'outside authorized'):
                shared.materialize(self.config)

    def test_rejects_seed_outside_parent(self):
        self.config['body']['seed_path'] = str(self.root / 'seed.zip')
        (self.root / 'seed.zip').write_bytes(self.seed.read_bytes())
        with self.assertRaisesRegex(ValueError, 'outside parent'):
            shared.materialize(self.config)

    def test_copies_seed_support_and_rejects_conflicts(self):
        self.write_seed(extra={'geo.txt': b'seed geo'})
        (self.images / 'geo.txt').write_bytes(b'different geo')
        with self.assertRaisesRegex(ValueError, 'Conflicting support'):
            shared.materialize(self.config)


if __name__ == '__main__':
    unittest.main()
