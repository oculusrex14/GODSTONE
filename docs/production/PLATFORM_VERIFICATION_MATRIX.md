# Platform verification matrix

| Platform | Source validation | Unit tests | Static analysis | Release build | Artifact inspection | Device evidence |
|---|---|---|---|---|---|---|
| Android | Partial, modified Kotlin compiled in isolated harness | Validator harness PASS | Repository checks PASS | BLOCKED | Not generated | Unavailable |
| iOS | Core validator compiled on Linux Swift | Validator harness PASS | plist/project checks PASS | BLOCKED: no Xcode | Not generated | Unavailable |
| Content/Python | Full overlay modules executable | 10 tests PASS | compile/static checks PASS | Signed fixture manifest PASS | SQLite/tier/hash/signature faults PASS | N/A |

A simulator, Linux Swift compiler, or software BLE model does not close any physical-device requirement.
