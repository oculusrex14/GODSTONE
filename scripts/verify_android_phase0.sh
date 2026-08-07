#!/usr/bin/env bash
# Portable Android Phase 0 verification runner.
#
# Runs the full Android Phase 0 evidence set with build-config-evidence gates,
# records every command's log + SHA-256, captures test XML, and emits a
# machine-readable summary. Returns nonzero if any REQUIRED command fails or is
# skipped. Two modes:
#
#   online-bootstrap      Gradle distribution may be downloaded (verified against
#                         distributionSha256Sum). Use on a clean, online machine.
#   offline-preprovisioned  No network. The Gradle 8.9 distribution AND the SDK
#                         packages must already be cached locally; the toolchain
#                         preflight (--offline) fails clearly if they are not,
#                         and Gradle is invoked with --offline so it can NEVER
#                         silently switch to online.
#
# Required commands (any failure => nonzero exit):
#   * toolchain preflight  (scripts/check_android_toolchain.py)
#   * shipping-path gate   (ci/check_shipping_path.py)
#   * wrapper + dist verify (./gradlew --version)
#   * gradle clean + :core/:mesh/:llm unit tests + :app:compileLightDebugKotlin
#   * Android Oracle ViewModel runtime-state tests (:app:testLightDebugUnitTest)
#
# Usage:
#   scripts/verify_android_phase0.sh online-bootstrap [--evidence-dir DIR]
#   scripts/verify_android_phase0.sh offline-preprovisioned [--evidence-dir DIR]
#
# Exit codes: 0 = all required steps passed; 1 = at least one required step
# failed; 2 = bad usage / unknown mode; 3 = preflight environment failure.
set -euo pipefail

# ---------------------------------------------------------------------------
MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
  echo "usage: $0 <online-bootstrap|offline-preprovisioned> [--evidence-dir DIR]" >&2
  exit 2
fi
shift || true
EVIDENCE_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "${MODE}" in
  online-bootstrap|offline-preprovisioned) ;;
  *) echo "unknown mode: ${MODE} (expected online-bootstrap|offline-preprovisioned)" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${EVIDENCE_DIR:-evidence/android-phase0-${TIMESTAMP}}"
mkdir -p "${EVIDENCE_DIR}"
STEPS_TSV="${EVIDENCE_DIR}/steps.tsv"
SUMMARY_JSON="${EVIDENCE_DIR}/summary.json"
META_TXT="${EVIDENCE_DIR}/environment.txt"
GIT_TXT="${EVIDENCE_DIR}/git.txt"
OVERALL=0
GRADLE_ARGS=("--no-daemon" "--stacktrace" "--warning-mode=all")
if [[ "${MODE}" == "offline-preprovisioned" ]]; then
  GRADLE_ARGS+=("--offline")
fi

echo "==> Android Phase 0 verification"
echo "    mode:         ${MODE}"
echo "    repo root:     ${REPO_ROOT}"
echo "    evidence dir:  ${EVIDENCE_DIR}"

