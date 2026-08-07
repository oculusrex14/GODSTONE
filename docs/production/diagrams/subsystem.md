# Subsystem architecture

```mermaid
flowchart LR
  App[Archive-only App] --> Core[GodstoneCore]
  Core --> Archive[(Verified read-only Archive)]
  Oracle[Oracle source - disabled] -. validation gate required .-> Core
  Mesh[Mesh source - nonshipping] -. no app dependency .-> Core
```
