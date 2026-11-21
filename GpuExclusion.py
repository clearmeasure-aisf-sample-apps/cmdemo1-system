#!/usr/bin/env python3
"""Name-resolution shim for the cmdemo1-system#816 GPU-exclusion acceptance commands.

The acceptance commands run the tests by dotted name, e.g.:

    python3 -m unittest factory/pi/test_item_loop.py GpuExclusion.test_excluded_reads_env_and_file

The `python -m unittest` loader resolves `GpuExclusion.test_...` by importing a
module named `GpuExclusion` and looking up `test_...` in it, so the class in
factory/pi/test_item_loop.py alone is not addressable. This module re-exposes
every GpuExclusion test method as a module-level one-test suite; the tests
themselves live only in the GpuExclusion class in factory/pi/test_item_loop.py.
"""
import unittest

from factory.pi.test_item_loop import GpuExclusion

for _name in unittest.defaultTestLoader.getTestCaseNames(GpuExclusion):
    globals()[_name] = unittest.TestSuite([GpuExclusion(_name)])
