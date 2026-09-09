# Production baseline record — T01 preservation

Authority: GODSTONE_BLUEPRINT_HANDOFF task card T01; plan `docs/production-readiness/MASTER_IMPLEMENTATION_BLUEPRINT.md` sections 1–9, 24–28.
All facts below are read from the live repository at execution time; the planning snapshot is quoted for reference only.

## 1. Baseline identity

- Branch: `codex/archive-reliability` (original checkout, left untouched)
- Planning HEAD: `b5c3d3d394b70cf356cdde33b47511dad7cbb95c`
- Parent: `921b93903dea32b30ee591c3c0b454f706333c69`
- Audited anchor `921b93903dea32b30ee591c3c0b454f706333c69` is an ancestor of HEAD (verified by `git merge-base --is-ancestor`, exit 0).
- Continuation worktree: `/Users/oculus/Projects/GODSTONE_BUILDER` on `codex/production-blueprint` created from exactly the planning HEAD.

```
commit b5c3d3d394b70cf356cdde33b47511dad7cbb95c
Author:     oculusrex14 <oculusrex14@users.noreply.github.com>
AuthorDate: Thu Sep 3 00:20:21 2026 +0530
Commit:     oculusrex14 <oculusrex14@users.noreply.github.com>
CommitDate: Thu Sep 3 00:20:21 2026 +0530

    stage4: bind CoreBluetooth manager callbacks to epochs
```

### Remote references
```
16e5a2bb66c1ab8281899790bb77355026ec0619 commit	refs/remotes/origin/HEAD
16e5a2bb66c1ab8281899790bb77355026ec0619 commit	refs/remotes/origin/main
b7daf5aceb642277807e9bfbe3bbb486112a64ec commit	refs/remotes/origin/production-readiness/2026-08-06
b7bac64341c1214e05d0436fcb29c5b671d710e9 commit	refs/remotes/origin/remediation/stage-2-gmp21
ce265e2e2b9a8e01d9851bde9baefbae0c72c993 commit	refs/remotes/origin/remediation/stage-3-durability
b5c3d3d394b70cf356cdde33b47511dad7cbb95c commit	refs/remotes/origin/remediation/stage-4-link-release
```

## 2. Working-tree status at preservation time

- Porcelain v1 entries: **156** (18 modified + 138 untracked)
- **Drift disclosure:** the planning snapshot reported 33 porcelain entries; the live tree counts 156 (the import package `GODSTONE_BLUEPRINT_HANDOFF/` arrived after the snapshot). The inventory governs; the snapshot is not corrected.

### 2a. Tracked modifications (preserved as verified)

| bytes | sha256 | path |
|-------|--------|------|
| 20669 | `b0a1488a8fbd` | `.github/workflows/repository-verification.yml` |
| 7983 | `f8b4cc94228f` | `android/app/src/main/java/io/godstone/app/ui/browse/BrowseScreen.kt` |
| 4768 | `1be6b5aef431` | `android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt` |
| 2141 | `3642f4247af7` | `android/core/build.gradle.kts` |
| 5340 | `6780dd04edf7` | `android/core/src/main/java/io/godstone/core/archive/ArchiveRepository.kt` |
| 7015 | `bae05f4d73f3` | `ci/check_release_gates_status.py` |
| 15380 | `3576a4ee537c` | `content/archive_manifest.py` |
| 13920 | `f80e8c1a524e` | `content/ingest/build_archive.py` |
| 5390 | `811c6598905f` | `content/tests/test_archive_manifest.py` |
| 1709 | `3cbdc76f77fc` | `ios/Godstone/Info.plist` |
| 375 | `bddb756db736` | `ios/Godstone/Sources/App/AppContainer.swift` |
| 7377 | `f3c8868d9870` | `ios/Godstone/Sources/App/ArchiveView.swift` |
| 17056 | `2ff4eef196d9` | `ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift` |
| 10192 | `273b6d763b4d` | `ios/Packages/GodstoneFoundation/SOURCE_MANIFEST.json` |
| 17056 | `2ff4eef196d9` | `ios/Packages/GodstoneFoundation/Sources/GodstoneCore/ArchiveRepository.swift` |
| 3931 | `42d9c66c97f8` | `ios/project.yml` |
| 10420 | `e0c913b08150` | `scripts/inspect_android_artifacts.py` |
| 8934 | `fa1fe05ecd12` | `scripts/prepare_release_assets.py` |

