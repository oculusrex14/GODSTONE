# Build instructions

## Android

After the complete checkout, wrapper, SDK, and approved LIGHT assets are present:

```bash
python3 scripts/prepare_release_assets.py --manifest /secure/release/assets-light.json --out android/app/src/light/assets
cd android
# Archive-only LIGHT release. Scoped to :app so :llm's CMake native build is
# never configured -- an Archive-only binary does NOT need llama.cpp/model/Oracle
# (:app ships implementation(project(":core")) only; :llm is testImplementation).
./gradlew --no-daemon --warning-mode=all \
  :app:lintLightRelease :app:assembleLightRelease :app:bundleLightRelease
```

A fresh checkout is already a clean source tree; do NOT use root
`clean test lint` for an Archive-only build -- those root aggregate tasks
configure `:llm` (NDK/CMake + `add_subdirectory(third_party/llama.cpp)`) and
fail on the missing native stack. The native stack is a SEPARATE gate
(`release-gates.yml / llm-native-stack`, `:llm:assembleRelease`) that stays
fail-closed until llama.cpp is pinned and restored; it must not block the
Archive-only binary.

Verify the shipping classpath is Archive-only before relying on it:

```bash
cd android
./gradlew :app:dependencies --configuration lightReleaseRuntimeClasspath
./gradlew :app:dependencies --configuration lightReleaseCompileClasspath
# neither graph may contain: project :llm | project :mesh | llama | ggml | godstone_llm
python3 scripts/inspect_android_artifacts.py app/build artifacts/android   # real APK/AAB inspection
```

Do not embed signing credentials. Inspect merged manifests and packaged assets before signing.

## iOS

On macOS with approved Xcode/XcodeGen:

```bash
python3 scripts/sync_ios_foundation_package.py
swift test --package-path ios/Packages/GodstoneFoundation
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Godstone.xcodeproj -scheme Godstone-Light -configuration LightRelease -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
