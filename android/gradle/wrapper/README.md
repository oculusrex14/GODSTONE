# gradle/wrapper

`gradle-wrapper.jar` is **deliberately absent** and must be restored before
`./gradlew` will run.

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

`ci/check_parity.py` Invariant G reports this as a WARNING rather than a
failure: it is a genuinely missing artefact, not a defect in the source, and
failing the whole gate on it would train people to ignore the gate.
