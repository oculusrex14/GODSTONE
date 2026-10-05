# Candidate status — AUDIT-003-R1, COMPUTED at round 122 (every figure re-derived from the ledger)

> **CURRENT STATE (2026-10-05) — DERIVED, NOT CARRIED.** *Everything below this banner is HISTORICAL
> candidate narrative from the round-122 era and is preserved verbatim; its SHAs, lane counts and class
> membership are NOT the current state.* **The current canonical state is DERIVED by
> `scripts/build_structured_closure.py`: builder status `REMEDIATION_IN_PROGRESS`, **35 internal obligations
> DISCHARGED and 0 OPEN** (no finding remains internally OPEN: `findings_with_internal_status_open = 0`). The FOUR
> `AUDIT-B1-CTRL-001` closure-control discharges are now earned by their OWN scope-specific generator-semantic
> mutation evidence -- five standalone strikes at preparatory B `46903cd0` over the unchanged guard logic
> (`CLOS-PARTIAL-BLIND`, `CLOS-DRIFT-BLIND`, `CLOS-SCHEMA-BYPASS`, `CLOS-FINDING-CONSISTENCY-BLIND`,
> `CLOS-STATUS-POPULATION-BLIND`): each baseline 2 PASS / mutant 1 NAMED FAIL / restored 2 PASS,
> byte-identical restored B source. The separate 13-case negative-input court remains C0 history;
> neither population is booked as registry rows or aggregated with the canonical controls. Each of the
> 35 discharged obligations carries an authored, production-reachable `structured_discharge` (the seven fields + an
> external `candidate_binding` that names ONLY the prospective rc15 candidate ref (`production-readiness-board1-rc15`),
> the external evidence bundle (manifest `docs/remediation/evidence/board1-evidence-bundle.json`) and the future
> attestation path (`FREEZE_ATTESTATION_rc15.json`, reserved until freeze) -- NO closure SHA is embedded); `verified_fixed = 0` (only an independent audit may write
> it), 5 external obligations
> (`gs-final-004.native-engine-half`, `gs-runtime-001.android-keystore`, `gs-store-002.sqlcipher-engine`,
> `gs-stress-001.device-radio`, `gs-ux-001.human-accessibility-acceptance`).**
> *The rc14 candidate, its tag object and its attestation remain immutable historical evidence; the rc14
> attestation's blanket internal-completion verdict is NOT a current completion claim.* **The prospective
> bound candidate is `production-readiness-board1-rc15` (its tag is created at freeze time; until then the
> ref resolve th to nothing, which is the honest pre-freeze state, never a stale rc14 authority).** **NO
> candidate carries a valid freeze for the current tree, and no READY status is asserted.**
> **Source reconciliation (2026-10-04):** each authored review gap now carrieth, in place, a `review_status`
> against the current production source -- 42 `REPAIRED_STALE`, 0 `PARTIAL`, 0 `LIVE`
> (`IOSR13-ACCESSIBILITY-ROSTER-INCOMPLETE`, formerly the sole PARTIAL, is now `REPAIRED_STALE`: the iOS rendered-role
> half is asserted in-process and the current UI run passed 43 tests / 0 failures -- LabMesh 29 accessibility 11 +
> functional 18, LIGHT 14 -- with human acceptance remaining the existing external obligation). A `REPAIRED_STALE` status
> settles ONLY the source half of a review's claim and does NOT discharge any obligation.
> **Historical campaign (2026-10-04):** the full board1 campaign on baseline `c5a565fcb83e3e636ebe3ac253bd0f6351d41da3`
> (tested tree `f67d8dd18be11928c39a3932296217a7dc5b8604`, canonical manifest `docs/remediation/evidence/board1-rc15-rods`)
> recorded **179 SEMANTIC controls KILLED and 2 STRUCTURAL controls KILLED**; these populations stay separate
> and are NEVER quoted as a combined score (`LANE-ROD-6-android-runner-aborts-before-digests` tests_run 1/restored 1; `ARCHIVE-PROV-007` tests_run
> 43/restored 43). SEMANTIC catches split into 178 `witness`-channel rows (build_exit 0) and ONE lawful
> `compiler`-channel row, `IOS-RECOVERY-006` (build_exit 1, tests_run null, restored-green 10).
> STRUCTURAL catches are TWO `witness`-channel rows (build_exit 0), accounted separately.
> `IOS-RECOVERY-006` strikes the source-bound TYPE-ENFORCEMENT invariant: compile-time refusal is its intended
> kill, NOT a build-invalid row. Every row carries a green restored phase and its own
> phase-log digests; `python3 -B ci/mutations.py --selftest-manifest --group board1 --manifest-dir
> docs/remediation/evidence/board1-rc15-rods` PASSED at that checkpoint, not on the corrected source. The earlier `4f84d0b6` run (179 KILLED + 2 EXEC_INVALID: IOS-RECOVERY-005,
> SH-R13 -- each retained the original find needle inside its replacement, so the strict installation postcondition
> correctly refused; the two registry needles were then completed to WHOLE-LINE needles so post-find=0, with NO harness
> weakening) and the selected two-rod qualification on `f66a1b41` are **DISTINCT earlier runs**, not folded into the 181.
> **Historical integration stage proof (2026-10-04):** the full `--mode all` integration **PASSED** on clean full SHA
> `b7bac67f018b015b0038ec11b3228bba9de59545` -- checker `python3 -B ci/check_integration_evidence.py --report
> /tmp/board1-rc15-integration-b7bac67f/integration-report.json --require-mode all` = **PASS** (rows 10, cross 8, crash 2,
> digests+inputs bound; 533.00s). BOTH honest directions ACCEPTED/DELIVERED the correct AUTHORED msg_id after a separate
> durable cancel+reopen; the SIX negative variants each REFUSED at their exact stage (unauthenticated / hs2 / old-session);
> the macOS SIGKILL campaign rc 0 with two fresh recoveries on the actual Android TestExecutor; natural `bye` on BOTH
> workers with command EOF (the 120s oracle unchanged). The coordinator fix `b7` centralizes `Worker.send('bye')` to close
> the command FIFO ONCE (idempotent `Fifo.close`), reply pipe unchanged, with NO new APIs and NO source-worker change.
> Source pre/post `ad11a88866de38fc47284a6e71d2719b56addd3ae50fcf0e95768f8808146419`. Those historical
> outputs do not bind the corrected source family. All ten lanes and the full canonical campaign are now
> measured green at preparatory B `46903cd0`; strict campaign and integration proof must still bind final immutable C after its tracked writes. All 35 internal obligations are
> DISCHARGED on earned proof and NONE remain OPEN: the CLOSURE-CONTROL block (the four `AUDIT-B1-CTRL-001`
> obligations) is now earned by its OWN generator-semantic strike evidence, and
> `gs-final-006.mutation` is DISCHARGED on its OWN separate four-rod restoration campaign at B `46903cd0`
> (tree `d74dc5e2…`, all four SEMANTIC controls KILLED with restored-green, never aggregated with the canonical controls); the five external gates stay
> OPEN, so NO READY claim is made, and the guard LOGIC is UNCHANGED by this DATA-only authoring -- the parent runs the
> FINAL-C re-integration/attestation/freeze.**
> **Historical closure-control strikes (2026-10-04):** the four closure-control discharges initially rested on
> `docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes/` (18 files: manifest + 15 phase logs +
> `CONSUMER-POSITIVE-real-ledger.baseline.log` + `NEGATIVE-INPUT-COURT-13cases.log`), each baseline/mutant/restored
> phase carrying its own digest and each restored run byte-identical to C0. The **56-test** closure-law court
> (`docs/remediation/evidence/board1-rc15-closure-controls/courts.log`, `Ran 56 tests ... OK`) and the separate
> **13-case** negative-input court (`NEGATIVE-INPUT-COURT-13cases.log`, 4 tests / 0 failures) are DISTINCT from the
> canonical 181 (179 semantic + 2 structural); the closure-law fixture authority was repaired
> (`ci/check_candidate_binding.py` refreshed from live in the scratch worktree, the citation trees provisioned) so the
> GREEN baselines are attributable to the real authority rather than to a broken fixture. The recorded 56-test court
> remains C0 history. The obsolete live-source gap-layout assertion was removed, not re-pinned; the separate
> pre-freeze behavioral contract court passed **78 tests / 0 failures**
> (`docs/remediation/evidence/board1-rc15-closure-controls/final-contract-courts.log`).
> Neither court claims an exact final-candidate integration or authenticated freeze.
> **Hosted prerequisite refusal:** untagged candidate `9e4064edd6d3c5d17c07fcaed45d147d77bd9b20` failed
> [release attempt 1](https://github.com/oculusrex14/GODSTONE/actions/runs/37207140714) and
> [repository verification](https://github.com/oculusrex14/GODSTONE/actions/runs/37207140743).
> Kotlin resolution and clean-checkout prerequisites refused before terminal proof; the repository terminal job
> was skipped. The two internal LIGHT release jobs passed, but that is not a complete release or readiness claim.
> At this pre-freeze checkpoint, no rc15 tag or attestation exists. Corrected prerequisites, a newly committed candidate and its own proofs are required.
> **Prepared clean-clone registry proof:** the original paths, identities and registered raw digests are retained.
> `scripts/materialize_external_registry_proof.py --write` produced **837** staged content-addressed gzip objects;
> its real `--check` verified **896** non-lost external references. All 837 decompressed SHA-256 values were checked,
> with 0 missing or mismatched objects (98,435,155 raw bytes; 7,884,005 compressed bytes).
> A valid absent absolute builder-root declaration still verified 896 references; a relative declaration refused
> by name. The consumer reads only tracked clone-carried proof, not the builder root.
> The single anchored declared loss remains a loss. These historical carriers are not current runtime proof,
> canonical mutation catches, external-gate closure, or an authenticated candidate freeze.
> A six-class credential-pattern scan found no matches; that limited scan is not a blanket secrecy guarantee.
> **Corrected prerequisites, pre-freeze proof only:** Foundation manifest membership now follows Git-owned
> sources, not the presence of ignored generated SQLCipher expectation output. The real mirror `--check`,
> 41 integration-evidence selftest cases and 12 isolated Foundation/integration fixture tests passed.
> The shell-rod probe passed under POSIX `dash`, including both ShellRodGuardWitness controls.
> Kotlin resolution now bounds braceless declarations, retains qualified owner identity, and confines a
> `when` smart cast to one nominal arm and its live, unshadowed, unwritten subject binding.
> The actual repository parity run passed **7 checks**, scanning **301 Kotlin files / 0 unresolved**;
> its selftest legal/refusal controls and **45** resolver regressions passed. Four previously false-accepted
> consumer cast probes now refuse the invalid member while also refusing the deliberately missing control.
> The complete readiness roster passed: **1049 collected / 1019 required internal / 30 historical excluded**,
> with exact identities and zero internal skips or nonpassing outcomes
> (`/tmp/board1-rc15-prerequisite-smoke-4347d047/readiness.log` and its recorded result JSON).
> At that prerequisite checkpoint, the canonical manifest verified **179 semantic + 2 structural**
> killed/restored rows with current input bindings; all ten parsed runtime lanes passed without failed or skipped arms.
> These local prerequisite results neither replace exact-candidate integration nor authenticate hosted
> release, terminal proof, an rc15 tag or a freeze.
> **SDK licence-input repair:** repository run 37222995728 attempts 1+2 reported `yes exited 1`.
> That producer status alone does not establish the consumer's status or an entropy/toolchain defect.
> The attempted `/dev/zero` replacement at `70bd34c6` supplied NUL bytes, not newline-terminated `y` answers;
> repository run 37224515975 recorded `OutOfMemoryError: Java heap space` in `SdkManagerCli.askYesNo`.
> The corrected script uses a checked finite file of 64 `y` lines and requires the actual consumer status to be zero;
> no missing-status fallback fabricates success. Archive/tree pins, package installation and the NDK assertion remain.
> Parent execution passed both fresh-root and warm-root provisioning on a constrained 64m heap (44.34s combined),
> reporting pinned sdkmanager 12.0. A real invalid-JVM invocation refused with consumer status 1 before success exports.
> These are local prerequisite proofs, not a hosted seven-job result or freeze.
> **Hosted iOS court repairs:** run 37225074109 on untagged `a4a66efb` refused the Foundation and UI lanes.
> The adoption court read its fixture keychain but omitted that keychain from staged promotion, accidentally
> targeting the machine keychain. It now uses one owned keychain throughout; the isolated real adoption arm passed,
> including foreign-key refusal, unchanged private state and legitimate full-key crash adoption. No RNG defect was established.
> The stress reopen now installs the campaign's manager factory on each new owner before `lifecycle.start()`;
> its independent **10k (157.715s)** and **30k (1092.162s)** schedules passed with unchanged seed, lengths,
> census and bounds, under stable **main-checkout** source digest `15d71a3d…`. That complete host lane passed **1533 arms /
> 0 failures / 0 skips** (1509.48s, `/tmp/board1-rc15-main-source-15d71a3d-evidence/ios-lane.log`), separate from the clean-B proof below.
> The preceding `1ebc27ac…` host run's five startup refusals were separate failures, not a swallowed suite.
> Source tracing located them at a pre-issuance ownership mismatch: the bootstrap captured an unbound estate
> registry, then construction joined the real shared identity/DEK root with a different revision.
> The selected repair prepares the exact declared inventory only after a durably settled recovery decision,
> before evidence captures its physical revision. Preparation errors must propagate without issuing a permit;
> corrupt/pending decisions, the bind-before-consume boundary, generation freshness and one-shot consumption remain.
> The throwing API and genuine Mesh/Lab/UI callers are migrated. Parent execution passed the **55-arm**
> startup/topology/store court (16.65s including compile): all five original failures now pass, as do the new
> nonzero-shared-root admission, post-issuance revocation, and preparation-error/spent-drive transitions.
> The new Lab error-boundary arm also passed: a thrown wipe drive remains non-complete, blocks ordinary use
> and carries its actual error. The clean-B native family is now re-sealed below; earlier native logs are history.
> The UI court retains the 44pt floor and absorbs only a two-ULP-per-endpoint coordinate-roundoff bound,
> identically for both axes and all four scale/direction rosters. A numerical control refused 0.001pt, 0.25pt and 1pt
> undersize at four coordinate scales. Both actual simulator schemes passed **43 required arms / 0 failures / 0 skips**
> with stable new-source digest `15d71a3d…` (778.93s,
> `/tmp/board1-rc15-main-source-15d71a3d-evidence/ios-ui-lane.log`); the rebuilt app's live Conversation surface was
> also launched and visually observed. Human/device accessibility acceptance remains external.
> The earlier conditional native court passed **1403 arms / 0 failures / 0 skips / 0 unfinished** at
> source `1ebc27ac…`; the later clean-B court below supersedes it with **1406 arms / 0 failures / 0 skips**.
> A separate clean Android court passed all **seven** families (267.835s): app 128, core 22, mesh 1479,
> labmesh 40, UI 168, simulator 40 and production 1479, each with zero failures, errors and skips.
> Its packaged-byte inspector passed against the actual staged Archive; counts remain lane-specific, not aggregated.
> The source-aware ten-lane verifier independently accepted all seven Android families and the three iOS families
> from the clean-B source family; lane counts are never summed. The complete 298-file Android lane/result/sidecar
> population was retained under `docs/remediation/evidence/board1-rc15-candidate-46903cd0/android-lanes/`
> and then re-read by the checker, including all three report-lane manifests and packaged Archive inspection.
> **Cold candidate source isolation:** preparatory commit `46903cd040ffae9f2cd20529aad54ac6166bd6ad`
> (tree `d74dc5e2679b69358663402e8c4711bea0d519db`) is untagged and is not final C.
> Its clean detached checkout built and verified the real pinned macOS image, then reconstructed source family
> `6428ac1e…` (30.89s). The main checkout's `15d71a3d…` family includes one pre-existing ignored fault database
> under Archive fixtures (created 2026-09-25, modified 2026-10-02); that user-owned file remains untouched.
> Main-family host/UI results are retained separately at `/tmp/board1-rc15-main-source-15d71a3d-evidence`.
> The clean checkout's two actual UI schemes passed **43 required arms / 0 failures / 0 skips** (835.31s);
> the real source-aware reader accepted digest `6428ac1e…`, and the rebuilt LabMesh Conversation surface was
> launched and visually observed. The clean Foundation lane passed **98 suites / 1533 arms / 0 failures / 0 skips**
> (2517.70s; Core 111 / Mesh 1413 / Lab 9), accepted by the real source-aware reader.
> Both unchanged full stress schedules passed: **10,000 cycles in 390.594s** and **30,000 in 1710.378s**,
> including the real reopen checkpoints and fixed owner bounds. The actual thrown-wipe UI boundary passed too.
> Raw host/UI logs and original digest sidecars are retained at `docs/remediation/evidence/board1-rc15-candidate-46903cd0/`.
> The clean native court passed **85 suites / 1406 arms / 0 failures / 0 skips / 0 unfinished** (2440.44s),
> with raw `xcodebuild` status zero and stable pre/post source family `6428ac1e…`; its real bundle, raw logs and
> sidecars are retained under `docs/remediation/evidence/board1-rc15-candidate-46903cd0/`.
> The full `--mode all` preparatory integration also passed (1551.00s): all **10 rows = 8 cross-platform + 2 crash**,
> candidate/tree and 26 tested-input digests bound, with the real evidence checker green. Because tracked proof data
> still changes after this B, final immutable C must rerun both campaign and integration; none is credited to C yet.
> A separate isolated LIGHT device package built and passed the actual packaged-byte inspector (33.07s,
> arm64, source-only-exclusion, no Archive expected); its real report is retained in the same B evidence namespace.
> Shipping/content/device approval remains external; this unsigned source-only package does not discharge it.
> The separate four-restoration campaign passed **4 SEMANTIC KILLED / 0 other outcomes** (611.10s),
> with green restored rosters (21 Android / 28 iOS), source-currency acceptance, and all 12 raw phase hashes checked.
> Proof is retained in its own `docs/remediation/evidence/board1-rc15-restoration-rods-46903cd0/` namespace,
> never aggregated with the canonical controls. A first 181-control run terminated after 71 complete triads without a
> manifest and is not credited. The original subsequent full `--group board1` campaign has now completed
> (17374.71s): **179 SEMANTIC controls KILLED and 2 STRUCTURAL controls KILLED, reported separately**;
> every required control has its actual restored-green companion, with no escapes, invalids, skips or timeouts.
> Manifest self-validation passed on the clean B judge before and after DGX offload. Its byte-identical
> manifest and all 543 raw phase logs are clone-carried under
> `docs/remediation/evidence/board1-rc15-candidate-46903cd0/canonical-campaign/`; every phase digest was checked.
> These are preparatory B results, not final-C campaign, hosted convergence, tag or attestation proof.
> The clean-B readiness court passed its complete exact-identity roster (1171.09s): **1049 collected,
> 1019 internal required passed, 30 historical excluded**, no internal skips/nonpassing outcomes.
> Its raw log, recorded identities and roster are retained at `docs/remediation/evidence/board1-rc15-candidate-46903cd0/`.
> The actual resolver selftest and 45 behavioral controls also passed; repository parity passed **all seven**
> internal invariants, scanning 301 Kotlin files with zero unresolved members, after the real MEDIUM Archive
> prerequisite was built. Noise conformance stays explicitly external and OPEN.
> The separate **five unregistered generator strikes passed** (113.75s):
> each actual baseline/restored phase ran two green arms, each mutant failed exactly its named witness, and all
> 15 raw-log SHA-256 values and byte-identical source restorations were checked. New proof lives at
> `docs/remediation/evidence/board1-rc15-closure-controls/generator-strikes-46903cd0/`; C0 history is unchanged.
> **Cold terminal source reconstruction:** the terminal now verifies its pinned macOS SQLCipher image, emits
> the existing mode-independent trusted expectation and syncs the mirror before campaign/source readers.
> In a cold isolated source tree, missing generated constants mismatched the producer digest; actual verified
> emission reconstructed the exact `1ebc27ac…` digest, while counterfeit generated-source drift still refused.
> No generated-source exclusion, consumer digest re-pinning or source-hash fallback was introduced.
> The corrected scratch-emission/placement sequence also ran in a real cold Git clone of checkpoint `a4a66efb`
> under `CI=true` (26.55s). Its source digest exactly reproduced the authenticated checkpoint producer digest
> `40333884…`, and the real mirror `--check` passed. This bootstrap smoke is not final-C lane or campaign proof.
> **Supply preflight (2026-10-04):** the four preflight supply refusals are REPAIRED by the canonical existing generators
> only (no code guard/pin/source change): the current `ios/project.yml` fingerprint is captured (`0c4a39…`), the SBOM now
> carries 566 components including 3 SQLite 2.6.2 coordinates, and 6 CycloneDX faces are refreshed.
> `verify --all` and `sbom-export --check` PASS with HONEST warnings (cmake absent / unpinned tool versions / a
> debug-dex nondeterminism) -- reproducibility is NOT claimed, and no guard was weakened.
> Compiler refusal is a catch only for the explicitly declared permit type-enforcement control;
> ordinary compile errors, missing execution, skipped cases and timeouts remain non-catches.
> The simulator stock-SQLite oracle now stages the resolved device's runtime image, validates its export
> surface, and checks the copied digest; missing supply remains a named failure, never a skip.
> SQLCipher expectation generation now produces one source for both approved host/simulator modes,
> selected at compile time, so preparing one lane does not invalidate its sibling's source digest.
> Staging and the real host-image verifier were exercised successfully; the strengthened replacement-image
> refusal witness passed. Preparatory B simulator and campaign re-sealing are complete; exact-C verification and release freeze remain pending.
>
> **Hosted candidate probe `a73da925` (run `37266700328`, attempt 1): FAILED, not frozen.**
> Constraints, parity/readiness, content, mesh simulation and Android passed. The iOS job stopped before
> simulator execution: its resolved iOS 27.0 cryptex runtime supplied no plain `usr/lib/libsqlite3.dylib`.
> The stock-oracle guard correctly refused missing supply; the terminal job was skipped and no exact-C
> mutation campaign or gate manifest was produced. Release proof `37266700386/1` measured internal PASS
> with typed external `BLOCKED_EXTERNAL`; that is not seven-job convergence or READY.
> The hosted prerequisite is now explicit: `provision_ios_simulator_runtime.py` reads the registered
> iOS 26.3.1 / build `23D8133` / arm64 identity, installs it only if absent, and binds a unique device
> before the simulator lane. No stock-image/export/cipher or source-digest guard changed.
> Local create and reuse paths both passed without a runtime download. The actual created device's stock
> image passed unchanged staging: 2024112 bytes, IOSSIMULATOR/arm64, SHA256
> `7acd62eeaf83809cb22da08615c10b0a08f28fb029d4cf2a935525e02e25c3d5`.
> Hosted installation was measured successfully by the next immutable probe below; exact-candidate convergence remains pending.
>
> **Hosted candidate probe `3883c9f3` (run `37275912694`, attempt 1): SIX prerequisites PASS, terminal FAILED.**
> The iOS job completed in 4h14m. Its actual simulator log names the provisioned iOS 26.3 device and
> build `23D8133` runtime image, with the same 2024112-byte stock SHA256 recorded above.
> All 1406 simulator tests passed; the raw xcodebuild status was 0. Constraints, parity/readiness,
> content, mesh simulation and Android also passed. The integration producer completed mode `all`
> with eight cross-platform and two crash rows, but that hosted producer result is not yet portable replay proof:
> the downloaded consumer refused a different local compiled-bundle digest and the absent runner-temporary
> SQLCipher image. No unrelated local binary may stand in for those attested bytes.
> Terminal verification failed at authenticated release capture before the canonical campaign or gate manifest.
> The collector discarded log-retrieval failures into an empty string, then reported a missing boundary command
> section; the underlying hosted retrieval cause was not retained and is not asserted.
> `UNKNOWN STEP` display labels are not the cause: actual command groups and typed markers survived in the
> retained log, and the existing section parser accepts those prefixes.
> The reader now retrieves the exact run/attempt/job archive through `gh run view --log`, propagates retrieval
> errors, and refuses blank logs explicitly. Actual capture of release attempt `37275912618/1` passed in
> 15.43s with internal PASS and typed external `BLOCKED_EXTERNAL`; command-scoped marker, named-step,
> internal-failure and remote candidate/tree checks are unchanged.
> Both failed probes remain untagged. The next immutable candidate must supply its own complete campaign,
> portable integration bytes, all 27 gates and all seven hosted jobs before rc15 freeze.
>
> **Portable tested-byte cutover:** fresh build attestations now use schema 3 and a mandatory
> report-relative `tested-bytes.tar`. The archive carries the actual tested bundle tree and registered
> SQLCipher image/descriptor pair. Both the raw archive hash/size and each payload digest are checked;
> original paths remain runtime provenance, not replay locations or local-build fallbacks.
> The producer verifies copied bytes before publication. Skip-build validation reads the previous archive
> without regenerating it, then carries that verified archive into the new report directory.
> An actual compiled Swift bundle and register-verified 1225016-byte macOS image were packaged directly on
> DGX and re-read successfully: archive 30935040 bytes, SHA256
> `dc5b586cc1bdba7c604d874708adc5262f7eebbb1b11b773d7c86eb86902b096`.
> All 15 integration behavior tests and the integration gate's 43 isolated selftest cases passed.
> These are API/guard proofs, not a new integration campaign or canonical mutation result.
> A fresh mode-`all` report from the next immutable candidate remains required.
> The producer also revalidates the live bundle/image/archive after all workers finish and before publishing
> a PASS report. An owned copy of the real compiled bundle was changed after retention; the record reader
> refused the drift. The original bundle was untouched and the temporary copy was removed.
>
> **Hosted candidate probe `5118d94e` (run `37310847380`, attempt 1): Android FAILED before terminal proof.**
> The actual Android job reports 1479 tests / 1 failure. Its failed XML case, `ReadinessT23Test`
> `testTheExactDuplicateIsSparedTheFreshSequencePerisheth`, expected `HANDSHAKE_IN_PROGRESS` but observed `CLOSED`.
> This fixture replayed only the first fragment of a 32-byte HS1. At the default 20-byte ATT value length,
> the first fragment carries only 12 payload bytes, so production correctly refused a different record.
> Asynchronous handshake startup made the first fragment's completeness depend on the MTU timing.
> The existing T22 full-record reassembly pattern now serves both HS1 and HS2 duplicate fixtures in T23.
> All exact-duplicate, fresh-sequence refusal and heard-once assertions remain; no production authority changed.
> The real affected class passed locally: **18 tests / 0 failures / 0 errors / 0 skips**, Gradle 22s.
> At this checkpoint iOS remained in progress, and no C3 canonical campaign had started.
> The corrected source requires a new immutable candidate; C3 is not tagged, frozen or relabelled as green.
>
> **Completed C3 iOS verdict:** the all-three-lane aggregate also failed. The Simulator ran 1406 tests
> and reported two assertions in the same seeded failure-address arm. Both replays deliberately injected
> one unreleased slot at cycle 399 and reported the same seed, cycle, class and resource census.
> Their addresses differed only in the wall-clock heartbeat, `sweepTicks=10` versus `0`; this was not an
> unexpected production slot leak. The private failure-address census now excludes that clock field.
> The real resource-leak oracle, complete address equality, completed-cycle equality and independent
> lease-sweep liveness witness remain. The obsolete delimiter-based repeat comparison was deleted,
> not repinned. No production source, retry, census bound or schedule was changed.
>
> **Hosted candidate probe `a71c697c` (run `37324195279`, attempt 1): five non-iOS prerequisites PASS,
> iOS FAILED before Simulator/integration/terminal proof.** Android passed with the complete-record fixture.
> LabMesh's announcement arm timed out in its 15s `XCUIElement` predicate wait for the octet readout,
> before checking the announcement. The same run's sibling multibyte-compose arm moved the readout.
> The existing live-tree polling convention now serves the announcement arm instead of predicate/KVC
> observation. Existing 15s/20s bounds and the real readout, outcome-transition and announcement-equality
> assertions remain. Outcome transition compares the actual pre-send rendered baseline, not incidental
> English placeholder wording. No production UI or accessibility delivery was changed.
> Actual release capture `37324195277/1` passed with internal PASS and external `BLOCKED_EXTERNAL`.
>
> **Pre-seal repaired-path smoke, not exact-C campaign proof:** the two real seeded-runtime/liveness arms
> passed on Foundation (8.960s) and the registered iOS 26.3.1 / `23D8133` Simulator (8.106s), both with
> zero failures. The actual LabMesh multibyte-input → outcome-change → announcement arm passed on iOS
> 26.5 in 21.562s. Logs and source/native-bound receipts are retained on DGX at
> `mac-mini-offload/GODSTONE/evidence/board1-rc15-ios-fixture-smoke-xj8m3hnk`.
> C3 and C4 remain failed, untagged probes; neither produced a canonical campaign or fresh mode-`all`
> report. The next immutable candidate must earn its own 179 semantic controls and two separately
> reported structural controls, portable integration, all 27 local gates and all seven hosted jobs.
> No rc15 tag, freeze or external closure is claimed by these smoke results.


**BOTH CANDIDATES REMAIN NO-GO.** The readiness flags are FALSE and enforced false by a passing canonical
control; THE FIVE EXTERNAL GATES REMAIN OPEN OR BLOCKED; NO finding carrieth `closure_evidence`.

## Candidate verification at `bcdfa1c` (ledger round 282) — **THE IOS-02 REPAIR LANDED**, and every lane re-measured

| Item | Result at this exact SHA (tree `06f163f`), worktree clean — the tree measured IS the tree committed |
|---|---|
| iOS lane (mirrored package) | **`Executed 1208 tests, with 0 failures (0 unexpected)`**, 83.6s — the three IOS-02 witnesses included |
| Android `:mesh` lane | **1193 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`), from the run's own 76 XML files |
| Android lab target | `labmesh-debug.apk` **forced**: 15,133,266 bytes, sha256 `0ca013caf6b5f45b…`, rc 0 |
| Python readiness suite | **582 tests, OK, rc 0** (the landed IOS-02 probe included) |
| Audit probes | **12 tests, OK, rc 0** |
| Repository controls | `check_parity --scope repo` rc 0; mandatory lab control **PASSED** (0 errors, 13 notes) |
| Symbols / digests | 223 Kotlin files, **0 unresolved**; **330/330** evidence digests verified |
| iOS lab target | **NOT claimed at this SHA**: no lab target changed, and **a cached green is not evidence** |

**WHAT MOVED.** IOS-02 step 1: production now begins the trusted handshake at the physical-duplex reduction, with the relation's captured hint, once, from `.roleBound` — and all six iOS readiness rigs are reconciled to that law (the full lane went from **61 failures to 0** by NAMED rig variants, never by bending an assertion). IOS-02 moves **OPEN → PARTIAL**; the round-281 entry's note that "IOS-02 remains OPEN" is thereby superseded.

**Not claimed:** T78 convergence (no hosted lane/URL/id/log exists here); no finding is `VERIFIED_FIXED`; readiness flags stay **false**; the **five external gates stay OPEN**; the iOS lab build is not claimed at this SHA.

## Candidate verification at `55896b9` (ledger round 281) — the CURRENT candidate, re-measured rather than inherited

| Item | Result at this exact SHA (tree `77b111e`), worktree clean |
|---|---|
| Android `:mesh` lane | **1193 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`), from the run's own 76 XML files; `BUILD SUCCESSFUL` 54s, rc 0 |
| iOS lane (mirrored package) | **`Executed 1205 tests, with 0 failures (0 unexpected)`**, 158.5s — mirror **re-generated** first |
| Python readiness suite | **579 tests, OK, rc 0** |
| Audit probes | **12 tests, OK, rc 0** (the round-281 probes live in subdirectories, which `discover` does not collect: red-by-design arms must not redden a green lane) |
| Repository controls | **every `ci/check_*.py` rc 0**; the **single** non-zero is `check_parity` under its **default** scope (= the external **A-06** arm); `--scope repo` rc 0 |
| Evidence digests | **327 registered / 327 examined / 327 verified** / 0 mismatched / 0 unresolved / 0 unnamed |
| Symbols | **223 Kotlin files, 0 unresolved** |
| Android lab target | `labmesh-debug.apk` **forced**: 15,133,266 bytes, sha256 `77056d55a6c5ce7a…`, rc 0 |
| iOS lab target | `BUILD SUCCEEDED`, rc 0, **0 `error:` lines** (simulator SDK, unsigned: **no device, no signed artifact, no T76 input**) |

**WHAT MOVED: NOTHING IN PRODUCTION SOURCE.** Round 281 measured IOS-02's defect (both entry points appear only as declarations),
took its **RED** (15 tests, exactly 2 failures, empty rejection ring), **wrote and proved the repair** (T22 **16 tests, 0 failures**,
including a witness for "do not repeat beginInitiator"), **measured the repair's blast radius** (the full iOS lane: 1208 tests,
**61 failures** across five suites whose rigs still begin the handshake by hand — T23 30, T21 26, T17 3, T19 1, T14 1), and
**parked the whole of it**, because a lane may never be left red and that reconciliation is arm by arm. The park is a re-appliable
patch (`round281-the-repair-and-the-arms.patch`, sha256 `4fe85c5e0ad28b0c…`) plus two red-by-design probes in
`tools/readiness/audit_probes/{swift,python}/`.

