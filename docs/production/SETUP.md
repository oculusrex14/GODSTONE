# Setup

1. Obtain a clean private checkout at `b7daf5aceb642277807e9bfbe3bbb486112a64ec`.
2. Run `python3 overlay/apply_to_checkout.py /path/to/GODSTONE --evidence-out /path/to/evidence` from the extracted bundle.
3. Review `git status`, generated patch, and diff stat; do not commit until review is complete.
4. Add a verified Gradle wrapper JAR matching the pinned wrapper properties; record its SHA-256 and provenance.
5. Install documented Android and Apple toolchains in controlled environments.
6. Do not stage release assets from `assets-light.example.json`; it is intentionally nonreleasable.
