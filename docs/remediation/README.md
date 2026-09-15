# GODSTONE remediation — AUDIT-003-R1

This directory carrieth the working ledger for remediating
`AUDIT_FINAL_2026-09-15/AUDIT_REPORT.md` (AUDIT-003-R1) and its ordered
`QWEN_REMEDIATION_QUEUE.md`.

**Audited source:** `c683a2bf0b5bcdd4a662d98f7542351501b57b7c`.
**54 OPEN findings** (48 HIGH, 6 MEDIUM). Both candidate scopes are **NO-GO**.

| File | What it is |
|---|---|
| `REMEDIATION_STATE.json` | the machine-readable ledger: all 18 waves, all 54 findings (each assigned exactly once as a primary), the submission rules, the two candidate gates, the external-input lane and the convergence requirements |
| `README.md` | this protocol |

## The rules this ledger obeyeth

1. **A repair is not a closure.** Only an *independent audit* may mark
   `VERIFIED_FIXED`. Everything this work submits is `FIX_SUBMITTED`, with its
   unavailable or dependent proof named explicitly as pending.
2. **A behavioral RED comes first.** For every finding: read its card (and any R1
   supplement), move the independent failing assertion **into the canonical suite**,
   and RUN it red **before** touching production code. A compilation or setup error
   is not a behavioral red.
3. **One coherent atomic repair per finding.** A wave is a dependency stage, not
   permission to fix several findings in one broad pass.
4. **Evidence is immutable and run-specific:** exact argv and cwd, executor, source
   commit/tree, counts, and checksums. Prior failures and retries are kept
   separately, never overwritten.
5. **Only for the task at hand:** negatives, a valid positive control, and the
   relevant canonical subsystem checks.
6. **Stale evidence:** a change to a production owner invalidates the closure
   evidence of its dependents (callers, adapters, session/identity users, storage
   transactions, OS lifecycle, content/artifact consumers, release controls) until
   revalidated. Unknown dependency scope means rerunning the broader suite.
7. **Nothing may be relabelled:** a fixture is never a device result, a simulated
   counter is never a runtime measurement, and a memory harness never closes a
   runtime-persistence claim.

## Frozen

* the wire, identity and signature contracts;
* the readiness flags stay **false**;
* the five external gates (A06, APPROVED_CONTENT, NATIVE_MODELS, HARDWARE, SIGNING)
  stay **OPEN or BLOCKED**, and **no fixture may close one**;
* the audit bundle is **read-only** — this work neither edits it nor its snapshots;
* T78's recorded builder status stays `BLOCKED_EXTERNAL` as a historical ledger
  fact while its audit role is *dependency-blocked final convergence*.

## The external-input lane runs in parallel

T79 (independent protocol fixtures), T80 (approved content), T81 (native/model
artifacts), T76 (signing inputs) and T73–T75 (device scheduling) get exact requests,
owners and immutable acceptance requirements **now**. Acquisition never closes a
gate, and self-generated fixtures are never a substitute for an approval.

## The order

The 18 waves are in `REMEDIATION_STATE.json`; their sequencing comes from
`REPAIR_PLAN.json`. Wave 3b is a Mesh/Oracle branch and does not delay LIGHT;
LIGHT need not wait for nonshipping work once its own gates pass and **exclusion is
proved** (Mesh, LabMesh, Oracle, inference-native libraries and models absent from
its build graph and final artifacts).

## Convergence (T78), once per declared candidate

One **clean exact candidate SHA**: zero unresolved production symbols and zero
test-path diagnostics; no tracked or untracked residue (T77 clean at start and end,
its report outside the source tree); every applicable hosted job enabled, executed
and green, with run URL/ID/attempt and immutable log hashes; applicable approved
external inputs and physical acceptance real and bound to that candidate; fresh
artifacts satisfying profile, dependency, payload and signing policy. Local probes
never supersede a red hosted workflow, and a skipped lane is never green.


---

# THE PROTOCOL AS ENFORCED (added at round 53)

The sections above describe the repair protocol. This section recordeth what the LEDGER COURT actually
REFUSETH, because every rule here was learned by being stopped by it.

## What the court refuseth (and it was right every time)

1. **A finding may not move off `OPEN` without a BEHAVIOURAL RED.** A bare `FIX_SUBMITTED` with no red,
   commit or evidence is REFUSED -- and so is a finding whose "red" is green on both revisions. Three
   findings in this work were sent back for exactly that, and twice the red was a FALSE WITNESS that
   passed on the pre-repair product too (`GS-ARCHIVE-005`, `GS-STORE-001`); both were reverted rather than
   kept, and the episodes are recorded beside the findings.
2. **A compile failure is NOT a red.** The pre-repair run must EXECUTE and FAIL on an assertion.
3. **A SKIPPED arm proveth nothing.** An arm that cannot find the thing it addresses must FAIL on the
   rename, never skip.
4. **The audit bundle is READ-ONLY** and its digests are re-verified by `test_audit_evidence.py`; the
   original checkout's declared addition GROWS and a SHRINK is refused.
5. **`VERIFIED_FIXED` is not this work's to write.** Only an independent audit may write it.

## What every submission carrieth

- the finding ID; the changed files and functions; **the actual runtime caller**;
- the red: its case name, argv, cwd, the OBSERVED outcome, and the immutable log with its sha256;
- the green: the same, after the repair, with the negative cases and the POSITIVE CONTROL that came with
  them; the canonical subsystem checks; and what the change INVALIDATED in dependent evidence;
- an explicit `pending_proof` list. Unavailable proof is stated as unavailable -- never substituted.

## Where a red liveth while it is red

A red-by-design arm must NOT sit in a lane that is expected green: Gradle and Swift both run EVERY test
source in a module, so a red arm inside one reddens that lane (and the audit's convergence requires the
lanes green). The red liveth in `tools/readiness/audit_probes/` -- `kotlin/` or `swift/` for the compiled
isles -- with its RUN RECIPE in that directory's README, and the repair MOVES it into the canonical lane.
That move is part of the repair, not a preliminary.

## The four arm defects this work paid for

- An arm green on BOTH revisions proveth nothing.
- An arm may read the CODE while its charge liveth in a COMMENT -- and the reverse: `GS-STORE-003`'s W01
  FAILED on this work's own comment QUOTING `DROP TABLE`.
- An arm about WIRING that accepteth a SPELLING will pass on a comment that merely NAMETH the thing.
- A red that CANNOT BE SATISFIED is not a red (`GS-STORE-001`'s arm A first forbade the only native seam a
  host court hath, which demanded the impossible).

## A control that PROTECTS the bypass

Expect to find one: `T52`'s deputy arms, `T61`'s null-artifact arm, `T29`'s stubbed native opener and the
SQLite stale-version court all ASSERTED the behaviour the audit condemned. Reverse them, and record the
reversal IN THE ARM so the next reader seeth what it once required.

## What is NOT proven anywhere in this work

No hosted lane (every result is a LOCAL reproduction), no device, no independent verification, and final
convergence (T78) has not run: it requireth ONE clean exact SHA with fresh green canonical AND hosted
controls. Readiness stayeth FALSE and the five external gates stay OPEN or BLOCKED.
