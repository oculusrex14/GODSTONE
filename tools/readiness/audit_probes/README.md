# Adopted audit probes — the RED harness for waves 3a and 8

`test_audit_artifacts.py` is the audit's own 12-case final suite
(`AUDIT_FINAL_2026-09-15/evidence/AUDIT-003/audit_final_negative_tests.py`) adopted with its
assertions intact. **Seven of its twelve arms are RED on this tree**, which is the point: they are
the reproduced defects of

| Finding | Red arm | Observed |
|---|---|---|
| GS-SUPPLY-001 | parent traversal / source symlink | `{"rejected": false, "wrote_outside_destination": true}` |
| GS-DIAG-001 | unique peer churn | `{"ring": 16, "retained_relation_keys": 10000}` |
| GS-PACKAGE-001 | forbidden signed entitlement / arm64 macOS binary | `{"verdict": "PASS", ...}` |
| GS-PACKAGE-002 | corrupt / partial AAB native libraries | `{"verdict": "PASS", ...}` |

The five arms that already pass are the suite's own POSITIVE CONTROLS — a valid cache restore,
changed bytes refused, a bounded ring, a valid source bundle and a valid APK — so the red suite is
not one that refuses everything.

## Why this directory and not `tests/`

`python3 -m unittest discover -s tools/readiness/tests` is the GREEN lane: it must never be red.
A probe that is red BY DESIGN therefore liveth here, and **each finding's repair MOVES its arm into
`tools/readiness/tests/` as it lands** — the card's "move the independent failing assertion into
the canonical subsystem suite" is part of the REPAIR, not a preliminary. When the last arm of a
probe is green, its file moves; the directory disappears with them.

Run them with:

```
python3 -m unittest discover -s tools/readiness/audit_probes -v
```
