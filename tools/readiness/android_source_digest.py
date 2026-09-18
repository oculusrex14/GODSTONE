#!/usr/bin/env python3
"""Print the digest over the sources one Android lane compiles.

Kept as its OWN script so the runner and the control share ONE definition of "the sources" --
*two copies of that list would drift, and a digest over a different list is a different claim.*
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ci'))
from check_lane_results import _android_source_digest  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('--lane', default='android:app')
print(_android_source_digest(ap.parse_args().lane))
