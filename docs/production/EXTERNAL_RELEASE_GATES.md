# External and unavailable release gates

| Class | Requirement | Why unavailable | Remaining action | Owner | Acceptance evidence | Prevents release |
|---|---|---|---|---|---|---|
| Owner-controlled | Android production signing | No keystore/Play access | Sign exact tested AAB under controlled custody | Release owner | signing fingerprint + Play artifact hash | Yes |
| Owner-controlled | Apple signing/provisioning | No account/team/profile | Archive/sign exact tested build | Release owner | signed archive/export logs | Yes |
| Owner-controlled | Production Archive signing key | No approved key/custody | Create protected Ed25519 key and trust-store rotation procedure | Security owner | key ceremony and signed manifest | Yes |
| External | Clinical/editorial review | No qualified approvals supplied | Review every source/transformation/chunk/warning | Clinical/editorial owners | immutable approval packet | Yes |
| External | Content rights | No production corpus/rightsholder evidence | Approve redistribution and derivatives | Legal/content owner | licence/evidence hashes | Yes |
| External | Legal/privacy/export | No accountable approvals | Review claims, data flows, crypto/export, terms | Legal/privacy owners | signed approval records | Yes |
| Physical | Android/iOS device matrix | No devices | Install, launch, airplane, upgrade, storage, wipe, accessibility | QA owner | device logs/videos/checksums | Yes |
| Physical | Hardware Case 0 | Mesh disabled and no devices | Complete Android↔iOS BLE/Noise/GMP evidence | Security/QA | packet capture + test matrix | Required only before Mesh |
| Physical | Battery/thermal/performance | No lab/devices | Measure budgets on supported hardware | Performance owner | raw measurements + pass report | Yes |
| External | Store review | No store accounts/artifacts | Submit truthful metadata and exact signed binaries | Product/release owner | Play/App Store acceptance | Yes |
