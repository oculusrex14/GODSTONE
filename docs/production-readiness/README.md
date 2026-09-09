# GODSTONE builder handoff

Start with README.md and the individually addressable sections/01.md through sections/09.md, sections/24.md through sections/28.md and sections/31.md as needed. Then load only tasks/T01.md and the invariants. Do not inject the complete1MiB master into one smaller-model prompt. It contains all31 requested sections and84 full task specifications. TASKS.json carries the same task requirements plus dependencies and command-stage contracts. Do not load the full task catalog into every small-model context: select one task and its required architecture sections.

Planning baseline: `b5c3d3d394b70cf356cdde33b47511dad7cbb95c`. Existing branch: `codex/archive-reliability`, dirty. This package does not implement application changes. Preserve the original checkout/WIP in T01 and create a clean continuation worktree before copying these files to docs/production-readiness/.

The requested Qwen3.8 Flash Next/Oh My Pi installation is unverified. T02 inspects actual local help/model metadata and registers DGX and Mac executors; no unverified harness launch command is supplied. The tools/readiness commands and ReadinessTxx regression files are proposed implementation artifacts, not existing tools/tests.

The plan keeps readiness=false, preserves frozen BLE/LinkInfo/wire/identity contracts, and separates shipping Archive from experimental mesh/Oracle. Native inputs, approved content, independent Noise fixtures, device evidence and signing remain external gates. The builder may not close them with fixtures or rename a partial result production-ready.

BUILD_STATE.template.json and ARCHITECTURE_INVARIANTS.template.json are initialization templates, not evidence of completed work. Full state schemas, retry policy, Git checkpoint protocol and audit bundle are in sections24–30.

CHECKSUMS.json hashes the deliverables. PLANNING_VALIDATION.json records structural validation of this package only; it is not GODSTONE test/build/production evidence.
