# Build instructions

## Android

After the complete checkout, wrapper, SDK, and approved LIGHT assets are present:

```bash
python3 scripts/prepare_release_assets.py --manifest /secure/release/assets-light.json --out android/app/src/light/assets
cd android
./gradlew --no-daemon --warning-mode=all clean test lint assembleLightRelease bundleLightRelease
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
