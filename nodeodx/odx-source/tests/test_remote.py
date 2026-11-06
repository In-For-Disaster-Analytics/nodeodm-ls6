import json
import os
import tempfile
import time
import unittest
import threading
import random
from unittest.mock import patch
from opendm import config, system, types
from opendm import remote
from opendm.remote import LocalRemoteExecutor, Task, ToolchainTask, NodeTaskLimitReachedException
from pyodm import Node, exceptions
from pyodm.types import TaskStatus

class TestRemote(unittest.TestCase):
    def setUp(self):
        self.lre = LocalRemoteExecutor('http://localhost:9001')

        projects = []
        for i in range(9):
            projects.append('/submodels/submodel_00' + str(i).rjust(2, '0'))
        self.lre.set_projects(projects)

    def test_lre_init(self):
        self.assertFalse(self.lre.node_online)

    def test_processing_logic(self):
        # Fake online status
        self.lre.node_online = True

        MAX_QUEUE = 2
        class nonloc:
            local_task_check = False
            remote_queue = 1
            should_fail = False
            task_limit_reached = False

        class OdmTaskMock:
            def __init__(self, running, queue_num):
                self.running = running
                self.queue_num = queue_num
                self.uuid = 'xxxxx-xxxxx-xxxxx-xxxxx-xxxx' + str(queue_num)
            
            def info(self, with_output=None):
                class StatusMock:
                    status = TaskStatus.RUNNING if self.running else TaskStatus.QUEUED
                    processing_time = 1
                    output = "test output"
                return StatusMock()

            def remove(self):
                return True

        class TaskMock(Task):
            def process_local(self):
                # First task should be 0000 or 0001
                if not nonloc.local_task_check: nonloc.local_task_check = self.project_path.endswith("0000") or self.project_path.endswith("0001")
                
                if nonloc.should_fail:
                    if self.project_path.endswith("0006"):
                        raise exceptions.TaskFailedError("FAIL #6")
                        
                time.sleep(1)

            def process_remote(self, done):
                time.sleep(0.05) # file upload

                self.remote_task = OdmTaskMock(nonloc.remote_queue <= MAX_QUEUE, nonloc.remote_queue)
                self.params['tasks'].append(self.remote_task)
                
                if nonloc.should_fail:
                    if self.project_path.endswith("0006"):
                        raise exceptions.TaskFailedError("FAIL #6")
                    
                nonloc.remote_queue += 1

                # Upload successful
                done(error=None, partial=True)

                # Async processing
                def monitor():
                    try:
                        if nonloc.task_limit_reached and random.randint(0, 4) == 0:
                            nonloc.remote_queue -= 1
                            raise NodeTaskLimitReachedException("Random fail!")

                        if not nonloc.task_limit_reached and self.remote_task.queue_num > MAX_QUEUE:
                            nonloc.remote_queue -= 1
                            nonloc.task_limit_reached = True
                            raise NodeTaskLimitReachedException("Delayed task limit reached")
                        time.sleep(0.5)
                        nonloc.remote_queue -= 1
                        done()
                    except Exception as e:
                        done(e)

                t = threading.Thread(target=monitor)
                self.params['threads'].append(t)
                t.start()

        self.lre.run(TaskMock)
        self.assertTrue(nonloc.local_task_check)

        nonloc.should_fail = True
        nonloc.remote_queue = 1
        nonloc.task_limit_reached = False

        with self.assertRaises(exceptions.TaskFailedError):
            self.lre.run(TaskMock)


