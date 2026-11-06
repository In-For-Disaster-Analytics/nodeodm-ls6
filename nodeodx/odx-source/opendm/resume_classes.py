import json
import os

RESUME_CLASSES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'resume_classes.json')

# Note: orthophoto-resolution is class O although it also caps the undistorted image size
# (gsd.image_max_size); class O re-runs regenerate undistortion anyway while keeping the seeded point cloud.
# Class M includes options consumed only by merge/postprocess on the primary (or no-ops for submodels)
# Lowest to highest: the work a change requires is the highest class among the changed options
CLASS_ORDER = ['M', 'O', 'F']

_table = None

def load():
    """
    :return the class table (version, classes, options, default) shipped with the engine
    """
    global _table
    if _table is None:
        with open(RESUME_CLASSES_PATH, 'r', encoding='utf-8') as f:
            _table = json.load(f)
    return _table

def option_class(name):
    table = load()
    return table['options'].get(name.lstrip('-').replace('_', '-'), table['default'])

def classify(changed_option_names):
    """
    Class of work that a set of changed options requires for a split project.
    Options missing from the table are classified as the table default (F, full run).

    :param changed_option_names: iterable of option names (dash or underscore form)
    :return 'M' (merge only), 'O' (submodels re-run from odm_meshing) or 'F' (full run).
        An empty set of changes is 'M'.
    """
    result = CLASS_ORDER[0]
    for name in changed_option_names:
        cls = option_class(name)
        if CLASS_ORDER.index(cls) > CLASS_ORDER.index(result):
            result = cls
    return result

def submodel_rerun_stage(cls):
    """
    :return the stage that submodels re-run from for this class, or None when
        submodels are not re-run (class M) or the whole task runs (class F)
    """
    return load()['classes'].get(cls, {}).get('submodelRerunFrom')
