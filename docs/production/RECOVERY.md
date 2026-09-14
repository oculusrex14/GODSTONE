# Recovery instructions

Recovery is **OFFLINE**. No step below fetches anything: a device that cannot
reach a network must still be recoverable, and nothing here is allowed to
become a hidden network dependency (invariant C1).

Archive corruption must produce a local unavailable state, never a crash or
network fetch. Restore only an asset whose signed manifest, tier, schema,
hash, counts, and model compatibility pass. Missing production content cannot
be replaced by the example corpus.

## The installed estate

An installed Archive is an **estate**: three files that must agree.

| File | What it is |
|---|---|
| `archive_light.db` | the installed archive bytes |
| `APPROVED_ASSETS.json` | the published approved-resource manifest that **nameth** those bytes (name, size, SHA-256) |
| `archive_manifest.json` | the signed archive manifest that answers those bytes (tier, `archive_schema`, counts, Ed25519 signature) |

The trust store is selected by the **operator**, and is never read from the
estate's own document: an estate is never permitted to nominate its own
authority.

Open (and verify) an estate with:

```sh
python3 scripts/upgrade_recovery.py verify --estate <estate> --trust-store <store>
```

A **partial** estate — one file present without its pair — is refused **by
name**. It is a wipe in progress or a broken estate; it is never read as
empty, and it is never recreated empty. Storage failure is never confused
with missing data.

## Upgrading: what may replace what

`scripts/upgrade_recovery.py`'s `RollbackCompatibilityMatrix` decides. The
shipped matrix is bound to the archive builder's own schema constant:

* the schema the release **publisheth** is the one the shipping build
  **runneth** (a matrix that would publish a schema the build may not open is
  refused outright);
* an **unsupported downgrade** (an older candidate schema over an installed
  estate) is refused **by name**, *before* any write;
* an **unknown future schema** is refused **by name** and the estate is
  preserved byte for byte. It is never auto-detected, and it is never
  recreated empty;
* a **migration** from an installed schema is applied only when it is
  *declared*, and a declaration requires a fixture-based migration from a
  supported version (see `MIGRATION.md`). This baseline declares **no**
  supported earlier version, so a `schema_version` below the shipped one is
  refused by name. The migration code path is exercised with a rehearsal
  matrix in `tools/readiness/tests/test_t77.py`, which is where a future
  supported version's step would be proven before it were declared here.

## The update transaction

The update is transactional, and the transaction's only owner is
`scripts/prepare_release_assets.py`:

```sh
python3 scripts/prepare_release_assets.py \
  --manifest <approved-asset-manifest> \
  --out <estate> \
  --trust-store <store> \
  --retain-previous <retention-directory-outside-the-estate>
```

The order is the law and does not change:

> validate → **retain the previous authoritative pair** → copy and re-verify
> → replace the archive → publish the manifest

Every refusal **precedes** every write. With `--retain-previous`, the previous
`archive_light.db` **and** the `APPROVED_ASSETS.json` that named it are copied
and fsynced into that directory together with a `RETENTION.json` record that
swears both digests, *before* either file of the pair is replaced. A **half
pair** is refused by name rather than retained as though it had been sworn,
and a retention directory may not live inside the estate it retaineth.

**The last-approved bytes remain available only under this explicit,
compatible trust policy.** A `RETENTION.json` that is not whole is not a
rollback target, and a rollback is refused when the retained archive's schema
is not one this build may run.

## Rollback

```sh
python3 scripts/upgrade_recovery.py rollback \
  --estate <estate> --retained <retention-dir> --work <work> --trust-store <store>
```

The retained estate is re-verified against the operator's trust store before
it is restored, and again after. The restored bytes must match the retention
record, or the rollback is refused.

## Resuming an interrupted update or wipe

An interruption in any transition — a crash, a full disk, a killed process —
leaves the **previous authoritative estate whole**, because the transaction is
complete only when its own journal says so. Every transition is journaled and
fsynced **outside** the estate (`<work>/<case>.recovery-journal.json`) before
the action it describes.

```sh
python3 scripts/upgrade_recovery.py resume \
  --estate <estate> --work <work> --case <case-id> --trust-store <store>
```

Resume reaches a terminal state **from the record alone**; nothing is guessed
and no byte is inferred from memory. If no journal stands, the estate is
verified as it stands rather than assumed.

```sh
python3 scripts/upgrade_recovery.py wipe \
  --estate <estate> --work <work> --case <case-id>
```

A wipe is journaled and **terminal**: resume it to completion. Its terminal
states are exactly WIPED or the previous authoritative estate intact. An
estate mid-wipe is refused as **partial**, never reported as a healthy empty
install.

## Reproducing the proof

```sh
python3 scripts/upgrade_recovery.py selftest
python3 scripts/upgrade_recovery.py rehearse --work <empty-dir> --report <report.json>
```

The rehearsal drives the whole ladder over **harmless development fixtures**
(app-navigation prose only, a TEST-ONLY key, no production review provenance).
Its report is labelled `development-fixture`: it is **NOT** an approval, it
closes no external gate, and it establishes nothing about any device.

## Still open

* Installation, launch, upgrade and rollback **on a real device** are
  UNVERIFIED. The device claim is `UNVERIFIED (external: no device in this
  lane)`; the platform/device gate remains a pending external gate.
* Signed production content (`APPROVED_CONTENT`), the native/model stack
  (`NATIVE_MODELS`), independent Noise fixtures (`A06`), hardware
  (`HARDWARE`) and signing (`SIGNING`) remain OPEN external gates. No
  rehearsal, fixture or example corpus closes them.
* Messaging recovery, bulk/tier store products, and the experimental mesh and
  Oracle surfaces remain disabled or unimplemented release blockers.
