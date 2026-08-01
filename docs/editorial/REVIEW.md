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

## Current state, stated plainly

The three seed documents are **worked examples, not reviewed content**. They
carry `reviewed_by: UNREVIEWED-EXAMPLE`. The build refuses to produce a
`--release` archive while any document is unreviewed, so the pipeline cannot
quietly ship unreviewed medical instructions.

**No clinician has reviewed anything in this repository.** That is the single
largest remaining gap and it cannot be closed by writing code.
