"""Check launcher configuration without starting containers or contacting Tapis."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "nodeodx" / "tapisjob_app.sh"
SOURCE = LAUNCHER.read_text()


class CapacityTests(unittest.TestCase):
    def generate(self, override=None, shared='0'):
        # Execute the actual validation and config writer, omitting launch/network steps.
        preamble = SOURCE[SOURCE.index('MAX_CONCURRENCY='):SOURCE.index('launch_multi_node_children()')]
        writer = SOURCE[SOURCE.index('export NODEODX_CONFIG_PATH='):SOURCE.index("python3 - \"$CONFIG_PATH\" <<'PY'")]
        python_block = SOURCE.split("python3 - \"$CONFIG_PATH\" <<'PY'\n", 1)[1].split('\nPY', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            env = dict(os.environ, CONFIG_PATH=str(config_path), NODE_TOKEN='test',
                       NODEODX_IMPORT_PATH_ROOTS=directory, NODEODX_CLEANUP_TASKS_AFTER='0',
                       BASE_WORK_ROOT=directory, _tapisJobUUID='fixture-job-007',
                       NODEODX_SHARED_SUBMODEL_V1=shared)
            env.pop('NODEODX_PARALLEL_QUEUE_PROCESSING', None)
            if override is not None:
                env['NODEODX_PARALLEL_QUEUE_PROCESSING'] = override
            result = subprocess.run(['bash', '-c', preamble + writer +
                                     'python3 - "$CONFIG_PATH" <<\'PY\'\n' + python_block + '\nPY\n'],
                                    env=env, capture_output=True, text=True)
            return result, json.loads(config_path.read_text()) if config_path.exists() else None

    def test_default_and_override(self):
        for override, expected in [(None, 64), ('8', 8), ('1', 1)]:
            result, config = self.generate(override)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(config['parallelQueueProcessing'], expected)
            self.assertEqual(config['maxConcurrency'], 12)
            self.assertFalse(config['sharedSubmodelV1'])

    def test_shared_config_opt_in(self):
        result, config = self.generate(shared='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(config['sharedSubmodelV1'])
        self.assertTrue(config['sharedSubmodelRoot'])
        self.assertEqual(config['sharedSubmodelJobUuid'], 'fixture-job-007')
        result, config = self.generate(shared='yes')
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(config)

    def test_engine_contract_guard(self):
        start = SOURCE.index('if [[ "$NODEODX_SHARED_SUBMODEL_V1" == "1" ]]')
        end = SOURCE.index('DEPENDENCY_CHECK_SCRIPT=', start)
        guard = SOURCE[start:end]
        for enabled, job, engine_status, expected in [
            ('0', '', 0, 0), ('1', 'fixture-job', 0, 0),
            ('1', '', 0, 2), ('1', 'fixture-job', 1, 1)
        ]:
            env = dict(os.environ, NODEODX_SHARED_SUBMODEL_V1=enabled,
                       _tapisJobUUID=job, RUNTIME_DIR='/scratch/fixture/1-admin/runtime',
                       BASE_WORK_ROOT='/scratch/fixture', SIF_PATH='fixture.sif',
                       MOCK_ENGINE_STATUS=str(engine_status))
            with tempfile.TemporaryDirectory() as directory:
                env['LOG_FILE'] = str(Path(directory) / 'log')
                script = '''log() { printf '%s\\n' "$*"; }
apptainer() { return "$MOCK_ENGINE_STATUS"; }
declare -a NODEODX_BIND_ARGS=()
''' + guard + '\nprintf "engine=%s marker=%s\\n" "$APPTAINERENV_ODX_SHARED_SUBMODEL_V1" "$APPTAINERENV_NODEODX_SHARED_SUBMODEL_ENGINE_V1"\n'
                result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected == 0:
                    self.assertIn(f'engine={enabled} marker={enabled}', result.stdout)

    def test_invalid_capacity(self):
        for override in ['0', '-1', 'abc', '1.5']:
            result, config = self.generate(override)
            self.assertEqual(result.returncode, 2)
            self.assertIsNone(config)
            self.assertIn('must be a positive integer', result.stderr)


if __name__ == '__main__':
    unittest.main()
