# Operations runbook

1. Freeze the exact source and artifact hashes.
2. Rehearse install, first launch in airplane mode, Archive search, missing/corrupt asset behavior, restart, reboot, upgrade, low storage, and removal.
3. Promote the exact tested artifact; never rebuild after approval.
4. On content defect, revoke the release manifest/key as designed, stop distribution, publish correction scope, and build from corrected reviewed inputs.
5. On security incident, preserve nonsecret evidence, rotate affected release trust anchors through an approved process, and avoid logging keys, plaintext, prompts, or full frames.
6. Roll back only to an artifact whose content review and platform compatibility remain valid.
