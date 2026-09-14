#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    path = Path("content/ingest/build_archive.py")
    if not path.is_file():
        print("content/ingest/build_archive.py missing")
        return 1
    text = path.read_text(encoding="utf-8")
    required = (
        "from content.release_gate import validate_release_corpus",
        "validate_release_corpus(",
        'ROOT / "content" / "manifests" / "documents"',
    )
    missing = [item for item in required if item not in text]
    if missing:
        print("release builder is not wired to the complete content gate: " + ", ".join(missing))
        return 1
    print(f"release archive builder invokes the complete content gate "
          f"({len(required) - len(missing)} of {len(required)} faces)")

    # T52: the binary-inspection leg must distinguish SOURCE-ONLY EXCLUSION
    # evidence from RELEASE-CANDIDATE CONTENT PRESENCE. These faces are the
    # contract; if any is struck, an exclusion-only run could masquerade as
    # content proof and the release gate would pass an app with no usable
    # archive at all. Checked by named face, refused by name.
    inspector = ROOT / "scripts" / "inspect_android_artifacts.py"
    if not inspector.is_file():
        print("scripts/inspect_android_artifacts.py missing")
        return 1
    body = inspector.read_text(encoding="utf-8")
    presence_faces = (
        "class ApprovedArchivePresenceReport",
        '"the expected Archive is absent from the package"',
        '"byte-matched"',
        '"present-unverified"',
        '"release-candidate-content"',
        '"source-only-exclusion"',
        '"packaged-bytes-present"',
        "duplicate ZIP entries",
        "symlink entries are prohibited",
        "traversal entry names are prohibited",
        "dangerous entry modes",
        "development fixture is packaged as production",
        "the resolved bundled engine is absent",
        "the counts metadata lieth",
        "the FTS5 index",
        "CFBundleExecutable",
        'base/assets/archive_light.db',
        "Payload/Godstone.app/archive_light.db",
        'node="remove"',
    )
    absent = [face for face in presence_faces if face not in body]
    if absent:
        print("the artifact inspector lost its presence faces: " + ", ".join(absent))
        return 1
    print(f"the artifact inspector keepeth {len(presence_faces) - len(absent)} of "
          f"{len(presence_faces)} presence faces")

    gates = (ROOT / ".github" / "workflows" / "release-gates.yml").read_text(encoding="utf-8")
    wired = ("--expected-archive", "--approved-manifest", "--release-candidate",
             "APPROVED_ASSETS.json")
    unwired = [face for face in wired if face not in gates]
    if unwired:
        print("the release-gates job is not wired to the presence form: " + ", ".join(unwired))
        return 1
    print("the release-gates job invocateth the guarded presence form")

    staging = (ROOT / "scripts" / "prepare_release_assets.py").read_text(encoding="utf-8")
    if "APPROVED_ASSETS.json" not in staging:
        print("the staging gate publisheth no APPROVED_ASSETS.json for the presence form to trust")
        return 1
    verification = (ROOT / ".github" / "workflows" / "repository-verification.yml").read_text(
        encoding="utf-8")
    for face in ("ci/archive_fixture.py", "--expected-archive"):
        if face not in verification:
            print(f"repository-verification is not wired for the debug presence proof ({face})")
            return 1
    print("the debug lane feédeth a labelled fixture and proveth the bytes arrived")

    # T77: the UPDATE is transactional and the previous authoritative bytes stay
    # available. Three faces are the contract: the staging gate carrieth the
    # retention record and refuses a half pair; the recovery authority carrieth
    # the compatibility matrix and the journal; and a repo-owned lane runneth
    # the rehearsal, so an amputation of any of them is refused by name rather
    # than discovered at a release.
    t77_staging_faces = (
        "RETENTION.json",
        "half pair is never retained",
        "PUBLISH_BOUNDARIES",
        "def publish_verified(",
        "--retain-previous",
    )
    staging_absent = [face for face in t77_staging_faces if face not in staging]
    if staging_absent:
        print("the staging gate lost its transactional-update faces: " +
              ", ".join(staging_absent))
        return 1
    print(f"the staging gate keepeth {len(t77_staging_faces) - len(staging_absent)} of "
          f"{len(t77_staging_faces)} transactional-update faces")

    recovery = ROOT / "scripts" / "upgrade_recovery.py"
    if not recovery.is_file():
        print("scripts/upgrade_recovery.py missing: the update has no recovery authority")
        return 1
    recovery_faces = (
        "class RollbackCompatibilityMatrix",
        "class UpgradeCase",
        "class RecoveryResult",
        "RollbackCompatibilityMatrix(",
        "SHIPPED_MATRIX = RollbackCompatibilityMatrix(",
        "unsupported archive schema",
        "unknown future schema",
        "unsupported downgrade",
        "never recreated empty",
        "def estate_record_dir(",
        "def recovery_instructions(",
        "DEVICE_CLAIM",
        "class Journal",
        "def resume(",
        "def rollback(",
        "def wipe(",
        "from content.ingest.build_archive import SCHEMA_VERSION as ARCHIVE_SCHEMA_VERSION",
    )
    body = recovery.read_text(encoding="utf-8")
    recovery_absent = [face for face in recovery_faces if face not in body]
    if recovery_absent:
        print("the recovery authority lost its faces: " + ", ".join(recovery_absent))
        return 1
    print(f"the recovery authority keepeth {len(recovery_faces) - len(recovery_absent)} of "
          f"{len(recovery_faces)} faces")

    lane_faces = ("python3 scripts/upgrade_recovery.py --selftest",
                  "scripts/upgrade_recovery.py rehearse", "test_t77.py")
    lane_absent = [face for face in lane_faces if face not in verification]
    if lane_absent:
        print("repository-verification is not wired for the recovery lane: " +
              ", ".join(lane_absent))
        return 1
    print("repository-verification runneth the recovery selftest, the rehearsal and the court")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
