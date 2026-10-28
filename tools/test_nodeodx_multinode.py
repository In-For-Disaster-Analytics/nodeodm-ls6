"""Exercise actual launcher fan-out and registration payload without Slurm/Tapis."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'nodeodx/tapisjob_app.sh').read_text()
PREAMBLE = SOURCE[SOURCE.index('MAX_CONCURRENCY='):SOURCE.index('launch_multi_node_children()')]
DISPATCH = SOURCE[SOURCE.index('launch_multi_node_children()'):SOURCE.index('# A multi-node Tapis allocation')]


class MultiNodeTests(unittest.TestCase):
    def dispatch(self, hosts, child='0', failed_host=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scontrol = root / 'scontrol'
            scontrol.write_text('#!/bin/sh\nprintf "%s\\n" $TEST_HOSTS\n')
            scontrol.chmod(0o755)
            srun = root / 'srun'
            srun.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
args = sys.argv[1:]
host = args[args.index('-w') + 1]
env_args = args[args.index('env') + 1:args.index('bash')]
record = {'env': dict(value.split('=', 1) for value in env_args), 'args': args}
(pathlib.Path(os.environ['TEST_OUTPUT']) / (host + '.json')).write_text(json.dumps(record))
sys.exit(9 if host == os.environ.get('TEST_FAILED_HOST') else 0)
''')
            srun.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       TEST_OUTPUT=directory, TEST_HOSTS=' '.join(hosts), TEST_FAILED_HOST=failed_host,
                       SLURM_NODELIST='fixture', NODEODX_CHILD=child, SCRIPT_DIR=directory,
                       NODEODX_JOB_INDEX='2', NODEODX_JOB_COUNT='3')
            for key in ['NODEODX_ROLE', 'NODEODX_WORKER_ID', 'NODEODX_PORT']:
                env.pop(key, None)
            result = subprocess.run(['bash', '-c', PREAMBLE + DISPATCH + '\nlaunch_multi_node_children\n'],
                                    env=env, capture_output=True, text=True)
            records = [json.loads((root / f'{host}.json').read_text()) for host in hosts
                       if (root / f'{host}.json').exists()]
            return result, records

    def test_two_and_four_hosts(self):
        for count in [2, 4]:
            result, records = self.dispatch([f'host{i}' for i in range(count)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(records), count)
            self.assertEqual([r['env']['NODEODX_ROLE'] for r in records], ['admin'] + ['worker'] * (count - 1))
            for index, record in enumerate(records):
                env = record['env']
                self.assertEqual(env['NODEODX_WORKER_ID'], str(index))
                self.assertEqual(env['NODEODX_HOST_INDEX'], str(index + 1))
                self.assertEqual(env['NODEODX_JOB_INDEX'], '2')
                self.assertEqual(env['NODEODX_JOB_COUNT'], '3')
                self.assertEqual(record['args'][-2], str(3001 + index))
            self.assertEqual(len({r['env']['NODEODX_CHILD_INDEX'] for r in records}), count)

    def test_single_host_and_child_do_not_fan_out(self):
        for hosts, child in [(['host0'], '0'), (['host0', 'host1'], '1')]:
            result, records = self.dispatch(hosts, child)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(records, [])

    def test_child_failure_propagates(self):
        result, records = self.dispatch(['host0', 'host1'], failed_host='host1')
        self.assertEqual(result.returncode, 9)
        self.assertEqual(len(records), 2)

    def test_secret_mode_and_cleanup(self):
        start = SOURCE.index('REGISTRATION_ACCESS_TOKEN=')
        end = SOURCE.index('NODEODX_CLEANUP_TASKS_AFTER=', start)
        helpers = SOURCE[start:end]
        cleanup = SOURCE[SOURCE.index('deregister_node()'):SOURCE.index('cleanup()')]
        for secret in ['', 'fixture-secret-unique']:
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'request.json'
                env = dict(os.environ, TAPIS_ACCESS_TOKEN='expired-bearer',
                           NODEODX_REGISTRATION_SECRET=secret, TEST_REQUEST=str(output),
                           REGISTERED_HOST='worker', REGISTERED_PORT='3000',
                           REGISTERED_NODE_ID='2', REGISTERED_REGISTRATION_UUID='job',
                           CLUSTER_URL='https://cluster.example')
                script = helpers + cleanup + '''
                curl() { python3 -c 'import json,os,sys; json.dump({"args":sys.argv[1:],"body":json.load(sys.stdin)},open(os.environ["TEST_REQUEST"],"w"))' "$@"; }
                deregister_node
                printf '%s' "$REGISTRATION_ACCESS_TOKEN"
'''
                result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                request = json.loads(output.read_text())
                self.assertEqual(request['body']['nodeId'], 2)
                self.assertEqual(request['body'].get('registrationSecret', ''), secret)
                if secret:
                    self.assertEqual(result.stdout, '')
                    self.assertNotIn('expired-bearer', ' '.join(request['args']))
                    self.assertNotIn(secret, ' '.join(request['args']))
                else:
                    self.assertEqual(result.stdout, 'expired-bearer')
                    self.assertIn('Authorization: Bearer expired-bearer', request['args'])

    def test_registration_failure_keeps_secret_out_of_retry_artifacts(self):
        helpers = SOURCE[SOURCE.index('REGISTRATION_ACCESS_TOKEN='):SOURCE.index('NODEODX_CLEANUP_TASKS_AFTER=')]
        registration = SOURCE[SOURCE.index('if [[ -n "$REGISTERED_HOST" ]]; then'):SOURCE.index('cat > "$WORK_ROOT/connection_info.txt"')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / 'curl'
            curl.write_text(f'#!{sys.executable}\n' + '''import json,os,pathlib,sys
args=sys.argv[1:]
body=json.load(sys.stdin)
pathlib.Path(os.environ['TEST_REQUEST']).write_text(json.dumps({'body':body,'args':args}))
pathlib.Path(args[args.index('-o')+1]).write_text('{"error":"fixture rejection"}')
print('401',end='')
''')
            curl.chmod(0o755)
            secret = 'fixture-secret-that-must-stay-out-of-logs'
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', WORK_ROOT=directory,
                       TEST_REQUEST=str(root / 'request.json'), NODEODX_REGISTRATION_SECRET=secret,
                       TAPIS_ACCESS_TOKEN='expired-bearer', REGISTERED_HOST='worker', REGISTERED_PORT='60000',
                       _tapisJobUUID='example-job-007', JOB_ID='fixture', USER='tester', NODE_TOKEN='node-token',
                       NODEODX_ROLE='admin', NODEODX_WORKER_ID='0', NODEODX_CHILD_INDEX='1-admin',
                       NODEODX_HOST_INDEX='1', NODEODX_JOB_INDEX='1', NODEODX_JOB_COUNT='1',
                       NODEODX_REQUIRE_REGISTRATION='0', CLUSTER_URL='https://cluster.example')
            script = 'log() { printf "%s\\n" "$*"; }\n' + helpers + registration
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            request = json.loads((root / 'request.json').read_text())
            self.assertEqual(request['body']['registrationSecret'], secret)
            self.assertNotIn('expired-bearer', ' '.join(request['args']))
            self.assertNotIn(secret, result.stdout + result.stderr)
            saved = json.loads((root / 'registration-payload.json').read_text())
            self.assertNotIn('registrationSecret', saved)
            self.assertIn('os.environ["NODEODX_REGISTRATION_SECRET"]', result.stdout)

    def test_registration_roles_and_identity(self):
        start = SOURCE.index('    REGISTRATION_UUID="${_tapisJobUUID:')
        end = SOURCE.index('    REGISTRATION_RESPONSE_FILE=', start)
        script = SOURCE[start:end] + '\nprintf "%s" "$REGISTRATION_PAYLOAD"\n'
        identities = []
        for index, role in enumerate(['admin', 'worker', 'worker', 'worker']):
            env = dict(os.environ, _tapisJobUUID='example-job-007', JOB_ID='fixture', USER='tester',
                       REGISTERED_HOST='ls6.example', REGISTERED_PORT=str(60000 + index),
                       NODE_TOKEN='fixture', NODEODX_ROLE=role, NODEODX_WORKER_ID=str(index),
                       NODEODX_CHILD_INDEX=f'{index + 1}-{role}', NODEODX_HOST_INDEX=str(index + 1),
                       NODEODX_JOB_INDEX='1', NODEODX_JOB_COUNT='1')
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload['role'], role)
            self.assertEqual(payload['workerId'], index)
            self.assertEqual(payload['tapisJobUuid'], 'example-job-007')
            identities.append(payload['registrationUuid'])
        self.assertEqual(identities[0], 'example-job')
        self.assertEqual(len(set(identities)), 4)


if __name__ == '__main__':
    unittest.main()
