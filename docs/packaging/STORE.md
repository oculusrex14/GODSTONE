# Store submission notes

Godstone breaks several assumptions app review is built on. It has no network
access, no account, no analytics and no server, and it gives medical and
emergency instructions. Every one of those attracts questions. This document
is the standing answer.

## What the app does

An offline survival reference with an on-device language model, plus an
encrypted peer-to-peer mesh over Bluetooth and Wi-Fi Aware. No component of it
contacts a server, because there may not be one.

## Expected review questions

### "Why does this need Bluetooth and location permission?"

Bluetooth is the transport. The mesh relays messages phone to phone when
infrastructure is down.

On Android, BLE scanning historically required location permission. We declare
`neverForLocation` on the scan permission and we do not request
`ACCESS_FINE_LOCATION` at all. The app never reads position, never stores it
and has no code path that could.

### "There is no privacy policy URL."

There is a privacy policy; it is bundled in the app and reachable from the
first screen. It is short because there is nothing to disclose. The app
collects nothing, transmits nothing to us, and has no analytics SDK, no crash
reporter and no advertising identifier.

Reviewers can verify this: the Android manifest does not declare
`android.permission.INTERNET`, and the iOS binary contains no `URLSession`,
`NSURLConnection` or socket usage. An app that cannot open a socket cannot
exfiltrate anything.

### "The app provides medical advice."

It provides first aid and emergency preparedness reference material, sourced
from published guidance and attributed in the app. Every answer names the
document and section it came from, and every source is listed in
`content/seed/sources.yaml` with its licence.

The model is constrained to answer only from retrieved documents (constraint
C3). When retrieval finds nothing relevant it says it does not know rather than
generating an answer. This is enforced in the prompt, enforced by a confidence
floor in the retriever, and tested in CI.

The app carries a prominent disclaimer that it is not a substitute for
professional medical care and that emergency services should be contacted
whenever they are reachable.

### "Why is the download so large?"

The whole point is that it works with no connection. The language model and
the document archive have to be on the device. Three tiers exist so users can
choose; see TIERS.md.

LARGE exceeds store binary limits and ships its weights as a post-install
download pack.

### "Does the app allow user-to-user communication?"

Yes, over the local mesh only, end-to-end encrypted, with no server and no
account. There is no global discovery: a user only ever sees devices in
physical radio range, or reachable by a few hops through devices in range.

Moderation of a serverless local mesh is not technically possible and we do not
claim otherwise. The mitigations that do exist:

- No public directory, no usernames, no way to search for a person
- Contacts are established by scanning a QR code in physical proximity
- Every device can block a peer key locally
- Range is metres to a few hundred metres per hop

The comparison is a walkie-talkie, not a social network.

### "Encryption export compliance."

The app uses standard cryptography only: Noise XX handshake, X25519, Ed25519,
ChaCha20-Poly1305, BLAKE2s and HKDF. Nothing is invented (C6), no proprietary
algorithm is included, and the implementations are established open-source
libraries.

This is standard exemption territory. Declare encryption as present, limited to
standard algorithms, used for confidentiality of user communications.

## Store listing

**Do not** describe the app as guaranteeing safety, replacing emergency
services, or being suitable as a sole source of medical guidance.

**Do** describe it as: an offline reference library with a local assistant, and
a short-range encrypted mesh for when networks are down.

Screenshots must show a real answer with its citation cards visible. The
citation is the product; a screenshot of an uncited answer misrepresents what
the app does.

## Age rating

Expect 12+ or equivalent. The archive contains clinical descriptions of injury
and, at MEDIUM and above, material on conflict and CBRN incidents. It contains
no depiction of violence for its own sake and no imagery beyond clinical
diagrams.

## Release checklist

- [ ] `corpus_sha256` recorded in the release notes for each tier
- [ ] All three tier tables agree (build_archive.py, Gradle, Tier.swift)
- [ ] No `INTERNET` permission in the merged Android manifest
- [ ] No networking symbols in the iOS binary
- [ ] Grounding refusal tests pass (tab 12)
- [ ] `meshsim` city_blackout scenario meets delivery targets
- [ ] Disclaimer visible on first launch
- [ ] Bundled privacy policy reachable from the first screen
- [ ] Licence attributions present for every source in the shipped tier