**Not claimed, and why: T78 convergence is NOT claimed** — no hosted lane, run URL, run id or log exists here. **No finding is
`VERIFIED_FIXED`**; **readiness flags stay false**; the **five external gates stay OPEN**; no fixture, simulated counter or lab
target is offered as a device result. IOS-02 remains **OPEN**, steps 2–5 outstanding.

## Candidate verification at `f054df7` (ledger round 278) — **THE NEW CANDIDATE, and the first whose python lane is genuinely green since round 193**

| Item | Result at this exact SHA (tree `c8241a0`), worktree clean |
|---|---|
| Android `:mesh` lane | **1193 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks --no-daemon`), counted from the run's own 76 XML result files; `BUILD SUCCESSFUL` in 1m 1s, rc 0 |
| iOS lane (mirrored package) | **`Executed 1205 tests, with 0 failures (0 unexpected)`**, 91.6s — and the mirror was **re-generated** first (`sync_ios_foundation_package.py` rc 0) |
| Python readiness suite | **578 tests, OK, rc 0** — the first candidate since round 193 whose python lane is **genuinely** green |
| Audit probes | **12 tests, OK, rc 0** |
| Repository controls | **every `ci/check_*.py` rc 0** — including the new `check_evidence_digests.py` — with the **single** non-zero being `check_parity` under its **default** scope (= the external **A-06** arm); `--scope repo` rc 0 |
| Evidence digests | **317 registered / 317 examined / 317 verified / 0 mismatched / 0 unresolved / 0 unnamed** (findings 306, convergence 11) |
| Symbols | `ci/symbols.py` — **223 Kotlin files, 0 unresolved** |
| Android lab target | `labmesh-debug.apk` — **15,185,636 bytes**, sha256 `16ada895f761e628…`, `BUILD SUCCESSFUL` rc 0 |
| iOS lab target | `BUILD SUCCEEDED`, rc 0, **0 `error:` lines** (simulator SDK, unsigned: **no device, no signed artifact, no T76 input**) |

**WHY A NEW CANDIDATE WAS REQUIRED.** Rounds **200 / 222 / 254 / 256 / 275 CANNOT STAND**: their python lane was **RED at every one** — re-measured at each candidate's exact tree — a fact hidden for **eighty-five rounds** behind a `| tail -2`
that kept the suite's trailing green and threw away its judgment. **A candidate tree with a red mandatory lane is not a candidate.** This entry replaceth them, and is measured at the SHA that repaired the court and the audit instrument.

**WHAT THIS CANDIDATE CHANGETH.** No production source. It repaireth a **court** (`test_t26_post_aead_charge.py` now judgeth the *binding* in three clauses, carrying a valid positive control and four negatives each landing on its own clause), repaireth the **audit instrument** (`ci/check_evidence_digests.py`, whose denominator now includeth the **convergence population** — 11 registered logs that **had never been digest-checked at all**), and correcteth the record.

**Not claimed, and why: T78 convergence is NOT claimed** — its requirement is that all applicable **hosted** lanes be enabled, executed and green at this SHA, and **no hosted lane, run URL, run id or log exists here**; the repository-side half is complete and the missing half is stated rather than papered over. **No finding is `VERIFIED_FIXED`** (only an independent audit may write that). **Readiness flags stay false** and the **five external gates stay OPEN**. **Closure evidence is stale** for the findings whose cards changed after the audited SHA — a *floor* on any later closure, not a clearance.

## ROUND-278 CORRECTION — the python lane was RED from round 193 to round 278 (85 rounds)

**THE TABLES BELOW WERE WRONG, AND THIS SECTION STANDETH FIRST SO THAT NOBODY READETH THEM WITHOUT IT.**

The python readiness suite was **RED for eighty-five rounds** — from `cf1bd15` (round 193) to round 278 — while **five candidate
verifications inside that span (rounds 200, 222, 254, 256, 275) recorded it `OK`**. Re-measured, not inferred:

| Tree | Verdict |
|---|---|
| `a1a7475` (round 192, the commit before the red) | `3 tests, OK` |
| `cf1bd15` (round 193) | **`FAILED (failures=1)`** — the first red |
| `03fd92b` (round 178 candidate) | the court did not yet exist there (**module error**), so that candidate's claim was TRUE and is **not** corrected |
| `4497542`, `1f110b1`, `5d75d21`, `38406d0`, `e47e779` | **`rc=1`, `FAILED (failures=1)`** — the same court, at each candidate's exact tree |

**THE CAUSE WAS A COURT ASSERTING A NAME, NOT THE LAW.** `test_t26_post_aead_charge.py` required the literal token `peerId` among the
arguments of `AdmissionBudget.chargeAuthenticated(...)`. Round 193's repair (`cf1bd15`) bound the identity first —
`val chargedIdentity = sessions?.authenticatedNodeIdOf(peerId) ?: peerId` — **which satisfieth the card more strongly, by naming the
authenticated lookup itself**, and the court reddened **on the rename**. The production law was never broken; the court was blind to it.
*A court that testeth a spelling reddeneth when the code improveth and stayeth green when the spelling is kept and the law is broken.*

**WHY I DID NOT SEE IT — the tenth species, and it is a reporting habit: `| tail -2` on a suite's output.** The suite printeth its custom
runner's `Ran 10 checks in selftest` / `OK` **after** the unittest summary, so its last two lines are always green while `rc` is 1 and a
`FAIL:` line sitteth above — measured identically at all five trees. *I piped the verdict through `tail`, which kept the tail and threw away
the head, and the head was the judgment.* Same disease as the ninth species (a denominator quietly shrunk): the report covered less than it
claimed to examine, and the omission was invisible because what remained looked clean. **The habit is now: read the verdict lines and the
failure lines, never a `tail` — and trust the check's `rc`, not its prose.**

**THE REPAIR.** The court now judgeth the **binding**, in three clauses: (1) the charged identity, or the binding it carrieth its name from,
must come from an **authenticated-identity lookup**; (2) no claimed MAC, hint or SOS priority may choose the key, and the only admissible
fallback is the **connection's own `peerId`**; (3) the charge must still be the **authenticated scope**, named as such. **Proven to judge:**
the positive case is green and **four negative cases each land on their own clause** (keyed directly on the claimed handle; bound from a
claimed hint; fallback to a non-connection source; fallback to a claimed SOS handle), with the production file restored **byte-identical**.

**THE PYTHON LANE NOW:** **573 tests, 0 failures, rc 0**; probes **12 tests, rc 0**. **A candidate tree with a red mandatory lane is not a
candidate**, so the round-275 entry (`e47e779`) cannot stand as the convergence candidate and neither can rounds 200/222/254/256: a **new
candidate measured at the repair's own SHA** is required, and round 278 produceth one.

## LIGHT Archive — the shared scope (the audit's 'Both')

**14 findings** — FIX_SUBMITTED 13, PARTIAL 1

* ACCEPTANCE BOUNDARY: final approved lexical content, trust/signing, applicable Archive device/accessibility/security evidence, green canonical controls, and actual release artifacts PROVING Mesh/LabMesh/Oracle/inference-native/model ABSENCE in the shipping graph.
* Still unfinished (1): GS-ARCHIVE-005
* Awaiting EXTERNAL or device/hosted input (14): GS-ARCHIVE-001, GS-ARCHIVE-002, GS-ARCHIVE-003, GS-ARCHIVE-004, GS-ARCHIVE-005, GS-CONTENT-001, GS-CONTENT-002, GS-CONTENT-003, GS-CTRL-001, GS-CTRL-002, GS-GATE-001, GS-PACKAGE-001, GS-PACKAGE-002, GS-SUPPLY-001
* Carrying COMPUTED-stale closure evidence (5) — a production owner changed since the audited SHA:
  GS-ARCHIVE-001, GS-ARCHIVE-002, GS-ARCHIVE-003, GS-ARCHIVE-004, GS-ARCHIVE-005
* LIGHT needeth none of the excluded runtime work once its own gates pass and EXCLUSION IS PROVED — but it may not skip a mandatory repository lane, and any new shared dependency makes an expanded-scope defect relevant to it.

## Mesh/Oracle — the additional scope

**40 findings** — FIX_SUBMITTED 14, OPEN 23, PARTIAL 3

* ACCEPTANCE BOUNDARY: the expanded store/crypto/transport/runtime/lab/model work, plus revalidation of affected shared repairs, and applicable independent protocol/native/device/interoperability/resource/signing evidence.
* Still unfinished (26): ANDROID-01, ANDROID-03, ANDROID-04, ANDROID-05, ANDROID-06, ANDROID-07, CRYPTO-001, CRYPTO-002, CRYPTO-005, GS-INBOX-001, GS-INTEGRATION-001, GS-LAB-001, GS-RUNTIME-001, GS-SOS-001, GS-STORE-002, GS-STORE-004, GS-STORE-005, GS-STORE-006, GS-STRESS-001, GS-UX-001, IOS-01, IOS-02, IOS-04, IOS-05, IOS-06, IOS-07
* Awaiting EXTERNAL or device/hosted input (17): ANDROID-02, ANDROID-04, ANDROID-05, CRYPTO-003, CRYPTO-004, CRYPTO-006, GS-ACK-001, GS-ACK-002, GS-DIAG-001, GS-MODEL-001, GS-SOS-002, GS-STORE-001, GS-STORE-002, GS-STORE-003, GS-SYNC-001, GS-SYNC-002, IOS-03
* Carrying COMPUTED-stale closure evidence (26) — a production owner changed since the audited SHA:
  ANDROID-01, ANDROID-02, ANDROID-03, ANDROID-04, ANDROID-06, ANDROID-07, GS-DIAG-001, GS-MODEL-001, GS-RUNTIME-001, GS-SOS-001, GS-SOS-002, GS-STORE-001, GS-STORE-002, GS-STORE-003, GS-STORE-004, GS-STORE-005, GS-STORE-006, GS-SYNC-001, GS-SYNC-002, IOS-01, IOS-02, IOS-03, IOS-04, IOS-05, IOS-06, IOS-07
* These 40 concern NONSHIPPING code and future acceptance; they are not claims of deployed physical-radio failures, and LIGHT does not wait on them.

## What NEITHER candidate can obtain from this work

* **No hosted lane existeth here** — no run URL, run id or hosted log for any lane — so **T78 final convergence has NOT run for either candidate**, and a local bundle cannot supersede that.
* **No device, emulator, simulator, radio, native-inference or signing operation was performed by this work.** Every result here is a LOCAL host reproduction, and no fixture or simulated counter was relabelled as a device or runtime result.
* **No human content approval is claimed**: every digest and coverage count the fixtures install is SYNTHETIC and closeth APPROVED_CONTENT for nothing.
* **Closure evidence is stale by construction wherever an owner changed** — COMPUTED, not asserted (see the ledger's `closure_evidence_staleness_COMPUTED_AT_ROUND_120`), and that block also recordeth why a computed verdict is a FLOOR and not a clearance.
* **Only an independent audit may write VERIFIED_FIXED**, and the ledger recordeth ZERO.

## Candidate verification at `03fd92b` (ledger round 178) — measured, per declared scope

| Item | Result at this exact SHA (tree `d4abed5`) |
|---|---|
| Android `:mesh` lane | **1175 tests, 0 failures, 0 errors** (forced re-run: `cleanTest`) |
| iOS lane (mirrored package) | **1198 tests, 0 failures (0 unexpected)**, 155.3s |
| Python readiness suite | **OK** |
| Repository controls | **every `ci/check_*.py` rc 0**; the only non-zero is `check_parity` under its **default** scope = the **external A-06 arm**, and `--scope repo` is rc 0 |
| Control instruments | `local_identity` **38/38**, `trusted_runtime_composition` **55/55**, `ble_link_substrate` **158/158** — all three of the audit's red controls green **and** their batteries run |
| Symbols (GS-CTRL-002's own item) | `ci/symbols.py` rc 0 — 219 Kotlin files, **0 unresolved** |

**Declared scopes, reported separately:** LIGHT Archive **14** findings; Mesh/Oracle **40** findings.

**Not claimed, and why:** **T78 convergence is NOT claimed** — its requirement is that all applicable **hosted** lanes be
enabled, executed and green at this SHA, and **no hosted lane, run URL, run id or log exists here**; the repository-side
half is complete and the missing half is stated rather than papered over. **No finding is `VERIFIED_FIXED`** (only an
independent audit may write that): live counts are **27 FIX_SUBMITTED, 5 PARTIAL, 22 OPEN**. Readiness flags stay
**false** and the five external gates stay **OPEN**. **Closure evidence is stale for 31 findings** whose card files
changed after the audited SHA — a *floor* on any later closure, not a clearance.

## Candidate verification at `4497542` (ledger round 200) — measured, per declared scope

| Item | Result at this exact SHA (tree `8e437d7`) |
|---|---|
| Android `:mesh` lane | **1187 tests, 0 failures, 0 errors** (forced re-run: `cleanTest`) |
| iOS lane (mirrored package) | **1203 tests, 0 failures (0 unexpected)**, 211.1s |
| `Python readiness suite | **OK** |` | **CLAIM WITHDRAWN at round 278 — THIS LANE WAS RED AT THIS TREE.** Re-measured at the candidate's exact tree (throwaway worktree at this SHA): `rc=1`, the python readiness suite FAILED with 1 failure — `test_t26_post_aead_charge::test_the_charge_is_keyed_on_the_authenticated_identity_not_a_claimed_handle`. The original claim (was: | Python readiness suite | **OK** |) is withdrawn, not deleted. The failure was a COURT asserting a NAME while the production law held: see the round-278 correction section below. |
| Repository controls | **every `ci/check_*.py` rc 0**; only `check_parity` under its **default** scope is non-zero = the **external A-06 arm**; `--scope repo` rc 0 |
| Ledger court | **OK** |
| Symbols | `ci/symbols.py` — 0 unresolved |

**Declared scopes, separately:** LIGHT Archive **14**; Mesh/Oracle **40**.

**Since round 178:** GS-CTRL-002's three red controls were **resolved** (ble_link_substrate 33 arms → 0, battery 158/158);
ANDROID-07's **four card steps** landed (186–193, including the retained full NodeID); ANDROID-05's T18, measured drain and
bounded in-flight drain landed (181–184); IOS-05's steps 2, 3 and 5 landed (194–199) with the iOS admission budget and the
behavioural full-NodeID witness; GS-ARCHIVE-005's App-layer blocker was classified as the **NATIVE_MODELS** external
artifact (180).

**Not claimed, and why:** **T78 convergence is NOT claimed** (no hosted lane/run URL/id/log exists here); **no finding is
`VERIFIED_FIXED`** (28 FIX_SUBMITTED / 20 OPEN / 6 PARTIAL); readiness flags **false** and the five external gates
**OPEN**; **closure evidence stale for 31 findings**. **IOS-05 is NOT complete:** steps 2, 3 and 5 are carried, but
**step 1** (the existing `PeerGovernor` itself under the runtime owner with one shared configuration) and **step 4's
separated-penalty witness** remain — this session built a purpose-built `AdmissionBudget` for the ingress rather than
wiring the governor, and that divergence is stated rather than hidden.

## Candidate verification at `1f110b1` (ledger round 222) — measured, per declared scope

| Item | Result at this exact SHA (tree `74b2dd8`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`) after a first attempt finished in 2 s |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 181.1s |
| `... / ledger court | **OK / OK** |` | **CLAIM WITHDRAWN at round 278 — THIS LANE WAS RED AT THIS TREE.** Re-measured at the candidate's exact tree (throwaway worktree at this SHA): `rc=1`, the python readiness suite FAILED with 1 failure — `test_t26_post_aead_charge::test_the_charge_is_keyed_on_the_authenticated_identity_not_a_claimed_handle`. The original claim (was: | Python readiness suite / ledger court | **OK / OK** |) is withdrawn, not deleted. The failure was a COURT asserting a NAME while the production law held: see the round-278 correction section below. |
| Repository controls | every `ci/check_*.py` **rc 0**; only `check_parity` under its **default** scope non-zero = the external **A-06** arm; `--scope repo` rc 0 |
| Symbols | `ci/symbols.py` — 0 unresolved |

