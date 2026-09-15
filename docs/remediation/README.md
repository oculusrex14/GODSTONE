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
