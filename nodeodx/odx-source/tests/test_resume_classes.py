import argparse
import unittest
from opendm import config, resume_classes


class RecordingParser(argparse.ArgumentParser):
    """Lists options the way NodeODX's odmOptionsToJson.py does"""
    options = {}

    def add_argument(self, *args, **kwargs):
        argparse.ArgumentParser.add_argument(self, *args, **kwargs)
        self.options[args[0]] = kwargs

    def add_mutually_exclusive_group(self):
        return RecordingParser()


class TestResumeClasses(unittest.TestCase):
    def parser_options(self):
        parser = argparse.ArgumentParser()
        config.config(["--project-path", "/datasets"], parser=parser)
        return {o[2:] for a in parser._actions for o in a.option_strings if o.startswith("--")} - {"help"}

    def test_every_option_is_classified(self):
        table = resume_classes.load()
        internal = {"submodel-rerun-from"}
        self.assertEqual(self.parser_options() - internal - set(table["options"]), set())
        self.assertEqual(set(table["options"]) - self.parser_options(), set())
        self.assertTrue(set(table["options"].values()) <= {"M", "O", "F"})
        self.assertEqual(table["default"], "F")
        self.assertEqual(table["version"], 1)
        self.assertEqual(sorted(table["classes"]), ["M", "O"])

    def test_classify(self):
        self.assertEqual(resume_classes.classify(["merge", "tiles"]), "M")
        self.assertEqual(resume_classes.classify(["merge", "dsm"]), "O")
        self.assertEqual(resume_classes.classify(["dsm", "pc-quality"]), "F")
        self.assertEqual(resume_classes.classify(["dem_resolution"]), "O")
        self.assertEqual(resume_classes.classify(["--cog"]), "M")
        self.assertEqual(resume_classes.classify([]), "M")

    def test_merge_only_options(self):
        for name in ["pc-csv", "pc-las", "pc-ept", "pc-copc", "gltf", "orthophoto-compression", "orthophoto-png",
                     "orthophoto-kmz", "orthophoto-no-tiled", "copy-to", "skip-3dmodel", "cog"]:
            self.assertEqual(resume_classes.classify([name]), "M", name)
        self.assertEqual(resume_classes.classify(["pc-classify"]), "O")
        self.assertEqual(resume_classes.classify(["pc-quality"]), "F")

    def test_unknown_options_default_to_full(self):
        self.assertEqual(resume_classes.classify(["not-an-option"]), "F")
        self.assertEqual(resume_classes.classify(["merge", "not-an-option"]), "F")

    def test_submodel_rerun_stage(self):
        self.assertIsNone(resume_classes.submodel_rerun_stage("M"))
        self.assertEqual(resume_classes.submodel_rerun_stage("O"), "odm_meshing")
        self.assertIsNone(resume_classes.submodel_rerun_stage("F"))
        self.assertIn(resume_classes.submodel_rerun_stage("O"), config.processopts)


class TestInternalArguments(unittest.TestCase):
    def setUp(self):
        self.saved = config.args
        self.addCleanup(setattr, config, "args", self.saved)

    def test_submodel_rerun_from_is_not_a_public_option(self):
        RecordingParser.options = {}
        args = config.config(["--project-path", "/datasets", "--submodel-rerun-from", "odm_meshing"], parser=RecordingParser())
        self.assertEqual(args.submodel_rerun_from, "odm_meshing")
        self.assertIn("--project-path", RecordingParser.options)
        self.assertNotIn("--submodel-rerun-from", RecordingParser.options)
        self.assertNotIn("submodel-rerun-from", repr(RecordingParser.options))

    def test_submodel_rerun_from_defaults_to_none(self):
        self.assertIsNone(config.config(["--project-path", "/datasets"]).submodel_rerun_from)

    def test_submodel_rerun_from_rejects_unknown_stage(self):
        with self.assertRaises(SystemExit):
            config.config(["--project-path", "/datasets", "--submodel-rerun-from", "nope"])

    def test_optimize_disk_space_refused_for_split_cluster_runs(self):
        with self.assertRaises(SystemExit):
            config.config(["--project-path", "/datasets", "--split", "200",
                           "--sm-cluster", "http://localhost:3000", "--optimize-disk-space"])

    def test_optimize_disk_space_allowed_without_cluster(self):
        args = config.config(["--project-path", "/datasets", "--split", "200", "--optimize-disk-space"])
        self.assertTrue(args.optimize_disk_space)


if __name__ == "__main__":
    unittest.main()