class TestToolchainSeeds(unittest.TestCase):
    def execute(self, **params):
        task = ToolchainTask('/submodels/submodel_0000', None, dict({'rerun': True}, **params))
        with patch.object(ToolchainTask, 'execute_remote_task') as execute:
            task.process_remote(lambda error=None: None)
        return execute.call_args[1]

    def test_initial_run_seeds_and_outputs(self):
        call = self.execute()
        self.assertEqual(call['seed_files'], ["opensfm/camera_models.json", "opensfm/reference_lla.json",
                                              "opensfm/reconstruction.json", "opensfm/tracks.csv"])
        self.assertEqual(call['seed_touch_files'], ["opensfm/features/empty", "opensfm/matches/empty", "opensfm/exif/empty"])
        self.assertEqual(call['outputs'], ["odm_orthophoto/cutline.gpkg", "odm_orthophoto/odm_orthophoto_cut.tif",
                                           "odm_orthophoto/odm_orthophoto_feathered.tif", "odm_dem", "odm_report",
                                           "odm_georeferencing",
                                           "odm_filterpoints/point_cloud.ply", "odm_filterpoints/point_cloud_stats.json"])

    def test_class_o_seeds_and_outputs(self):
        call = self.execute(submodel_rerun_from='odm_meshing')
        self.assertEqual(call['seed_files'], ["opensfm/camera_models.json", "opensfm/reference_lla.json",
                                              "opensfm/reconstruction.json", "opensfm/tracks.csv",
                                              "odm_filterpoints/point_cloud.ply", "odm_filterpoints/point_cloud_stats.json"])
        self.assertEqual(call['seed_touch_files'], ["opensfm/features/empty", "opensfm/matches/empty", "opensfm/exif/empty",
                                                    "opensfm/undistorted/openmvs/scene_dense_dense_filtered.ply"])
        self.assertEqual(call['outputs'], ["odm_orthophoto/cutline.gpkg", "odm_orthophoto/odm_orthophoto_cut.tif",
                                           "odm_orthophoto/odm_orthophoto_feathered.tif", "odm_dem", "odm_report",
                                           "odm_georeferencing"])

    def test_class_o_marker_is_the_openmvs_guard_and_no_marker_is_a_seed(self):
        tree = types.ODM_Tree('/project')
        self.assertIn(os.path.relpath(tree.openmvs_model, tree.root_path), remote.CLASS_O_SEED_MARKERS)
        self.assertIn(os.path.relpath(tree.filtered_point_cloud, tree.root_path), remote.CLASS_O_SEED_FILES)
        self.assertIn(os.path.relpath(tree.filtered_point_cloud_stats, tree.root_path), remote.CLASS_O_SEED_FILES)
        self.assertFalse(set(remote.CLASS_O_SEED_FILES) & set(remote.CLASS_O_SEED_MARKERS))

    def test_run_ids(self):
        with patch('opendm.remote.Node'):
            self.assertEqual(LocalRemoteExecutor('http://localhost:9001').params['class_run_id'], remote.INITIAL_RUN_ID)
            first = LocalRemoteExecutor('http://localhost:9001', rerun=True).params['class_run_id']
            second = LocalRemoteExecutor('http://localhost:9001', submodel_rerun_from='odm_meshing').params['class_run_id']
            self.assertNotIn(remote.INITIAL_RUN_ID, [first, second])
            self.assertNotEqual(first, second)


