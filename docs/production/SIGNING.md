# Signing instructions

Build unsigned artifacts first. Verify source commit, clean status, release manifest, SBOM, asset hashes, tests, and artifact hashes. Use owner-controlled signing infrastructure; never place keystores, certificates, profiles, passwords, private Archive keys, or API secrets in the repository or bundle. Record signing fingerprint and prove the signed artifact contains the exact tested unsigned payload.