# ---------------------------------------------------------------------------
# run_step_shell NAME "shell command"
#   Runs the command, captures stdout+stderr to a log, records rc + SHA-256 of
#   the log, and updates OVERALL. Never triggers `set -e` (uses `|| rc=$?`).
# ---------------------------------------------------------------------------
run_step_shell() {
  local name="$1"; shift
  local log="${EVIDENCE_DIR}/${name}.log"
  echo "+ STEP ${name}: $*"
  local rc=0
  ( bash -c "$*" ) >"${log}" 2>&1 || rc=$?
  local sha=""
  if [[ -s "${log}" ]]; then
    sha="$(shasum -a 256 "${log}" | awk '{print $1}')"
  fi
  printf 'step\t%s\trc=%d\tsha256=%s\tlog=%s\n' "${name}" "${rc}" "${sha}" "${name}.log" >>"${STEPS_TSV}"
  if [[ "${rc}" -ne 0 ]]; then
    echo "    FAIL ${name} (rc=${rc}); log: ${log}"
    OVERALL=1
  else
    echo "    ok   ${name}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Record environment + tool versions + git state (best-effort; never fatal).
# ---------------------------------------------------------------------------
record_environment() {
  {
    echo "## Android Phase 0 verification environment"
    echo "mode=${MODE}"
    echo "timestamp=${TIMESTAMP}"
    echo "repo_root=${REPO_ROOT}"
    echo "evidence_dir=${EVIDENCE_DIR}"
    echo
    echo "## host"
    uname -a 2>&1 || true
    sw_vers -productVersion 2>/dev/null || true
    echo
    echo "## ANDROID_HOME=${ANDROID_HOME:-<unset>}  ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-<unset>}"
    echo "## JAVA_HOME=${JAVA_HOME:-<unset>}  GRADLE_USER_HOME=${GRADLE_USER_HOME:-<default>}"
    echo
    echo "## tool versions"
    echo "--- java -version ---"; java -version 2>&1 || true
    echo "--- python3 --version ---"; python3 --version 2>&1 || true
    echo "--- adb version (best-effort) ---"; adb version 2>&1 || true
  } >"${META_TXT}" 2>&1
  shasum -a 256 "${META_TXT}" | awk '{print "environment.txt.sha256=" $1}'
}

record_git() {
  : >"${GIT_TXT}"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      echo "is_git_repo=yes"
      echo "head=$(git rev-parse HEAD 2>&1)"
      echo "branch=$(git rev-parse --abbrev-ref HEAD 2>&1)"
      echo "describe=$(git describe --tags --always 2>&1 || true)"
      echo "worktree=$(git rev-parse --show-toplevel 2>&1)"
      echo "--- status --porcelain ---"
      git status --porcelain 2>&1 || true
      echo "--- worktree list ---"
      git worktree list 2>&1 || true
    } >>"${GIT_TXT}" 2>&1
  else
    echo "is_git_repo=no (not a git repository at ${REPO_ROOT})" >>"${GIT_TXT}"
  fi
  shasum -a 256 "${GIT_TXT}" | awk '{print "git.txt.sha256=" $1}'
}

collect_test_xml() {
  local name="test-xml"
  local dest="${EVIDENCE_DIR}/test-xml"
  rm -rf "${dest}"; mkdir -p "${dest}"
  local manifest="${EVIDENCE_DIR}/${name}.log"
  : >"${manifest}"
  local count=0
  # Gradle JUnit XML lives under <module>/build/test-results/<variant>/*.xml
  while IFS= read -r xml; do
    local rel
    rel="$(echo "${xml}" | sed "s#^${REPO_ROOT}/##")"
    cp "${xml}" "${dest}/$(echo "${rel}" | tr '/' '_')"
    local sha
    sha="$(shasum -a 256 "${xml}" | awk '{print $1}')"
    printf 'xml\t%s\tsha256=%s\n' "${rel}" "${sha}" >>"${manifest}"
    count=$((count + 1))
  done < <(find android -path '*/build/test-results/*' -name '*.xml' -type f 2>/dev/null)
  printf 'step\t%s\trc=0\txml_count=%d\tmanifest=%s\n' "${name}" "${count}" "${name}.log" >>"${STEPS_TSV}"
  echo "    ok   ${name} (${count} JUnit XML file(s) collected)"
}

# ---------------------------------------------------------------------------
echo "==> recording environment + git state"
record_environment
record_git

# ---------------------------------------------------------------------------
# Step 1: toolchain preflight (fail-fast; environment failure, not a test fail)
#   In BOTH modes a preflight failure is an environment problem (missing/wrong
#   JDK, missing SDK/platform/build-tools, wrapper or distribution checksum
#   failure, or -- in offline mode -- the Gradle distribution not cached). We
#   stop BEFORE Gradle so an environment failure is never mislabelled as a
#   source-code test failure, and offline mode can never silently fall back to
#   downloading the distribution.
# ---------------------------------------------------------------------------
echo "==> step 1: toolchain preflight"
preflight_cmd=(python3 scripts/check_android_toolchain.py)
if [[ "${MODE}" == "offline-preprovisioned" ]]; then
  preflight_cmd+=(--offline)
fi
if ! "${preflight_cmd[@]}" >"${EVIDENCE_DIR}/toolchain-preflight.log" 2>&1; then
  cat "${EVIDENCE_DIR}/toolchain-preflight.log" >&2
  shasum -a 256 "${EVIDENCE_DIR}/toolchain-preflight.log" | awk '{print "toolchain-preflight.log.sha256=" $1}'
  printf 'step\ttoolchain-preflight\trc=3\tlog=toolchain-preflight.log\n' >>"${STEPS_TSV}"
  echo "ENV: toolchain preflight failed; aborting before Gradle (environment failure, not a source-code test failure; no silent online switch)." >&2
  exit 3
