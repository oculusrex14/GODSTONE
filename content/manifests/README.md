# Production content manifests

`documents/` is intentionally empty. A production release must contain one approved YAML manifest per selected source document and its immutable rights, reviewer-approval, and chunk-boundary evidence files. The release gate rejects an empty set, examples, placeholders, missing files, mismatched hashes, expired review, absent redistribution/derivative rights, and unapproved warning or contraindication mappings.

`examples/document-manifest.example.yaml` documents the schema only. Its `example: true` and placeholder hashes guarantee that it cannot pass the release gate.
