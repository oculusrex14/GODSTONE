# Native dependency status

`third_party/llama.cpp/` is required by both native LLM bridges, but V4 does
**not** contain a `.gitmodules` entry, a gitlink, or a verified commit lock.
Therefore the dependency is currently **absent and unpinned**.

Do not run `git submodule update` and assume this is closed: without a committed
gitlink that command has nothing to restore. Before an app/LLM build may be
called reproducible, add one of these reviewed controls:

1. a real git submodule at `third_party/llama.cpp` pinned to an audited commit;
2. or a lockfile plus a fetch script that verifies the exact source archive
   SHA-256 and license before extraction.

Both native build definitions intentionally expect the dependency at this path:

- `android/llm/src/main/cpp/CMakeLists.txt`
- `ios/Godstone/Package.swift`

Until the pin exists, CI may compile only the host-buildable/core surfaces and
must report the complete LLM/app build as blocked rather than silently skipping
it.
