# Signing instructions

**This document prepares the human signing step. It does not perform it, and it
closes no gate.** Signing is owner-controlled and happens on a designated
signing workstation outside this repository. Until it does, the candidate is
`unsigned` and the `SIGNING` gate stays OPEN.

## What is signed

The **exact tested unsigned payload**. The signed artifact must contain a
byte-identical payload to the artifact the tests ran against, so the order is:

> clean checkout → build unsigned → inspect → **test** → record the artifact
> identity → release owner signs that identity → prove the signed payload still
> matches.

If the payload changes at any point after testing, the signature is over bytes
no test touched and the whole evidence chain is void.

## Preconditions, verified before the signing window

| Check | Command |
|---|---|
| Exact source commit recorded and clean | `git rev-parse HEAD` ; `git status --porcelain` |
| Release manifest and asset hashes | `python3 scripts/prepare_release_assets.py --help` |
| Dependency inventory and licences | `docs/supplychain/SBOM.json` |
| Shipping surface carries no debug capability | `python3 ci/check_release_surface.py` |
| Archive-only boundary holds | `python3 ci/check_shipping_path.py` |
| Unsigned metadata is shaped and secret-free | `python3 tools/readiness/run.py task T76 --stage narrow` |

## What must never be here

Keystores, certificates, provisioning profiles, passwords, API keys, store
credentials and the private Archive signing key **may never** be placed in the
repository, in the bundle, or in any builder prompt. The metadata file
`docs/production/RELEASE_METADATA.json` records the prohibition and is itself
checked for it: `test_t76.py`'s W02 refuses a secret appearing in a field whose
job is to hold metadata.

## The metadata record

`docs/production/RELEASE_METADATA.json` is the non-secret contract for this
step. Its `signing` block has three fields that must agree:

* `state` — `unsigned` or `signed`, and nothing else;
* `fingerprint` — **null exactly while `state` is `unsigned`**; a fingerprint
  recorded beside `unsigned`, or `signed` with no fingerprint, is refused by W03;
* `payload_equivalence_required` — true; the equivalence rule names the artifact
  the release owner produces (`SignatureVerificationReport`), which lives
  outside builder authority.

## After signing

The release owner records, outside this repository:

1. the signing fingerprint and its algorithm;
2. proof that the signed payload equals the tested unsigned payload;
3. the artifact identity (hash) that was actually signed.

Only then does `state` become `signed`. The repository records the fingerprint;
it never records the key.

## Still open

Signing itself is **external**: no keystore, certificate, provisioning profile
or store credential exists in this checkout, so neither platform can be signed
from here. Store acceptance is a further external step. Both are recorded as
open gates in `docs/production/EXTERNAL_RELEASE_GATES.md`.
