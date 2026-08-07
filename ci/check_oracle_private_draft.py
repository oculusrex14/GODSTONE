#!/usr/bin/env python3
from pathlib import Path

checks = {
    Path("android/app/src/main/java/io/godstone/app/ui/oracle/OracleViewModel.kt"): [
        "val draft = StringBuilder()", "rag.validate(draft.toString(), retrieval)", "answer = draft.toString().trim()",
    ],
    Path("ios/Godstone/Sources/App/OracleViewModel.swift"): [
        "case generating", "var draft = \"\"", "pipeline.validate(answer: draft",
    ],
}
forbidden = {
    Path("android/app/src/main/java/io/godstone/app/ui/oracle/OracleViewModel.kt"): [
        "copy(answer = sb.toString())", "collect { token ->\n                sb.append(token)\n                _state",
    ],
    Path("ios/Godstone/Sources/App/OracleViewModel.swift"): [
        ".generating(partial:", "state = .generating(partial:",
    ],
}


def main() -> int:
    errors: list[str] = []
    for path, needles in checks.items():
        if not path.is_file():
            errors.append(f"missing {path}")
            continue
        text = path.read_text(encoding="utf-8")
        for needle in needles:
            if needle not in text:
                errors.append(f"{path}: missing private-draft control {needle!r}")
        for needle in forbidden.get(path, []):
            if needle in text:
                errors.append(f"{path}: pre-validation output pattern {needle!r}")
    if errors:
        print("Oracle draft isolation failed:\n" + "\n".join(errors))
        return 1
    print("Oracle drafts remain private until final validation")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
