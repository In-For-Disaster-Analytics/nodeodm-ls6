"""Shared submission contract tests; no running processing node required."""
import hashlib
import json
import os
import tempfile
import unittest
import uuid
import zipfile
from unittest.mock import Mock, patch
from opendm import shared_submodel as shared


class SharedSubmodelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = self.temp.name
        self.parent = str(uuid.uuid4())
        self.project = os.path.join(self.root, self.parent, 'submodels', 'submodel_0000')
        os.makedirs(os.path.join(self.project, 'images'))
        os.makedirs(os.path.join(self.project, 'opensfm'))
        self.env = patch.dict(os.environ, {
            'ODX_SHARED_DATA_ROOT': self.root,
            'ODX_SHARED_CONTAINER_ROOT': '/var/www/data',
            'ODX_SHARED_SUBMODEL_V1': '1',
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def write(self, relative, data=b'contents'):
        path = os.path.join(self.project, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
        return path

    def test_snapshot_preserves_support_and_hashes_exact_seed(self):
        self.write('opensfm/camera_models.json', b'{}')
        self.write('gcp_list.txt', b'GCP')
        self.write('geo.txt', b'GEO')
        self.write('images/photo.jpg', b'image must not enter ZIP')
        marker = 'opensfm/split_merge_stop_at_reconstruction.txt'
        archive, fields = shared.snapshot(self.project, 'reconstruction',
                ['opensfm/camera_models.json'], [marker], ['cameras.json'])
        with zipfile.ZipFile(archive) as zf:
            manifest = json.loads(zf.read('shared_submodel.json'))
            self.assertEqual(manifest['parent_task_uuid'], self.parent)
            self.assertEqual(manifest['markers'], [marker])
            for path, digest in manifest['files'].items():
                self.assertEqual(hashlib.sha256(zf.read(path)).hexdigest(), digest)
            self.assertNotIn('images/photo.jpg', zf.namelist())
            self.assertIn('gcp_list.txt', zf.namelist())
            self.assertIn('geo.txt', zf.namelist())
        self.assertEqual(fields['import_path'], os.path.join(self.project, 'images'))
        self.assertEqual(fields['seed_path'], archive)
        second, _ = shared.snapshot(self.project, 'reconstruction', [], [], [])
        self.assertNotEqual(archive, second)
        self.assertEqual(os.stat(archive).st_mode & 0o222, 0)

    def test_capability_must_be_boolean_and_enabled_before_path_checks(self):
        node = Mock()
        for value in (False, None, 'true', 1):
            node.get.return_value = {'capabilities': {'shared_submodel_v1': value}}
            self.assertFalse(shared.enabled(node))
        node.get.return_value = {'capabilities': {'shared_submodel_v1': True}}
        self.assertTrue(shared.enabled(node))
        with patch.dict(os.environ, {'ODX_SHARED_SUBMODEL_V1': '0'}):
            node.get.reset_mock()
            self.assertFalse(shared.enabled(node))
            node.get.assert_not_called()

    def test_path_mapping_rejects_sibling_and_missing_configuration(self):
        expected = os.path.join(self.root, self.parent, 'submodels', 's', 'images')
        self.assertEqual(shared.translate('/var/www/data/%s/submodels/s/images' % self.parent), expected)
        with self.assertRaises(ValueError):
            shared.translate('/var/www/data-other/secret')
        with patch.dict(os.environ, {'ODX_SHARED_DATA_ROOT': ''}):
            with self.assertRaises(ValueError):
                shared.translate(self.project)

    def test_seed_symlinks_rejected_and_partial_archive_removed(self):
        os.symlink('/etc/hosts', os.path.join(self.project, 'geo.txt'))
        with self.assertRaises(OSError):
            shared.snapshot(self.project, 'toolchain', [], [], [])
        self.assertFalse(any(n.endswith('.zip') for n in os.listdir(self.project)))

    def test_old_results_cannot_satisfy_new_completion(self):
        self.write('opensfm/reconstruction.json')
        self.write('opensfm/tracks.csv')
        self.write('cameras.json')
        task = Mock()
        with self.assertRaisesRegex(ValueError, 'Missing fresh'):
            shared.restore(task, self.project, 'reconstruction', [], {}, None)
        task.download_assets.assert_called_once()

    def test_toolchain_optional_outputs_and_restore(self):
        def download(path, **kwargs):
            os.makedirs(os.path.join(path, 'odm_orthophoto'))
            for name in ['cutline.gpkg', 'odm_orthophoto_cut.tif', 'odm_orthophoto_feathered.tif']:
                with open(os.path.join(path, 'odm_orthophoto', name), 'wb') as f:
                    f.write(b'fresh')
        task = Mock()
        task.download_assets.side_effect = download
        outputs = ['odm_orthophoto/cutline.gpkg', 'odm_orthophoto/odm_orthophoto_cut.tif',
                   'odm_orthophoto/odm_orthophoto_feathered.tif', 'odm_dem', 'odm_report']
        shared.restore(task, self.project, 'toolchain', outputs, {'merge': 'orthophoto'}, None)
        self.assertTrue(os.path.isfile(os.path.join(self.project, outputs[0])))
        self.assertFalse(os.path.exists(os.path.join(self.project, 'odm_report')))
        with self.assertRaisesRegex(ValueError, 'odm_dem'):
            shared.restore(task, self.project, 'toolchain', outputs, {'dsm': True, 'merge': 'orthophoto'}, None)

    def test_restore_rejects_nested_existing_destination_symlink(self):
        outside = os.path.join(self.root, 'outside')
        os.makedirs(outside)
        os.makedirs(os.path.join(self.project, 'features'))
        os.symlink(outside, os.path.join(self.project, 'features', 'nested'))
        def download(path, **kwargs):
            os.makedirs(os.path.join(path, 'features', 'nested'))
            with open(os.path.join(path, 'features', 'nested', 'data'), 'wb') as output:
                output.write(b'must not escape')
        task = Mock()
        task.download_assets.side_effect = download
        with self.assertRaisesRegex(ValueError, 'symlink'):
            shared.restore(task, self.project, 'toolchain', ['features'],
                           {'skip-orthophoto': True, 'merge': 'orthophoto'}, None)
        self.assertFalse(os.listdir(outside))

    def test_submit_uses_authenticated_transport_without_image_bodies(self):
        class Encoder:
            content_type = 'multipart/form-data; boundary=test'
            def __init__(self, fields):
                self.fields = fields
        node = Mock()
        attempt = str(uuid.uuid4())
        fields = {'attempt_id': attempt, 'shared_submodel_version': '1', 'import_path': '/images', 'seed_path': '/seed'}
        node.post.return_value = {'uuid': attempt}
        with patch.dict('sys.modules', {'pyodm.utils': Mock(MultipartEncoder=Encoder)}):
            self.assertIs(shared.submit(node, fields, {'dsm': True}, ConnectionError, RuntimeError), node.get_task.return_value)
        args, kwargs = node.post.call_args
        self.assertEqual(args, ('/task/new',))
        self.assertNotIn('images', kwargs['data'].fields)
        self.assertEqual(kwargs['headers']['set-uuid'], attempt)
        self.assertEqual(json.loads(kwargs['data'].fields['options']), [{'name': 'dsm', 'value': True}])
        node.post.side_effect = ConnectionError()
        node.get_task.return_value.info.side_effect = ConnectionError()
        with patch.dict('sys.modules', {'pyodm.utils': Mock(MultipartEncoder=Encoder)}):
            with self.assertRaisesRegex(RuntimeError, 'reconcile attempt'):
                shared.submit(node, fields, {}, ConnectionError, RuntimeError)
        self.assertEqual(node.post.call_count, 2)  # one call per explicit test submission
        node.create_task.assert_not_called()


if __name__ == '__main__':
    unittest.main()
