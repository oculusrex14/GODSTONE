# Testing instructions

Run repository checks and host tests first:

```bash
python3 ci/check_repository.py
python3 ci/no_legacy_wire.py
python3 ci/no_legacy_wire.py --selftest
python3 -m unittest discover -s content/tests -v
python3 scripts/sync_ios_foundation_package.py --check
```

Then run full Android/iOS suites on supported platform environments. Do not exclude a failure unless it objectively requires unavailable hardware, credentials, OS infrastructure, external service, or human approval; record the exact command and blocker.