**A cached green is not evidence:** the first Android attempt returned in **2 s** (task up-to-date), so the lane was re-run
**forced** and the count re-read from the run's XML. The number happened to be identical — but it was not *evidence* until
it was fresh.

**Since round 200:** ANDROID-04's scheduler **proven by a controlled experiment** (210 — a silent peer tripped by time
alone); IOS-05's steps 1–4 landed with a behavioural full-NodeID witness and a durable-trust separation witnessed against
a **real** repository (202–203); IOS-07's owned deadline sweep landed with its own controlled-experiment witness (213);
ANDROID-06's reservations repaired (a slot **taken**, a generation and capacity epoch **captured**, cancellation at the
**writer and the caller**, the bound counting **reserved** records) with its caller-side law then **witnessed
behaviourally** through a named seam (216–221); and the **connection's lease clock made monotonic** at both creation
sites (208).

**Not claimed, and why:** **T78 is NOT claimed** (no hosted lane/run URL/id/log exists here); **no finding is
`VERIFIED_FIXED`** (32 FIX_SUBMITTED / 18 OPEN / 4 PARTIAL); readiness flags **false** and the five external gates
**OPEN**; **closure evidence stale for 31 findings**.

## Candidate verification at `5d75d21` (ledger round 254) — measured, with one REGRESSION recorded

