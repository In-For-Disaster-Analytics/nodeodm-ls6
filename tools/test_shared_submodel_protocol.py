"""Pinned PyODM HTTP -> actual worker materializer -> result restore contract.

Run with PyODM 1.5.12 installed; local fixture processing replaces photogrammetry.
"""
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit, parse_qs
import uuid
import zipfile

from pyodm import Node, exceptions
from pyodm.api import Task

ROOT = Path(__file__).resolve().parents[2]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

engine = load('engine_shared', ROOT / 'ODX/opendm/shared_submodel.py')
worker = load('worker_shared', ROOT / 'NodeODX/helpers/shared_submodel.py')


class ProtocolTests(unittest.TestCase):
    def test_shared_inputs_and_real_task_lifecycle(self):
        with tempfile.TemporaryDirectory() as temporary:
            allocation = Path(temporary)
            data = allocation / '1-admin/runtime/data'
            parent = str(uuid.uuid4())
            project = data / parent / 'submodels/submodel_0001'
            (project / 'images').mkdir(parents=True)
            (project / 'opensfm/exif').mkdir(parents=True)
            (project / 'images/photo.jpg').write_bytes(b'fixture image')
            (project / 'opensfm/camera_models.json').write_text('{}')
            (project / 'opensfm/exif/photo.jpg.exif').write_text('{}')
            outputs = ['opensfm/reconstruction.json', 'opensfm/tracks.csv', 'cameras.json', 'opensfm/features', 'opensfm/matches']
            requests = []
            state = {}
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *_args):
                    pass
                def send(self, body, content_type='application/json'):
                    self.send_response(200)
                    self.send_header('Content-Type', content_type)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                def do_GET(self):
                    self.assert_auth()
                    path = urlsplit(self.path).path
                    if path == '/info':
                        return self.send(json.dumps({'capabilities': {'shared_submodel_v1': True}}).encode())
                    if path.endswith('/info'):
                        return self.send(json.dumps(dict(uuid=state['attempt'], name='submodel', dateCreated=0, processingTime=1,
                            status={'code': 40}, options=[], imagesCount=1)).encode())
                    if path.endswith('/download/all.zip'):
                        return self.send(state['results'], 'application/zip')
                    self.send_error(404)
                def assert_auth(self):
                    if parse_qs(urlsplit(self.path).query).get('token') != ['fixture-token']:
                        raise AssertionError('PyODM authentication was not preserved')
                def do_POST(self):
                    self.assert_auth()
                    body = self.rfile.read(int(self.headers['Content-Length']))
                    message = BytesParser(policy=default).parsebytes(('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + body)
                    fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True).decode()
                              for part in message.iter_parts()}
                    requests.append(fields)
                    fields['shared_source_job_uuid'] = 'fixture-allocation'  # Trusted coordinator authorization fixture.
                    attempt = fields['attempt_id']
                    state['attempt'] = attempt
                    staging = allocation / ('worker-' + attempt + '.initializing')
                    staging.mkdir()
                    destination = allocation / ('worker-' + attempt)
                    worker.materialize(dict(body=fields, id=attempt, root=str(allocation), job='fixture-allocation',
                        imageRoots=[], destination=str(destination), staging=str(staging), maxImages=64))
                    # NodeODX publishes only after its cancellation guard succeeds.
                    os.rename(staging, destination)
                    if (destination / 'images/photo.jpg').is_symlink():
                        raise AssertionError('Worker input is not isolated')
                    archive = io.BytesIO()
                    with zipfile.ZipFile(archive, 'w') as result:
                        for name in outputs[:3]:
                            result.writestr(name, b'fresh')
                        result.writestr('opensfm/features/photo.npz', b'features')
                        result.writestr('opensfm/matches/photo.npz', b'matches')
                    state['results'] = archive.getvalue()
                    self.send(json.dumps({'uuid': attempt}).encode())
            # Avoid platform reverse-DNS resolution for this loopback-only fixture.
            with patch('socket.getfqdn', return_value='localhost'):
                server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with patch.dict(os.environ, ODX_SHARED_SUBMODEL_V1='1', ODX_SHARED_DATA_ROOT=str(data), ODX_SHARED_CONTAINER_ROOT='/var/www/data'):
                    node = Node('127.0.0.1', server.server_port, token='fixture-token')
                    self.assertTrue(engine.enabled(node))
                    seed, fields = engine.snapshot(str(project), 'reconstruction',
                        ['opensfm/camera_models.json', 'opensfm/exif'], ['opensfm/split_merge_stop_at_reconstruction.txt'], outputs)
                    task = engine.submit(node, fields, {}, exceptions.NodeConnectionError, exceptions.TaskFailedError)
                    self.assertIsInstance(task, Task)
                    self.assertEqual(task.uuid, fields['attempt_id'])
                    self.assertNotIn('images', requests[0])
                    self.assertTrue(Path(seed).exists())
                    engine.restore(task, str(project), 'reconstruction', outputs, {}, None)
                    self.assertEqual((project / 'opensfm/reconstruction.json').read_bytes(), b'fresh')
                    self.assertEqual((project / 'images/photo.jpg').read_bytes(), b'fixture image')
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    unittest.main()
