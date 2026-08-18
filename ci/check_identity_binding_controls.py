#!/usr/bin/env python3
"""Regression controls and structural checks for IdentityBindingV1 (ADR-003, Phase C8.1A).

Verifies the presence and structural markers of:
- Android production & test IdentityBindingV1 implementations
- iOS production & test IdentityBindingV1 implementations
- Python reference, generator, KAT fixture, and conformance test
- CI workflow invocations of vector generation and identity binding tests
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ANDROID_PROD_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "IdentityBindingV1.kt"
ANDROID_TEST_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "IdentityBindingV1Test.kt"
IOS_PROD_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "IdentityBindingV1.swift"
IOS_TEST_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "IdentityBindingV1Tests.swift"
PYTHON_REF_PATH = ROOT / "crypto" / "identity_binding.py"
PYTHON_GEN_PATH = ROOT / "crypto" / "gen_identity_binding_vectors.py"
FIXTURE_PATH = ROOT / "crypto" / "identity_binding_vectors.json"
PYTHON_TEST_PATH = ROOT / "crypto" / "test_identity_binding.py"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "repository-verification.yml"


def check_identity_binding_controls(
    android_prod: Path = ANDROID_PROD_PATH,
    android_test: Path = ANDROID_TEST_PATH,
    ios_prod: Path = IOS_PROD_PATH,
    ios_test: Path = IOS_TEST_PATH,
    py_ref: Path = PYTHON_REF_PATH,
    py_gen: Path = PYTHON_GEN_PATH,
    fixture: Path = FIXTURE_PATH,
    py_test: Path = PYTHON_TEST_PATH,
    workflow: Path = WORKFLOW_PATH,
) -> list[str]:
    errors: list[str] = []

    # 1. Existence checks
    for path, name in [
        (android_prod, "Android production IdentityBindingV1"),
        (android_test, "Android test IdentityBindingV1Test"),
        (ios_prod, "iOS production IdentityBindingV1"),
        (ios_test, "iOS test IdentityBindingV1Tests"),
        (py_ref, "Python reference identity_binding.py"),
        (py_gen, "Python vector generator gen_identity_binding_vectors.py"),
        (fixture, "KAT fixture identity_binding_vectors.json"),
        (py_test, "Python conformance test test_identity_binding.py"),
    ]:
        if not path.exists():
            errors.append(f"Missing required file: {name} ({path})")

    if errors:
        return errors

    # 2. Android test markers
    a_test_text = android_test.read_text(encoding="utf-8")
    if "fresh_generation_zero" not in a_test_text:
        errors.append("Android test missing KAT marker: fresh_generation_zero")
    if "endian_lock" not in a_test_text:
        errors.append("Android test missing KAT marker: endian_lock")
    if "max_generation" not in a_test_text:
        errors.append("Android test missing KAT marker: max_generation")
    if "InvalidSignature" not in a_test_text and "bad signature" not in a_test_text:
        errors.append("Android test missing bad-signature test marker")
    if "NoiseStaticMismatch" not in a_test_text and "remote Noise static mismatch" not in a_test_text:
        errors.append("Android test missing Noise static mismatch test marker")
    if "AdvertisementHintMismatch" not in a_test_text and "advertised hint mismatch" not in a_test_text:
        errors.append("Android test missing advertisement hint mismatch test marker")
    if "UnsupportedVersion" not in a_test_text and "bad version" not in a_test_text:
        errors.append("Android test missing bad-version test marker")
    if "MalformedLength" not in a_test_text and "truncated" not in a_test_text:
        errors.append("Android test missing bad-length test marker")

    # 3. iOS test markers
    i_test_text = ios_test.read_text(encoding="utf-8")
    if "fresh_generation_zero" not in i_test_text and "testFreshGenerationZeroKat" not in i_test_text:
        errors.append("iOS test missing KAT marker: fresh_generation_zero")
    if "endian_lock" not in i_test_text and "testEndianLockKat" not in i_test_text:
        errors.append("iOS test missing KAT marker: endian_lock")
    if "max_generation" not in i_test_text and "testMaxGenerationKat" not in i_test_text:
        errors.append("iOS test missing KAT marker: max_generation")
    if "invalidSignature" not in i_test_text and "testBadSignature" not in i_test_text:
        errors.append("iOS test missing bad-signature test marker")
    if "noiseStaticMismatch" not in i_test_text and "testRemoteNoiseStaticMismatch" not in i_test_text:
        errors.append("iOS test missing Noise static mismatch test marker")
    if "advertisementHintMismatch" not in i_test_text and "testAdvertisedHintMismatch" not in i_test_text:
        errors.append("iOS test missing advertisement hint mismatch test marker")
    if "unsupportedVersion" not in i_test_text and "testBadVersion" not in i_test_text:
        errors.append("iOS test missing bad-version test marker")
    if "malformedLength" not in i_test_text and "testTruncated" not in i_test_text:
        errors.append("iOS test missing bad-length test marker")

    # 4. Workflow invocations
    if workflow.exists():
        wf_text = workflow.read_text(encoding="utf-8")
        if "crypto.gen_identity_binding_vectors" not in wf_text:
            errors.append("repository-verification.yml: missing 'python -m crypto.gen_identity_binding_vectors'")
        if "crypto.test_identity_binding" not in wf_text:
            errors.append("repository-verification.yml: missing 'python -m crypto.test_identity_binding'")
        if "check_identity_binding_controls.py" not in wf_text:
            errors.append("repository-verification.yml: missing 'ci/check_identity_binding_controls.py'")

    return errors


def selftest() -> int:
    """Run mutation negative controls to prove the checker fails on invalid inputs."""
    print("Running check_identity_binding_controls --selftest...")
    failures: list[str] = []
    passed_mutations = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        f_a_prod = tmp / "IdentityBindingV1.kt"
        f_a_test = tmp / "IdentityBindingV1Test.kt"
        f_i_prod = tmp / "IdentityBindingV1.swift"
        f_i_test = tmp / "IdentityBindingV1Tests.swift"
        f_py_ref = tmp / "identity_binding.py"
        f_py_gen = tmp / "gen_identity_binding_vectors.py"
        f_fixture = tmp / "identity_binding_vectors.json"
        f_py_test = tmp / "test_identity_binding.py"
        f_wf = tmp / "repository-verification.yml"

        # Populate with baseline clean files
        f_a_prod.write_text(ANDROID_PROD_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_a_test.write_text(ANDROID_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_i_prod.write_text(IOS_PROD_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_i_test.write_text(IOS_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_py_ref.write_text(PYTHON_REF_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_py_gen.write_text(PYTHON_GEN_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_fixture.write_text(FIXTURE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_py_test.write_text(PYTHON_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_wf.write_text(WORKFLOW_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Baseline check must pass (assuming workflow is updated)
        # Note: if workflow isn't updated yet, write a valid workflow in temp
        wf_valid = f_wf.read_text(encoding="utf-8")
        if "crypto.gen_identity_binding_vectors" not in wf_valid:
            wf_valid += "\n          python -m crypto.gen_identity_binding_vectors\n          python -m crypto.test_identity_binding\n          python ci/check_identity_binding_controls.py\n"
            f_wf.write_text(wf_valid, encoding="utf-8")

        # H1: Android KAT marker removed
        orig_a_test = f_a_test.read_text(encoding="utf-8")
        f_a_test.write_text(orig_a_test.replace("fresh_generation_zero", "mutated_marker"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("Android test missing KAT marker" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H1 (Android KAT marker removed) was NOT detected")
        f_a_test.write_text(orig_a_test, encoding="utf-8")

        # H2: iOS KAT marker removed
        orig_i_test = f_i_test.read_text(encoding="utf-8")
        f_i_test.write_text(orig_i_test.replace("fresh_generation_zero", "mutated_marker").replace("testFreshGenerationZeroKat", "mutatedKat"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("iOS test missing KAT marker" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H2 (iOS KAT marker removed) was NOT detected")
        f_i_test.write_text(orig_i_test, encoding="utf-8")

        # H3: Android bad-signature marker removed
        f_a_test.write_text(orig_a_test.replace("InvalidSignature", "Mutated").replace("bad signature", "mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("Android test missing bad-signature" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H3 (Android bad-signature marker removed) was NOT detected")
        f_a_test.write_text(orig_a_test, encoding="utf-8")

        # H4: iOS bad-signature marker removed
        f_i_test.write_text(orig_i_test.replace("invalidSignature", "mutated").replace("testBadSignature", "mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("iOS test missing bad-signature" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H4 (iOS bad-signature marker removed) was NOT detected")
        f_i_test.write_text(orig_i_test, encoding="utf-8")

        # H5: Android static-mismatch marker removed
        f_a_test.write_text(orig_a_test.replace("NoiseStaticMismatch", "Mutated").replace("remote Noise static mismatch", "mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("Android test missing Noise static mismatch" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H5 (Android static-mismatch marker removed) was NOT detected")
        f_a_test.write_text(orig_a_test, encoding="utf-8")

        # H6: iOS static-mismatch marker removed
        f_i_test.write_text(orig_i_test.replace("noiseStaticMismatch", "mutated").replace("testRemoteNoiseStaticMismatch", "mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("iOS test missing Noise static mismatch" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H6 (iOS static-mismatch marker removed) was NOT detected")
        f_i_test.write_text(orig_i_test, encoding="utf-8")

        # H7: Android hint-mismatch marker removed
        f_a_test.write_text(orig_a_test.replace("AdvertisementHintMismatch", "Mutated").replace("advertised hint mismatch", "mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("Android test missing advertisement hint mismatch" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H7 (Android hint-mismatch marker removed) was NOT detected")
        f_a_test.write_text(orig_a_test, encoding="utf-8")

        # H8: iOS hint-mismatch marker removed
        f_i_test.write_text(orig_i_test.replace("advertisementHintMismatch", "mutated").replace("testAdvertisedHintMismatch", "mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("iOS test missing advertisement hint mismatch" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H8 (iOS hint-mismatch marker removed) was NOT detected")
        f_i_test.write_text(orig_i_test, encoding="utf-8")

        # H9: identity-binding generator removed from workflow
        orig_wf = f_wf.read_text(encoding="utf-8")
        f_wf.write_text(orig_wf.replace("crypto.gen_identity_binding_vectors", "crypto.mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("missing 'python -m crypto.gen_identity_binding_vectors'" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H9 (generator removed from workflow) was NOT detected")
        f_wf.write_text(orig_wf, encoding="utf-8")

        # H10: identity-binding Python conformance command removed from workflow
        f_wf.write_text(orig_wf.replace("crypto.test_identity_binding", "crypto.mutated"), encoding="utf-8")
        errs = check_identity_binding_controls(f_a_prod, f_a_test, f_i_prod, f_i_test, f_py_ref, f_py_gen, f_fixture, f_py_test, f_wf)
        if any("missing 'python -m crypto.test_identity_binding'" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation H10 (conformance command removed from workflow) was NOT detected")
        f_wf.write_text(orig_wf, encoding="utf-8")

    if failures:
        print(f"FAILED: {len(failures)} mutation(s) were NOT caught:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"check_identity_binding_controls selftest PASSED ({passed_mutations}/10 mutations caught deterministically).")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        return selftest()

    errors = check_identity_binding_controls()
    if errors:
        print("IDENTITY BINDING CONTROLS GATE: FAILED", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("IDENTITY BINDING CONTROLS GATE: PASS -- structural controls and platform markers present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