fi
shasum -a 256 "${EVIDENCE_DIR}/toolchain-preflight.log" | awk '{print "toolchain-preflight.log.sha256=" $1}'
printf 'step\ttoolchain-preflight\trc=0\tlog=toolchain-preflight.log\n' >>"${STEPS_TSV}"
echo "    ok   toolchain-preflight"

# ---------------------------------------------------------------------------
# Step 2: shipping-path gate (build-config evidence; A-01 stays OPEN)
# ---------------------------------------------------------------------------
echo "==> step 2: shipping-path gate"
run_step_shell shipping-path-gate "python3 ci/check_shipping_path.py --root ."

# ---------------------------------------------------------------------------
# Step 3: wrapper + distribution verification (exercises the pinned wrapper)
# ---------------------------------------------------------------------------
echo "==> step 3: wrapper + gradle distribution verification"
if [[ "${MODE}" == "offline-preprovisioned" ]]; then
  run_step_shell gradle-version "cd android && ./gradlew --offline --version"
else
  run_step_shell gradle-version "cd android && ./gradlew --version"
fi

# ---------------------------------------------------------------------------
# Step 4: gradle clean + core/mesh/llm unit tests + app LIGHT Kotlin compile
#   :core:testDebugUnitTest  -- core (incl. Blake2s conformance)
#   :mesh:testDebugUnitTest  -- mesh (incl. port-vector tests, Noise session)
#   :llm:testDebugUnitTest   -- llm (incl. Android Oracle AnswerValidator tests)
#   :app:compileLightDebugKotlin -- LIGHT shipping Kotlin compile (no native)
# ---------------------------------------------------------------------------
echo "==> step 4: gradle clean + unit tests + LIGHT compile"
run_step_shell gradle-phase0 \
  "cd android && ./gradlew ${GRADLE_ARGS[*]} clean :core:testDebugUnitTest :mesh:testDebugUnitTest :llm:testDebugUnitTest :app:compileLightDebugKotlin"

# ---------------------------------------------------------------------------
# Step 5: Android Oracle ViewModel runtime-state tests (no native model)
# ---------------------------------------------------------------------------
echo "==> step 5: Android Oracle ViewModel runtime-state tests"
run_step_shell gradle-oracle-vm \
  "cd android && ./gradlew ${GRADLE_ARGS[*]} :app:testLightDebugUnitTest --tests '*OracleViewModelTest*'"

# ---------------------------------------------------------------------------
# Step 6: collect JUnit XML evidence + SHA-256
# ---------------------------------------------------------------------------
echo "==> step 6: collect test XML"
collect_test_xml

# ---------------------------------------------------------------------------
# Step 7: machine-readable summary (JSON)
# ---------------------------------------------------------------------------
echo "==> step 7: machine-readable summary"
python3 - "${STEPS_TSV}" "${SUMMARY_JSON}" "${MODE}" "${TIMESTAMP}" "${EVIDENCE_DIR}" "${OVERALL}" <<'PY'
import json, sys, pathlib, hashlib
steps_tsv, out_json, mode, ts, edir, overall = sys.argv[1:7]
steps = []
for line in pathlib.Path(steps_tsv).read_text().splitlines():
    if not line.startswith("step\t"):
        continue
    parts = line.split("\t")
    name = parts[1]
    info = {"name": name}
    for p in parts[2:]:
        if "=" in p:
            k, v = p.split("=", 1)
            info[k] = v
    info["passed"] = (info.get("rc") == "0")
    steps.append(info)
evidence_files = []
base = pathlib.Path(edir)
for f in sorted(base.iterdir()):
    if f.is_file():
        evidence_files.append({"file": f.name, "sha256": hashlib.sha256(f.read_bytes()).hexdigest()})
summary = {
    "verdict": "PASS" if overall == "0" else "FAIL",
    "mode": mode,
    "timestamp": ts,
    "evidence_dir": edir,
    "overall_exit_code": int(overall),
    "required_steps": [s["name"] for s in steps],
    "steps": steps,
    "evidence_files": evidence_files,
}
pathlib.Path(out_json).write_text(json.dumps(summary, indent=2) + "\n")
print("    wrote " + out_json)
PY
shasum -a 256 "${SUMMARY_JSON}" | awk '{print "summary.json.sha256=" $1}'

# ---------------------------------------------------------------------------
echo "==> done"
echo "    verdict: $(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['verdict'])" "${SUMMARY_JSON}")"
echo "    evidence: ${EVIDENCE_DIR}"
exit "${OVERALL}"