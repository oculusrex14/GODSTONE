# Production content manifests

`documents/` is intentionally empty. A production release must contain one
approved YAML manifest per selected source document and its immutable rights,
reviewer-approval, and chunk-boundary evidence files. The release gate
rejects an empty set, examples, placeholders, missing files, mismatched
hashes, expired review, absent redistribution/derivative rights, and
unapproved warning or contraindication mappings.

`examples/document-manifest.example.yaml` documents the schema only. Its
`example: true` and placeholder hashes guarantee that it cannot pass the
release gate.

Duplicate keys are refused everywhere a manifest is read -- YAML or JSON,
at any depth. A reader that lets the last key win is a smuggling gap, not
a parser.

## Final chunk approvals (T46)

A document manifest proves the source was approved. It does not prove that
the chunks which ship are the chunks a reviewer read. For that, a release
build may engage the approval limb by naming two paths:

    --approvals-dir DIR          holds {source_id}.approvals.json bundles
    --reviewer-keyset FILE       the operator's reviewer trust store

**The bundle cannot nominate its own trusted keys.** The keyset must be
configured independently: it is refused unread when it resolves inside the
seed corpus, the manifests home, the evidence root, the approvals dir, or
the destination tree. Copy it out of band; point at it from the command.

### Reviewer keyset (schema 1)

    {"schema": 1, "keys": [
      {"key_id": "...", "reviewer_id": "...",
       "public_key": "<base64 of the raw 32-byte Ed25519 public key>",
       "valid_from": "YYYY-MM-DD", "valid_until": "YYYY-MM-DD"}
    ]}

Duplicate `key_id`s, placeholder identities, short keys and inverted windows
are refused at load. A key out of its window on the injected build date
refuseth every signature it ever made.

### Approvals bundle ({source_id}.approvals.json, schema 1)

    {"schema": 1, "approvals": [
      {"schema": 1, "source_id": "...", "document_sha256": "...",
       "rights_sha256": "...", "reviewer_id": "...",
       "reviewer_credential_evidence_file": "relative-to-evidence-root",
       "reviewer_credential_sha256": "...", "reviewed_on": "YYYY-MM-DD",
       "valid_from": "...", "valid_until": "...",
       "warnings_sha256": "...", "contraindications_sha256": "...",
       "chunk_final_sha256": ["...", ...], "chunk_count": N,
       "key_id": "...", "signature": "<detached Ed25519, base64>"}
    ]}

Every field is bound into a length-prefixed, domain-tagged canonical
preimage (`GS-APPROVAL-V1`) before signing; the chunk hashes are the
`GS-CHUNK-FINAL-V1` digests of (source_id, document_sha256, ordinal,
section, text, token_count, warnings-digest, contraindications-digest).
Warning and contraindication texts are harvested from the chunks whose
section path falls under a name declared in the document manifest's
`safety.warning_sections` / `safety.contraindication_sections`.

The verifier refuseth: an unknown future schema, an unlisted `key_id`, a
bad signature, a record expired or not yet in force (against the INJECTED
clock), a review date outside its window, digests that do not answer to
the bytes that ship, foreign chunk claims, double-claimed chunks, and
every uncovered chunk. When the leg engages, a build passeth only if
every shipped chunk is covered; the archive then records the rows
`approvals_sha256` and `approvals_covered`, which travel onward inside
the signed archive manifest.

The aids `make_test_keyset_entry`, `write_test_keyset`,
`sign_final_approval_fields` and `write_approvals_bundle` in
`content/release_gate.py` fabricate keys and seals for the courts. They
prove no clinical review; production keys are generated out of band, by
the state's own hand.
