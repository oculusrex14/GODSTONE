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

## D-T02-a [ACCEPTED] Requirement alias resolution in the runner
TASKS.json manifests declare `requires: 'python'` while the machine
provides `python3` only (PEP 394: the unversioned alias is optional).
The runner accepts a versioned provider when it is the very
executable argv[0] names (python3 / python3.14 satisfies python);
unrelated tools never qualify and genuinely missing tools still
BLOCK. First observed as a real BLOCKED outcome, then resolved.

## D-T02-b [ACCEPTED] Harness discovery (read-only)
omp (Oh My Pi CLI) found at /opt/homebrew/bin/omp, self-reported
version 'omp/18.1.13'; `omp models ls --json` listed 742 models
(read-only catalog; captured under private evidence T02/probes/).
No model session was launched and no unverified launch command was
recorded. ollama 0.33.2 is present but does not satisfy the
NATIVE_MODELS gate. DGX/Linux: absent. JDK: unusable on this
machine (Android Gradle targets blocked at environment level).

## D-T02-c [ACCEPTED] Evidence placement and id uniqueness
Runner command entries follow the section 25 schema (exit_code, test
counts as UNKNOWN when absent); logs live under <evidence>/<task>/logs
with sha256 recorded; entry ids get a -NNN suffix when a log name
would collide, keeping the log append-only and every record addressable.

## D-T08-a [ACCEPTED] SessionSlot is the single serialization authority
All relation-scoped operations (handshake completion, seal, open, readiness
query, retire, and the drop transition) enter their relation through one lock
owned by the slot, never through the manager-wide map lock. The manager lock
guards only the registry mapping itself. Destructive lease destroy is routed
outside the serialize lock to avoid reentrancy hazards, and retired slots are
removed together with their lock entries; the remembered-generation registry is
bounded (256) so a replacement handle for the same relation carries generation
+1. Both engines implement the identical design.

## D-T08-b [ACCEPTED] Self-witnessing serialisation and teardown parity
Each slot records the peak number of distinct threads ever simultaneously
inside its serialize region (Kotlin: Thread identity + depth; Swift:
pthread_t identity + depth). The concurrency test asserts the peak stays below
2 after the join, so a lock-free mutation cannot survive silently. This
witness was required: the M2 mutation (serialize made non-locking) initially
SURVIVED the Swift host because retire() bypassed the slot lock; routing
retire through serialize on both engines (parity fix) made M2 kill on both
(negative evidence: M2b Android concurrency failure, M2c Swift 24 witness-
peak assertion failures). Lesson recorded: teardown paths must share the same
entry point as the operations they terminate, or the invariant is untested.
