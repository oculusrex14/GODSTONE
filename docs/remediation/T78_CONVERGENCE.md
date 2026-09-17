# T78 CONVERGENCE — GODSTONE remediation against AUDIT_FINAL_2026-09-15 (AUDIT-003-R1)

**Candidate SHA (exact, single, clean): `302cdf154e6a58b9efef2d666254dff3ca020b90`** — working tree clean at the time of writing (`git status --porcelain` → 0 entries).
Audited baseline the findings were raised against: `c683a2bf0b5bcdd4a662d98f7542351501b57b7c`.
Branch: `codex/production-blueprint` (pushed).

## Ledger at this SHA

```
FIX_SUBMITTED 45 · OPEN 3 · PARTIAL 6        (54 findings total)
VERIFIED_FIXED  0        — ABSENT BY RULE: only an independent audit may write it.
```

The span began with `OPEN 7 · FIX_SUBMITTED 41` and five findings carrying **no work at all**.

## THE TWO SCOPES, REPORTED SEPARATELY

### Scope A — LIGHT Archive (14 findings)
The LIGHT-Archive findings are **not this span's work**: they were submitted before it began, and this span did not reopen them.
**Nothing in this candidate alters their standing**, and none of them may be treated as verified on the strength of this SHA.

### Scope B — Mesh/Oracle (40 findings)
This span's work lies here. At `302cdf154e6a58b9efef2d666254dff3ca020b90`:
* **the five findings named by the human (CRYPTO-002, CRYPTO-005, GS-INBOX-001, GS-INTEGRATION-001, GS-STORE-006) are ALL `FIX_SUBMITTED`**;
* **four of them rest on measurements read by name in the full lane**, and the fifth (GS-INTEGRATION-001) on a **RED authored, measured, and then turned
  green by its own repair**;
* **the full lane at this SHA: `GodstoneMeshTests` 1187 tests, 0 failures; `GodstoneCoreTests` passed; EXIT CODE 0** — *the count having grown by the
  arms this span wrote, which is evidence no filter can manufacture*;
* **parity: all invariants hold** · **symbols: restored tree, 0 unresolved** · **evidence digests: PASSED**.

## WHAT AWAITS INDEPENDENT VERIFICATION
**ALL OF IT.** `VERIFIED_FIXED` is **zero** across the programme, and no finding in this candidate has been examined by anyone but its author. The arms
below are **the author's** proofs; an independent audit is the only thing that may call them sufficient:
* CRYPTO-005 — `testCRYPTO005_theIntentSurvivesAReopenOfTheDurableStore` (medium, round 489/511) and
  `testCRYPTO005_theCompositionPinsTheIntentBeforeTheRadioAndSurvivesAReopen` (composition, round 511);
* GS-INBOX-001 — `testDiskFailureYieldsNeitherAckNorClaimedAcceptance` and the durable-inbox / end-to-end ACK arms (round 511);
* CRYPTO-002 — the four canonical courts carrying the finding's own id (round 513);
* GS-INTEGRATION-001 — `testGSINTEGRATION001_afterAWipeTheDurableIntentMustBeGone` (RED 0.195 s → GREEN 0.010 s, rounds 514–515).

## WHAT DEPENDS ON EXTERNAL ARTIFACTS
Nothing in this candidate supplies, or claims to supply, any of the following — **and none was fabricated**:
* **a real process restart.** The card's closure clause for CRYPTO-005 asks for storage *"reopened in a NEW PROCESS"*; the arms **reopen the store from the
  same path**, which is "a new process" as far as the medium is concerned (the isle's own courts annotate that idiom) — **but no process is terminated**;
* **device / radio measurements** — for GS-STORE-006, GS-INBOX-001, CRYPTO-002 and GS-INTEGRATION-001 alike;
* **platform-encryption proofs** — GS-INBOX-001's card names them as **explicitly tracked child commits**, and **none of those child commits is taken**;
* **the Android counterparts.** The human's phase-two law requires the shared contract on **both isles**; the Mesh medium landed here is **iOS-only**.

## WHICH CLOSURE EVIDENCE IS STALE
* **Arms predating this span** — *their passing is evidence about the SHA they ran on, not about this one*;
* **CRYPTO-005's original restart arm** — it claims a restart while **reusing its medium**; round 430's sibling arm exposed exactly that by differing by one
  argument. It is carried as stale rather than quietly renamed;
* **the old in-memory paths** remaining beside the repaired ones — *`ComposedRuntime.sendDirect` still never consults an intent journal while its own
  comment claims "the durable enqueue happeneth FIRST"; the harness's radio is still an in-process `LinkFacade`*.

## WHAT THIS SPAN FOUND THAT THE AUDIT DID NOT NAME
Six corrections are recorded in the ledger's `record_corrections`, three of them **corrections of my own corrections**; and four defects were found **by
measurement rather than by reading** — *the missing medium, the blind observer (`StoreSchema.allTables`), the unkeepable contract (a `load` whose prose
promised a distinction its signature could not carry), and my own mis-binding in `insertIntent`*. Five instruments now report what the repository previously
discarded at four separate sites.

## REMAINING WORK
**PHASE TWO** — the six `PARTIAL` findings (ANDROID-05, GS-ARCHIVE-005, GS-RUNTIME-001, GS-SOS-001, GS-STORE-002, GS-STORE-004), the three remaining
`OPEN` (ANDROID-03, GS-STRESS-001, GS-UX-001), and the four external artifacts above.

**Readiness flags remain FALSE and the five external gates remain OPEN. Acquisition never closes a gate.**
