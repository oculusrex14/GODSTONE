# L1 Discovery — Role Matrix

## Why symmetric discovery cannot work

Unifying the BLE service UUID looks like the fix for the v1 platform partition.
It is not sufficient, because of a platform constraint no protocol work removes:

> **A backgrounded iOS peripheral does not advertise its service UUID.**
> CoreBluetooth moves it into a proprietary "overflow area" — a hashed bitfield
> inside Apple manufacturer data — readable only by another iOS device that is
> explicitly scanning for that exact UUID. An Android scanner sees an anonymous
> Apple advertisement and nothing else.

In a blackout almost every node is backgrounded. So **Android→iOS discovery is
structurally impossible**, and any symmetric design fails in the field even with
a shared UUID and a shared frame format.

## The architecture

Make discovery one-directional and let the platform that *can* discover do it.

| Link | Mechanism | Works backgrounded |
|---|---|---|
| Android → Android | BLE adv + scan, both directions | Yes |
| **iOS → Android** | Android advertises; iOS scans as central with an explicit UUID filter | Yes |
| **Android → iOS** | **Never attempted.** Not needed — iOS closes this link itself | n/a |
| iOS → iOS | Overflow area, both ends Apple | Degraded but real |

* **Android advertises unconditionally**, from a foreground service. It is the
  beacon the mesh is built on.
* **iOS always plays central toward Android.** Background scanning with an
  explicit UUID filter is permitted and does fire callbacks.
* **Terminated iOS apps** are relaunched by **CoreLocation region monitoring**
  against an iBeacon frame interleaved into the Android anchor's advertising
  cycle. CoreBluetooth state restoration does not relaunch a force-quit app;
  region monitoring does. Without this the mesh dies in a pocket.

### Anchor election

Any Android node may anchor. Nodes elect anchors by lowest `node_id` among peers
seen in the last 60 s, capped at 3 anchors per neighbourhood, re-elected every
5 minutes or on anchor loss.

### Consequences that MUST be surfaced in the UI

1. iOS↔Android requires at least one Android device in range. An all-iOS group
   backgrounded is a degraded mesh.
2. Bulk transfer requires the iOS app foregrounded.
3. These are platform facts, not bugs. `BackgroundLimitBanner` states them.

## Open compliance items

* **iBeacon is an Apple-licensed format.** CoreLocation only monitors
  iBeacon-format regions; AltBeacon will not wake iOS. An Android device
  transmitting iBeacon frames needs a legal review, not an engineering one.
* **CoreLocation region monitoring requires `Always` location permission on
  iOS.** `docs/packaging/STORE.md` claims the app "never reads position and has
  no code path that could". That claim no longer holds on iOS; the store
  narrative and privacy policy must be updated before review.

## Hardware test matrix

Case 0 **gates cases 1–10**. A frame test on a link that never established is
measuring nothing.

| # | Case | Expected |
|---|---|---|
| **0** | **Android ↔ iOS Noise XX handshake, real devices** | **completes < 2 s, transport keys agree** |
| 1 | Android ↔ Android, both foreground | discovery < 5 s |
| 2 | Android ↔ Android, both background | discovery < 30 s |
| 3 | iOS → Android, iOS foreground | discovery < 5 s |
| 4 | iOS → Android, iOS background | discovery < 60 s |
| 5 | iOS → Android, iOS force-quit | relaunch via iBeacon region, < 5 min |
| 6 | iOS ↔ iOS, both background | discovery via overflow area |
| 7 | v2 frame round-trip across platforms | golden vectors reproduce |
| 8 | SOS end-to-end, 3 hops, mixed platforms | delivered, signature verifies |
| 9 | Bulk transfer > 512 B, iOS foreground | Wi-Fi plane up then torn down < 5 s |
| 10 | Battery: 8 h idle listening, Android | < 3 %/hour |

**None of cases 0–10 have been run.** No physical devices were available. BLE
only tells the truth on real radios.