class TestToolchainStamps(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.submodels = self.temp.name

    def stamp(self, name, content=None, run_id=None):
        path = os.path.join(self.submodels, name)
        os.makedirs(path)
        stamp = os.path.join(path, 'toolchain_completed.txt')
        if run_id is not None:
            remote.write_toolchain_stamp(stamp, run_id, 'hash')
        elif content is not None:
            with open(stamp, 'w') as f:
                f.write(content)

    def test_stamp_roundtrip_and_legacy(self):
        self.stamp('submodel_0000', run_id='abc')
        self.stamp('submodel_0001', content='')
        self.stamp('submodel_0002', content='Done!\n')
        read = lambda n: remote.read_toolchain_stamp(os.path.join(self.submodels, n, 'toolchain_completed.txt'))
        self.assertEqual(read('submodel_0000'), {'classRunId': 'abc', 'optionsHash': 'hash'})
        self.assertEqual(read('submodel_0001')['classRunId'], remote.LEGACY_RUN_ID)
        self.assertEqual(read('submodel_0002')['classRunId'], remote.LEGACY_RUN_ID)

    def test_toolchain_writes_stamp_after_success(self):
        args = config.config(["--project-path", "/datasets"])
        path = os.path.join(self.submodels, 'submodel_0000')
        os.makedirs(path)
        task = ToolchainTask(path, None, {'rerun': False, 'class_run_id': 'run-1'})
        task.write_stamp()
        with open(os.path.join(path, 'toolchain_completed.txt')) as f:
            stamp = json.load(f)
        self.assertEqual(stamp['classRunId'], 'run-1')
        self.assertEqual(len(stamp['optionsHash']), 40)

    def test_consistent_stamps_pass(self):
        self.stamp('submodel_0000', run_id='abc')
        self.stamp('submodel_0001', run_id='abc')
        self.stamp('submodel_0002')  # no stamp (e.g. local workflow): ignored
        remote.check_consistent_toolchain_stamps(self.submodels)

    def test_legacy_stamps_are_one_run(self):
        self.stamp('submodel_0000', content='')
        self.stamp('submodel_0001', content='Done!\n')
        remote.check_consistent_toolchain_stamps(self.submodels)

    def test_mixed_stamps_are_refused(self):
        self.stamp('submodel_0000', run_id='new')
        self.stamp('submodel_0001', run_id='old')
        with self.assertRaisesRegex(system.ExitException, 'Mixed submodel runs.*Run the task fully'):
            remote.check_consistent_toolchain_stamps(self.submodels)

    def test_legacy_mixed_with_initial_is_refused(self):
        self.stamp('submodel_0000', content='')
        self.stamp('submodel_0001', run_id=remote.INITIAL_RUN_ID)
        with self.assertRaisesRegex(system.ExitException, 'Run the task fully'):
            remote.check_consistent_toolchain_stamps(self.submodels)

    def test_already_processed_keeps_the_existing_stamp(self):
        path = os.path.join(self.submodels, 'submodel_0000')
        os.makedirs(path)
        stamp = os.path.join(path, 'toolchain_completed.txt')
        with open(stamp, 'w') as f:
            f.write('Done!\n')
        task = ToolchainTask(path, None, {'rerun': False, 'class_run_id': 'run-2'})
        results = []
        with patch.object(ToolchainTask, 'execute_remote_task') as execute:
            task.process_remote(lambda error=None, **kw: results.append(error))
        execute.assert_not_called()
        self.assertEqual(results, [None])
        with open(stamp) as f:
            self.assertEqual(f.read(), 'Done!\n')

    def test_options_hash_ignores_rerun_stage(self):
        base = remote.options_hash(config.config(["--project-path", "/d", "--dsm"]))
        rerun = remote.options_hash(config.config(["--project-path", "/d", "--dsm", "--rerun-from", "merge",
                                                   "--submodel-rerun-from", "odm_meshing"]))
        self.assertEqual(base, rerun)
        self.assertNotEqual(base, remote.options_hash(config.config(["--project-path", "/d"])))

    def test_legacy_mixed_with_new_is_refused(self):
        self.stamp('submodel_0000', run_id='new')
        self.stamp('submodel_0001', content='')
        with self.assertRaises(system.ExitException):
            remote.check_consistent_toolchain_stamps(self.submodels)

    def test_missing_class_o_seeds(self):
        self.stamp('submodel_0000')
        path = os.path.join(self.submodels, 'submodel_0000')
        self.assertEqual(remote.missing_class_o_seeds(path), remote.CLASS_O_SEED_FILES)
        self.assertNotIn('odm_georeferencing/odm_georeferenced_model.bounds.gpkg', remote.CLASS_O_SEED_FILES)
        for f in remote.CLASS_O_SEED_FILES:
            os.makedirs(os.path.dirname(os.path.join(path, f)), exist_ok=True)
            open(os.path.join(path, f), 'w').close()
        self.assertEqual(remote.missing_class_o_seeds(path), [])

if __name__ == '__main__':
    unittest.main()