# ADR-0001: Git tree is executable source of truth

Status: Accepted for remediation.

The Git tree at the recorded commit is the executable source. `Godstone.xlsx`, V3, and V4 aggregate documents are historical traceability artifacts and may not overwrite the tree. Any extraction tool must be read-only or deterministic verification-only. The current private-repository transfer limitation is documented separately and does not change this decision.
