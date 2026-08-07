#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path

SOURCE_ROOTS = [Path("android/app/src"), Path("ios/Godstone/Sources/App")]
FORBIDDEN = (
    "io.godstone.mesh.wire.Frame", "GMP/1 frame", "PROTOCOL_VERSION: Byte = 0x01",
    "import GodstoneMesh", "MeshNode", "MeshCoordinator",
)
EXTENSIONS = {".kt", ".java", ".swift", ".mm", ".m", ".h", ".hpp"}


def violations(root: Path) -> list[str]:
    output: list[str] = []
    for relative in SOURCE_ROOTS:
        base = root / relative
        if not base.exists(): continue
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in EXTENSIONS:
                text = path.read_text(encoding="utf-8", errors="replace")
                for needle in FORBIDDEN:
                    if needle in text:
                        output.append(f"{path.relative_to(root)}: {needle}")
    gradle = root / "android/app/build.gradle.kts"
    if gradle.is_file() and 'project(":mesh")' in gradle.read_text(encoding="utf-8"):
        output.append("android/app/build.gradle.kts: production app depends on :mesh")
    project = root / "ios/project.yml"
    if project.is_file() and "product: GodstoneMesh" in project.read_text(encoding="utf-8"):
        output.append("ios/project.yml: production app depends on GodstoneMesh")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            test_root = Path(tmp)
            path = test_root / "android/app/src/main/Test.kt"
            path.parent.mkdir(parents=True)
            path.write_text("import io.godstone.mesh.wire.Frame\n", encoding="utf-8")
            if not violations(test_root):
                print("negative control failed")
                return 1
        print("negative control detected a reintroduced shipping legacy import")
        return 0
    found = violations(args.root.resolve())
    if found:
        print("Legacy or disabled Mesh path is reachable from a shipping app:\n" + "\n".join(found))
        return 1
    print("shipping applications have no Mesh/GMP/1 dependency edge")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