| Item | Result at this exact SHA (tree `1dde121`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`, 45s) |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 182.0s |
| `... / ledger court | **OK / OK** |` | **CLAIM WITHDRAWN at round 278 — THIS LANE WAS RED AT THIS TREE.** Re-measured at the candidate's exact tree (throwaway worktree at this SHA): `rc=1`, the python readiness suite FAILED with 1 failure — `test_t26_post_aead_charge::test_the_charge_is_keyed_on_the_authenticated_identity_not_a_claimed_handle`. The original claim (was: | Python readiness suite / ledger court | **OK / OK** |) is withdrawn, not deleted. The failure was a COURT asserting a NAME while the production law held: see the round-278 correction section below. |
| Repository controls | every `ci/check_*.py` **rc 0 EXCEPT `check_parity`, which is rc 1 IN BOTH SCOPES** |
| Symbols | `ci/symbols.py` — **1 unresolved** (221 Kotlin files) |

**A REGRESSION, FOUND AND RECORDED RATHER THAN EXPLAINED AWAY:** `check_parity --scope repo` **was rc 0 at round 222 and is rc 1
now**, so a landing between rounds 223 and 253 caused it. **Invariant F names `BleTransport.kt: conn.relationKeyProvider()`** — the
round-226 edit of ANDROID-03 slice (b) — and `ci/symbols.py` agrees (1 unresolved). **But the compiler disagrees, and the tool
itself says the compiler is the authority:** `BleConnection` carries `internal var relationKeyProvider: () -> RelationKey`
(`BleConnection.kt:120`), and the **whole Android `:mesh` lane (1192 tests, forced) compiles the call cleanly**. The tool's own
report notes *"175 type(s) whose inheritance leaves the project, 8 whose declaration was not read in full — a visible limitation,
and the compiler is the authority."*

**Two resolutions, named:** (a) **avoid the construct** — carry the relation from a source the tool resolves (e.g. the same
`relationGeneration` the writer already uses) so the mandatory control returns to rc 0; or (b) **declare the limitation in
writing** if (a) proves impossible. **The first is preferred, because a mandatory lane must be green, not explained.**

**Not claimed:** T78 (no hosted lane); no finding `VERIFIED_FIXED` (34/16/4); readiness flags **false**; five gates **OPEN**;
**and one mandatory control is non-zero at this SHA, which the next round must either fix or declare.**

## Candidate verification at `38406d0` (ledger round 256) — FULLY GREEN, with the round-254 regression CLOSED — **NOT FULLY GREEN: THE PYTHON LANE WAS RED AT THIS TREE (CORRECTED AT ROUND 278)**

| Item | Result at this exact SHA (tree `96fe578`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`, 47s) |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 135.1s |
| `Python readiness + ledger courts | **OK** |` | **CLAIM WITHDRAWN at round 278 — THIS LANE WAS RED AT THIS TREE.** Re-measured at the candidate's exact tree (throwaway worktree at this SHA): `rc=1`, the python readiness suite FAILED with 1 failure — `test_t26_post_aead_charge::test_the_charge_is_keyed_on_the_authenticated_identity_not_a_claimed_handle`. The original claim (was: | Python readiness + ledger courts | **OK** |) is withdrawn, not deleted. The failure was a COURT asserting a NAME while the production law held: see the round-278 correction section below. |
| Repository controls | **every `ci/check_*.py` rc 0, AND `check_parity --scope repo` rc 0 AGAIN**; the only non-zero is `check_parity` under its **default** scope = the **external A-06** arm |
| Symbols | `ci/symbols.py` — **0 unresolved** (221 Kotlin files) |

