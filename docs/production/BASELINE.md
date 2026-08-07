# GODSTONE remediation baseline

- Repository: `oculusrex14/GODSTONE`
- Default branch: `main`
- Starting commit: `b7daf5aceb642277807e9bfbe3bbb486112a64ec`
- Starting tree: `ccbdc382b2f4cd88d79f59b77248760037603031`
- Report baseline: same commit
- Intervening commits: none
- Original report verdict: `NOT READY`, 2.2/10
- Original inspected Actions run: `31078274189`, failed
- Execution environment: Linux x86_64; no Android SDK/Gradle installation, no macOS/Xcode, no physical mobile devices, no signing credentials.

## Retrieval boundary

The private repository was read through the authenticated GitHub connector. The execution container could not clone or mount the repository archive and had no outbound GitHub network route. The delivered `GODSTONE/` directory is therefore a source overlay, not a claim of a complete private checkout. `overlay/apply_to_checkout.py` verifies this exact commit and each touched baseline Git blob before applying the overlay to a local checkout. It then emits the genuine working-tree patch and changed-file evidence.

This transfer limitation prevents a clean full-project Gradle/Xcode build in the current environment and is explicitly release-blocking. It does not weaken any safety gate: missing production content, assets, wrapper JAR, model locks, signing material, or hardware evidence remain fail-closed.
