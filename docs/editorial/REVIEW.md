# Editorial review and the medical disclaimer

Audit **A-09** blocked shipping on two things: no first-run disclaimer, and no
documented editorial review. Both are closed here. Neither is code.

## Why this is a blocker and not a nicety

The Archive tells a frightened person where to put a tourniquet and how much
bleach to put in a litre of water. If a chunk is wrong, or is retrieved out of
the context that made it safe, the failure mode is not a bad review — it is a
death. Every other control in this repository exists to stop the *software*
inventing an answer. Nothing in the software can stop a *source* being wrong.

## The disclaimer

Shown on first launch, before any content is reachable, and never auto-dismissed.
Implemented in `DisclaimerGate` on both platforms and enforced by Invariant H:
the Archive and Oracle destinations are unreachable until it is acknowledged.

Text is deliberately short, plain, and does not reassure:

> **Godstone is a reference, not a rescuer.**
>
> This app carries survival and first-aid documents so you can read them with no
> signal. It is **not medical advice** and it is **not a substitute for
> professional care**.
>
> If emergency services can be reached, contact them first. Always.
>
> The app answers only from the documents it carries, and refuses when they do
> not cover your question. That refusal is the app working correctly — it means
> go and find help, not try harder here.

## The editorial gate

Every document entering the Archive passes all six, recorded in
`content/seed/sources.yaml` and enforced by `content/ingest/build_archive.py`:

1. **Primary source.** Traceable to a named published guideline. No survival
   wikis, no aggregators, no "commonly recommended".
2. **Licence permits redistribution and derivation.** Chunking is unambiguously
   a derivative work.
3. **Clinical review** by someone qualified in that domain, named in the front
   matter with a date. `reviewed_by` and `reviewed_on` are now REQUIRED fields.
4. **Chunk-boundary check.** Every chunk must be safe read *alone*, because
   retrieval will surface it alone. "Apply the tourniquet" without "never over a
   joint" is a lethal chunk even though the document is correct.
5. **Reading level ≤ 9.** Verified at build time.
6. **Contraindications travel with the procedure.** A warning separated from its
   step by a chunk boundary has been deleted, not stored.

Point 4 is the one that is specific to this architecture and the one most likely
to be skipped, because the *document* passes review while the *chunk* does not.

## The held-out evaluation

The in-repo probes (`safety/probes.py`, `content/eval/grounding.py`) ask a
handful of questions against a small demo corpus. That proves the gate is wired.
It does not establish that the product answers safely across a clinical domain,
and nothing in this repository may claim otherwise on that evidence.

`content/eval/heldout.py` carries the other half: a *held-out* manifest of
adversarial cases, each bound to the exact digest of the approved corpus and of
the model lock under test, each carrying a category label, each reviewed by a
named human under blinding, and each accounted for in a complete-case ledger.
The families are the ones this architecture actually fails at:

| family | what it asks of the product |
| --- | --- |
| `well_supported` | it must answer; a gate that refuses everything is as broken as one that allows everything, it merely fails in the direction that survives review |
| `numerical_conflict` | evidence and question disagree on a quantity |
| `qualifier_conflict` | the passage carries a condition the question drops |
| `context_conflict` | the passage is real but wrong for this tier or this population |
| `unanswerable` | no passage can support an answer |
| `malicious_retrieved_instruction` | retrieved text tries to instruct the model |
| `harmful_source_substitution` | a poisoned passage replaces the true one |

The report counts false-allows and false-blocks by category and keeps an
explicit uncertainty bucket (caveated answers, reviewer abstentions, undecided
reviews). Reviewer packets are keyed by opaque tokens and withhold the family,
the expected verdict and the category label, so a reviewer grades the behaviour
rather than the harness's own answer key. A decision that no human recorded is
never turned into an acceptance: the evaluation is simply INCOMPLETE.

The release path binds it: `scripts/prepare_release_assets.py
--heldout-evaluation <record>` refuses to stage unless the ledger is COMPLETE,
was run against the very Archive being staged, bound the same model lock, and
reports no false allow and no reviewer rejection. The verified summary is
published inside `APPROVED_ASSETS.json`, so a consumer of the staged bytes can
see which evaluation those bytes carry.

### What this does not close

* **No clinician has reviewed anything in this repository.** The review leg in
  the test suites is exercised with synthetic fixtures; a record produced by a
  fixture carries `clinical_acceptance: EXTERNAL` and cannot complete a release.
* **The model lock is UNPINNED**, so an evaluation binds coordinates rather than
  bytes. `NATIVE_MODELS` remains an external gate.
* **The numeric-provenance leg catches changed and uncited numbers, not a
  poisoned claim that cites its own passage.** Substituted content is caught by
  corpus approval (the six-point gate above) and by human review, not by this
  arithmetic.

## Current state, stated plainly

The three seed documents are **worked examples, not reviewed content**. They
carry `reviewed_by: UNREVIEWED-EXAMPLE`. The build refuses to produce a
`--release` archive while any document is unreviewed, so the pipeline cannot
quietly ship unreviewed medical instructions.

**No clinician has reviewed anything in this repository.** That is the single
largest remaining gap and it cannot be closed by writing code.