**The regression is closed:** the round-254 candidate carried the red (`check_parity --scope repo` rc 1, Invariant F,
`conn.relationKeyProvider`); **this candidate carries the green**, with the construct **avoided** rather than the tool's
limitation declared.

**Not claimed:** T78 (no hosted lane/run URL/id/log); no finding `VERIFIED_FIXED` (34/16/4); readiness flags **false**; five
gates **OPEN**; closure evidence **stale for 31 findings**; and the programme's own debt is named — **31 self-inflicted
corrections recorded across this session's rounds**, each kept beside the repair it accompanied, *because a record that
carries only successes teaches nothing*.

## Candidate verification at `e47e779` (ledger round 275) — FULLY GREEN, INCLUDING BOTH LAB APPLICATION TARGETS — **NOT FULLY GREEN: THE PYTHON LANE WAS RED AT THIS TREE (CORRECTED AT ROUND 278)**

| Item | Result at this exact SHA (tree `a3824ea`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`, 45s) |
| **Android lab application target** | **0 compile errors (forced)**, `labmesh-debug.apk` **15,133,266 bytes** |
| **iOS lab application target** | **`BUILD SUCCEEDED`** (simulator SDK, unsigned, `CODE_SIGNING_ALLOWED=NO`) |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 211.8s |
| `Python readiness + ledger courts | **OK** |` | **CLAIM WITHDRAWN at round 278 — THIS LANE WAS RED AT THIS TREE.** Re-measured at the candidate's exact tree (throwaway worktree at this SHA): `rc=1`, the python readiness suite FAILED with 1 failure — `test_t26_post_aead_charge::test_the_charge_is_keyed_on_the_authenticated_identity_not_a_claimed_handle`. The original claim (was: | Python readiness + ledger courts | **OK** |) is withdrawn, not deleted. The failure was a COURT asserting a NAME while the production law held: see the round-278 correction section below. |
| Repository controls | every `ci/check_*.py` **rc 0 EXCEPT `check_parity` under its default scope (rc 1 = the EXTERNAL A-06 arm, designed fail-closed)**; `--scope repo` rc 0 |
| Symbols | `ci/symbols.py` — **0 unresolved** (223 Kotlin files, two more than round 256: GS-LAB-001's own lab sources) |

**Since round 256:** GS-LAB-001 carried **four of six steps on real artifacts** — the Android APK whose **merged manifest** carries the
launcher activity, the retained runtime owner, **INTERNET removed** and `BLUETOOTH_SCAN` present; and the iOS `GodstoneLabMesh.app`
with its **own** bundle identity `io.godstone.labmesh` — plus **five lab invariants each proven to judge by a negative case**;
GS-UX-001's step 5 landed the SOS as a **real cancellable hold on a monotonic threshold** with an accessible alternative; the
round-254 mandatory-control regression was **closed**; and ANDROID-01's reconciliation was measured to **three of six arms
reconciled**, with three failures **each described by kind**.

**Not claimed:** **T78** (no hosted lane, run URL, run id or log exists here); **no finding is `VERIFIED_FIXED`** (35 FIX_SUBMITTED /
15 OPEN / 4 PARTIAL); readiness flags **false**; five gates **OPEN**; closure evidence **stale for 31 findings**; and the
hardware-dependent work is explicitly outstanding — **GS-LAB-001's step 6 awaits T73–T75 and IOS-01's behavioural half awaits a real
CoreBluetooth manager. No simulator or fixture result is offered as a device result anywhere in this record.**


**A CORRECTION IN THIS VERY ENTRY, LEFT VISIBLE (round 265's pattern, committed again and caught again):** the first version of this
verification claimed *every* control was rc 0 "including `check_parity` under its default scope" — **and the same call's own log printed
`ci/check_parity.py rc=1` beside the claim.** The honest statement is the one in the table: every **repository-owned** control is rc 0,
and the **only** non-zero is the **external A-06** arm, whose gate stays **OPEN**. *A claim written before its evidence was read is the
mistake this ledger exists to catch, and it was caught in the round that made it.*
