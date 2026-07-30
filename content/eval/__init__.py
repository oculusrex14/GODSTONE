"""Offline evaluation harness for the Godstone Archive.

Exists so that `python -m content.eval.grounding` resolves. Deliberately empty
otherwise: nothing here should run at import time, because the CI job imports
this package before any model or embedding weights are present.
"""