Canonical-vs-generated sync check: `ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift` and `ios/Packages/GodstoneFoundation/Sources/GodstoneCore/ArchiveRepository.swift` carry the same sha256 (`2ff4eef196d9`) — in sync.

### 2b. Untracked files (all preserved and compared)

| bytes | sha256 | path |
|-------|--------|------|
| 1170 | `9dc3ee4c1eb5` | `GODSTONE_BLUEPRINT_HANDOFF/ARCHITECTURE_INVARIANTS.template.json` |
| 55258 | `bd3604766c00` | `GODSTONE_BLUEPRINT_HANDOFF/BASELINE_EVIDENCE.json` |
| 1258 | `f0d8fa0af899` | `GODSTONE_BLUEPRINT_HANDOFF/BUILD_STATE.template.json` |
| 16332 | `768aee0742d1` | `GODSTONE_BLUEPRINT_HANDOFF/CHECKSUMS.json` |
| 1023719 | `685456b37866` | `GODSTONE_BLUEPRINT_HANDOFF/MASTER_IMPLEMENTATION_BLUEPRINT.md` |
| 1775 | `0ab5e90f21aa` | `GODSTONE_BLUEPRINT_HANDOFF/PLANNING_VALIDATION.json` |
| 1984 | `b71a198c2f8f` | `GODSTONE_BLUEPRINT_HANDOFF/README.md` |
| 1047398 | `b7cf90483cde` | `GODSTONE_BLUEPRINT_HANDOFF/TASKS.json` |
| 2323 | `48b1bfadd27e` | `GODSTONE_BLUEPRINT_HANDOFF/sections/01.md` |
| 3365 | `84548eec175f` | `GODSTONE_BLUEPRINT_HANDOFF/sections/02.md` |
| 2423 | `b93a68e3ebaf` | `GODSTONE_BLUEPRINT_HANDOFF/sections/03.md` |
| 6465 | `503d864fe235` | `GODSTONE_BLUEPRINT_HANDOFF/sections/04.md` |
| 3248 | `f50ab9b7d4f6` | `GODSTONE_BLUEPRINT_HANDOFF/sections/05.md` |
| 2854 | `686e6729ac04` | `GODSTONE_BLUEPRINT_HANDOFF/sections/06.md` |
| 3080 | `636a64872a86` | `GODSTONE_BLUEPRINT_HANDOFF/sections/07.md` |
| 12515 | `09e426a5b63a` | `GODSTONE_BLUEPRINT_HANDOFF/sections/08.md` |
| 4630 | `6b92deade447` | `GODSTONE_BLUEPRINT_HANDOFF/sections/09.md` |
| 2343 | `e1e3e5785125` | `GODSTONE_BLUEPRINT_HANDOFF/sections/11.md` |
| 2196 | `087060d2463f` | `GODSTONE_BLUEPRINT_HANDOFF/sections/12.md` |
| 6815 | `90dbf45e19d5` | `GODSTONE_BLUEPRINT_HANDOFF/sections/13.md` |
| 12067 | `c9b372362a0f` | `GODSTONE_BLUEPRINT_HANDOFF/sections/14.md` |
| 4106 | `ca565117f68f` | `GODSTONE_BLUEPRINT_HANDOFF/sections/15.md` |
| 3056 | `f3f78cced943` | `GODSTONE_BLUEPRINT_HANDOFF/sections/16.md` |
| 2706 | `e7d2223601d7` | `GODSTONE_BLUEPRINT_HANDOFF/sections/17.md` |
| 5136 | `3b73073dfb13` | `GODSTONE_BLUEPRINT_HANDOFF/sections/18.md` |
| 4421 | `bde0cc5e3023` | `GODSTONE_BLUEPRINT_HANDOFF/sections/19.md` |
| 2644 | `486c6925180c` | `GODSTONE_BLUEPRINT_HANDOFF/sections/20.md` |
| 2596 | `6d7e49f135e6` | `GODSTONE_BLUEPRINT_HANDOFF/sections/21.md` |
| 1888 | `e09a34e3f90c` | `GODSTONE_BLUEPRINT_HANDOFF/sections/22.md` |
| 3178 | `a2ce052f8352` | `GODSTONE_BLUEPRINT_HANDOFF/sections/23.md` |
| 5613 | `d8e5a6f44e6f` | `GODSTONE_BLUEPRINT_HANDOFF/sections/24.md` |
| 5382 | `9212adb60849` | `GODSTONE_BLUEPRINT_HANDOFF/sections/25.md` |
| 2719 | `f632d38f53a5` | `GODSTONE_BLUEPRINT_HANDOFF/sections/26.md` |
| 2612 | `cf099d316344` | `GODSTONE_BLUEPRINT_HANDOFF/sections/27.md` |
| 7735 | `ec2b238a608c` | `GODSTONE_BLUEPRINT_HANDOFF/sections/28.md` |
| 2107 | `77ad8f0fab9f` | `GODSTONE_BLUEPRINT_HANDOFF/sections/29.md` |
| 3100 | `08d7a082ec2e` | `GODSTONE_BLUEPRINT_HANDOFF/sections/30.md` |
| 44548 | `eb251d2cd8d7` | `GODSTONE_BLUEPRINT_HANDOFF/sections/31.md` |
| 8641 | `7aa613754a60` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T01.md` |
| 8805 | `d33176f07209` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T02.md` |
| 9537 | `bd5d189b91d4` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T03.md` |
| 9389 | `30d3d6f24c36` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T04.md` |
| 10447 | `261714b8ec22` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T05.md` |
| 10682 | `a1c6072cdece` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T06.md` |
| 9850 | `ee5353fd9845` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T07.md` |
| 10693 | `b37288b04adc` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T08.md` |
| 9821 | `90da8aa9a498` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T09.md` |
| 11555 | `11189033eba0` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T10.md` |
| 9916 | `4dd64debac18` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T11.md` |
| 10030 | `3a0b1302ee95` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T12.md` |
| 9612 | `75952d7b354b` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T13.md` |
| 9465 | `4585908741d4` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T14.md` |
| 9286 | `1a596154b7c1` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T15.md` |
| 9721 | `96f162c434e0` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T16.md` |
| 10785 | `c657057cda5c` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T17.md` |
| 10009 | `64c64eeb9e72` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T18.md` |
| 9621 | `f595f7d49f43` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T19.md` |
| 11929 | `19ac70eb8751` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T20.md` |
| 11534 | `425f861a71b9` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T21.md` |
| 10725 | `2be95582e307` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T22.md` |
| 10977 | `df4ed2b05e9a` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T23.md` |
| 11640 | `223e46cc67b7` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T24.md` |
| 11452 | `e16594eed8cd` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T25.md` |
| 10609 | `3be987322cbd` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T26.md` |
| 9678 | `d0021dc56ac0` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T27.md` |
| 11818 | `cc1c2ca8a9a6` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T28.md` |
| 10741 | `612fe0b1efa3` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T29.md` |
| 10775 | `51fbcd8ea7e2` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T30.md` |
| 10209 | `aa4cc6b3d825` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T31.md` |
| 10761 | `5d1c83f6d449` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T32.md` |
| 10079 | `663c22f9ad48` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T33.md` |
| 12562 | `805e4ac8d326` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T34.md` |
| 12573 | `5bb307d39cb1` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T35.md` |
| 11434 | `055f5b214223` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T36.md` |
| 12752 | `1b4e66e9f61b` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T37.md` |
| 12161 | `067dd372d2c2` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T38.md` |
| 11156 | `a9c9ac009fb1` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T39.md` |
| 12431 | `10ca566bd997` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T40.md` |
| 10918 | `21a570e3b8a8` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T41.md` |
| 10954 | `cdff18b7c506` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T42.md` |
| 11223 | `a69adab38b1a` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T43.md` |
| 12206 | `5de8443df9e4` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T44.md` |
| 9839 | `c1949286212c` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T45.md` |
| 10135 | `8906afd2e812` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T46.md` |
| 10912 | `e5bb61104d58` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T47.md` |
| 10332 | `7b3284465061` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T48.md` |
| 9987 | `d121c3119bf2` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T49.md` |
| 9450 | `627d66521956` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T50.md` |
| 10146 | `dcb99ba5aedb` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T51.md` |
| 9932 | `69a53a0bfcbe` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T52.md` |
| 9437 | `fb3f004ff12a` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T53.md` |
| 10395 | `b8e10dbe8b75` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T54.md` |
| 10206 | `badf6dd7644e` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T55.md` |
| 9656 | `d7367b5fd203` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T56.md` |
| 9834 | `5e0a931ad202` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T57.md` |
| 9542 | `470b22bda33b` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T58.md` |
| 10713 | `16761ab9d929` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T59.md` |
| 9574 | `fd516fb2c39e` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T60.md` |
| 11122 | `43e0c3e2383c` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T61.md` |
| 10283 | `60ad47527b3d` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T62.md` |
| 10556 | `e292cebce6e7` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T63.md` |
| 11091 | `d693b94e4f23` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T64.md` |
| 11182 | `994e45b01f45` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T65.md` |
| 9878 | `5f266706e5d3` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T66.md` |
| 8638 | `c997b79ee9d9` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T67.md` |
| 10533 | `3f732059dcd2` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T68.md` |
| 10104 | `4a18292a6c49` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T69.md` |
| 9995 | `9dd3dc6d24f3` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T70.md` |
| 9591 | `d54371a485c3` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T71.md` |
| 9724 | `f48d5f1ae19c` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T72.md` |
| 9564 | `5b4b49306fe9` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T73.md` |
| 9596 | `ace225433f05` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T74.md` |
| 9762 | `427c730d31a9` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T75.md` |
| 9696 | `826e707fde1f` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T76.md` |
| 9479 | `935a0c919ffc` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T77.md` |
| 9740 | `bb0436890fc7` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T78.md` |
| 8606 | `9bd122e152a5` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T79.md` |
| 9131 | `0343577c7e3e` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T80.md` |
| 10064 | `5772fdc73ecd` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T81.md` |
| 10712 | `3e7ae31e4228` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T82.md` |
| 11019 | `edaf50dcb5b6` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T83.md` |
| 11570 | `f4306de272d4` | `GODSTONE_BLUEPRINT_HANDOFF/tasks/T84.md` |
| 7861 | `f1830624443a` | `android/app/src/test/java/io/godstone/app/ui/browse/BrowseViewModelTest.kt` |
| 3751 | `9d58ef2ac894` | `android/core/src/main/java/io/godstone/core/archive/ArchiveDatabase.kt` |
| 3686 | `a04243838dcc` | `android/core/src/main/java/io/godstone/core/archive/ArchiveInstaller.kt` |
| 5668 | `cccbcc93e7b0` | `android/core/src/test/java/io/godstone/core/archive/ArchiveInstallerTest.kt` |
| 7485 | `2bdd9f313556` | `android/core/src/test/java/io/godstone/core/archive/ArchiveRepositoryTest.kt` |
| 3914 | `012b120f3603` | `ci/archive_fixture.py` |
| 177 | `30043a5ba98f` | `content/requirements-dev.txt` |
| 1301 | `0c984a90e778` | `content/tests/archive_fixtures.py` |
| 2958 | `c3336ac56af2` | `content/tests/test_build_archive.py` |
| 9237 | `aa9853ff8972` | `content/tests/test_prepare_release_assets.py` |
| 2745 | `545e82f190fe` | `ios/Godstone/Sources/GodstoneCore/ArchiveReaderModel.swift` |
| 2773 | `17d47eab73fa` | `ios/Godstone/Tests/GodstoneCoreTests/ArchiveReaderModelTests.swift` |
| 7744 | `5bf4a22e2931` | `ios/Godstone/Tests/GodstoneCoreTests/ArchiveRepositoryTests.swift` |
| 2745 | `545e82f190fe` | `ios/Packages/GodstoneFoundation/Sources/GodstoneCore/ArchiveReaderModel.swift` |
| 2773 | `17d47eab73fa` | `ios/Packages/GodstoneFoundation/Tests/GodstoneCoreTests/ArchiveReaderModelTests.swift` |
| 7744 | `5bf4a22e2931` | `ios/Packages/GodstoneFoundation/Tests/GodstoneCoreTests/ArchiveRepositoryTests.swift` |

### 2c. Ignored paths classified as relevant fixtures

| bytes | sha256 | classification | path |
|-------|--------|----------------|------|
| 10763 | `2ceea9e9b43a` | debug_or_past_run_fixture | `artifacts/android-archive-bundled-tests.log` |
| 11666 | `34bbf431197d` | debug_or_past_run_fixture | `artifacts/android-archive-final-build.log` |
| 10350 | `643ec6bfb249` | debug_or_past_run_fixture | `artifacts/android-archive-tests.log` |
| 909 | `4cd8126bcf75` | debug_or_past_run_fixture | `artifacts/android-core-parity.log` |
| 139264 | `28a0ba1fccbe` | debug_or_past_run_fixture | `dist/archive_medium.db` |
| 652 | `20bfe1411dae` | debug_or_past_run_fixture | `provenance.json` |

- Build noise ignored (counted, not copied): 15361 paths (venvs, build dirs, caches).
- The six fixtures above are past-run debug artifacts. They are **not** approved content, models, or independent inputs; they may never be used to close external gates.

## 3. Tracked patch integrity

- `git diff --binary HEAD` sha256: `b78e77db8ff425c2d8009abedeec7306ca1783c5a7a87d70e51982f873eed1ac`
- Preserved copy verified three ways: byte size, SHA-256, and reconstructability —
  `git apply --check` on a fresh baseline clone succeeds; applying the patch twice is correctly rejected by the suite (duplicate application guard).

## 4. Preservation manifest

- Evidence root (private, outside all worktrees): `/Users/oculus/Projects/GODSTONE_BUILDER_EVIDENCE/T01`
- `inventory.json` sha256: `e7f2e905fa7d1be256d54e26854ff91aab89490209af0058dbce375cdb57f3fb`
- Raw probes: `raw/head-fuller.txt`, `raw/head.txt`, `raw/parent.txt`, `raw/remote-tips.txt`, `raw/status-before.txt`, `raw/tracked-patch.bin`
- Logs: `logs/unittest-t01-run1.log`, `logs/unittest-t01-run2.log`, `logs/unittest-t01-run3.log`, `logs/unittest-t01-run4.log`
- `commands.json` follows the command-entry schema of blueprint section 25.

## 5. Test evidence

- Final suite: 21 tests, 0 failures, 0 errors, 0 skips (positive test counts only).
- Mutation controls: removed untracked copy → reported missing; single-byte tamper (size-preserving) → reported hash mismatch; removed/tampered promoted tracked patch → reported missing/drift. All mutations run against a mirror copy; the original evidence tree is re-verified green afterwards.

## 6. External gates (left open by policy, not closed by the builder)

- A06 independent conformance review, APPROVED_CONTENT, NATIVE_MODELS, HARDWARE, SIGNING.
- Readiness flags unchanged: android `LINK_LAYER_READY=false`; iOS `linkLayerReady=false`.

