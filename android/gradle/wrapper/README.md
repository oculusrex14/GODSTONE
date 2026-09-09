# gradle/wrapper

`gradle-wrapper.jar` is present in this checkout and its SHA-256 matches
the pin in `docs/production/ANDROID_TOOLCHAIN_CONTRACT.md` (verified by
`scripts/check_android_toolchain.py` and by the T02 builder probe).
Restore it only if it ever goes missing again:

It is a ~60 KB binary. This repository is distributed as a single text document,
so no binary can survive the round trip -- writing a corrupt placeholder would be
worse, because `./gradlew` would fail with a class-loading error instead of a
clear "file not found".

Restore it either way:

```bash
# Option A -- if a system Gradle 8.9 is available (preferred, verifiable)
gradle wrapper --gradle-version 8.9 --distribution-type bin

# Option B -- fetch the jar that matches gradle-wrapper.properties
curl -L -o gradle/wrapper/gradle-wrapper.jar \
  https://raw.githubusercontent.com/gradle/gradle/v8.9.0/gradle/wrapper/gradle-wrapper.jar
```

If the jar is ever missing again, `ci/check_parity.py` Invariant G reports
it as a WARNING rather than a failure, so a genuinely missing artefact
cannot be confused with a source defect.
