# DECISIONS

Statuses: ACCEPTED (builder-recorded, not external approval) / PROPOSED / SUPERSEDED.

## D-T01-a [ACCEPTED] Private evidence root
Path: /Users/oculus/Projects/GODSTONE_BUILDER_EVIDENCE (sibling of the original
checkout; outside every worktree, so it can never dirty either tree).

## D-T01-b [ACCEPTED] Continuation worktree
Path: /Users/oculus/Projects/GODSTONE_BUILDER, branch codex/production-blueprint,
created from exactly b5c3d3d394b70cf356cdde33b47511dad7cbb95c; original checkout
untouched on codex/archive-reliability (status bytes compared before/after, equal).

## D-T01-c [ACCEPTED] Planning-snapshot drift is documented, not corrected
The planning snapshot reported 33 porcelain entries (not a file count); the live
inventory counts 156 entries (18 modified + 138 untracked, the import package
included). Inventory bytes take precedence over snapshot prose.

## D-T01-d [ACCEPTED] Ignored-path classification policy
Relevant fixtures: allowlisted prefixes content/ crypto/ safety/ meshsim/ wire/
dist/ artifacts/ scripts/ ci/ provenance.json, minus build-noise markers
(__pycache__/, *.pyc, build dirs, venvs). Six such fixtures were inventoried and
preserved; they are debug/past-run outputs, NOT approved inputs.

## D-T01-e [ACCEPTED] Builder runtime facts (this environment)
Python 3.14.4: shutil exposes copy2/copyfile spellings; the copy_file spelling is
absent here (AttributeError at import-time during T01 development). Tools must
adapt; the classic spelling is reserved for runtimes that provide it.
