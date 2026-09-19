# Privacy and data inventory

**This document describes what the prepared production target ACTUALLY does.**
It is a description of current behaviour, not a marketing claim, and it names
what is unknown rather than asserting what has not been measured. External
legal/privacy/export review is **PENDING** (`docs/production/EXTERNAL_RELEASE_GATES.md`).

## Claim set: archive-only

The prepared production target browses an immutable local Archive. For this
claim set it requests:

* **no** Bluetooth or BLE capability;
* **no** local-network or nearby-devices capability;
* **no** location, camera, microphone or notification capability;
* **no** background-radio capability.

The enforcement is structural, not aspirational:

| Platform | Mechanism | Check |
|---|---|---|
| Android | `INTERNET` is **explicitly removed** (`tools:node="remove"`), so a transitive library manifest cannot reintroduce it; `allowBackup="false"`; `usesCleartextTraffic="false"` | `ci/check_release_surface.py` |
| iOS | `Godstone.entitlements` is an empty dict; the privacy manifest declares no tracking and no collected data | `ci/check_release_surface.py` |

`ci/check_release_surface.py` fails if any forbidden permission, usage-description
key or disabled capability reappears in the shipping manifest, entitlements or
privacy manifest. That check runs in the canonical workflow on every push.

## What is stored locally

The Archive database is installed into application-private storage and is the
only persistent content store for this claim set. It is read through the
Archive repository; it is not uploaded anywhere, because there is no network
capability to upload it with.

Android backup is disabled on **all** API levels by `allowBackup="false"`, so
the Archive is not copied into cloud backup. On iOS the target declares no
collected data and no tracking.

## What is NOT collected

For the archive-only claim set the target has no capability to collect, and
therefore does not collect: identity keys, contacts, trust relations, messages,
acknowledgments, prompts, history, diagnostics, location, media or radio
metadata. Those surfaces exist in the codebase but are **not authorized for
production** while their features are disabled and their gates are open.

> Those capabilities are not merely switched off in configuration: the
> permissions that would make them possible are absent from the shipping
> manifest, and the check above reddens if they return.

## Deletion and wipe

Recovery and wipe behaviour is specified in `docs/production/RECOVERY.md`.
Behaviour that privacy review depends on, stated from the implementation:

* an interrupted wipe leaves the **previous authoritative estate intact** and
  is refused as *partial* rather than reported as a healthy empty install —
  the estate is never silently recreated empty;
* a wipe is journaled and terminal: it resumes to `WIPED` or to the previous
  estate, and never to an ambiguous state;
* a **partial** estate (one file of the pair without its partner) is refused by
  name and is never read as empty.

## Known limitations, stated honestly

* **Device-level privacy behaviour is UNVERIFIED.** No device is present in this
  lane. Locked-device behaviour, private-data protection classes and background
  suspension are therefore **device claims that remain external** (the
  `HARDWARE` gate). The repository-visible half — which protection class the
  store *requests*, and that the shipping manifest carries no forbidden
  capability — is enforced by `ci/check_store_schema_controls.py` and
  `ci/check_release_surface.py` respectively.
* **Dependency licences are partly UNKNOWN.** `docs/supplychain/SBOM.json`
  records 552 components whose licence nobody has recorded. They are counted as
  UNKNOWN rather than omitted; whether that is acceptable for distribution is a
  legal question that stays OPEN.
* **Native/model artifact licences cannot be inventoried yet**: those artifacts
  are not present in this checkout (`NATIVE_MODELS`, tasks T62–T65/T81).

## Still open

Legal/privacy/export review, content rights, store privacy answers and the
device-level privacy claims are **human or device gates**. Nothing in this
document closes them, and no fixture may substitute for an approval.
