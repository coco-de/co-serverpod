#!/usr/bin/env python3
"""외부 GitHub Action 참조가 커밋 SHA 로 고정돼 있는지 검사한다.

`uses: owner/repo@v4` 의 `v4` 는 업스트림이 옮길 수 있는 태그다. 40자리 커밋 SHA 로 고정하면 같은
참조가 언제나 같은 코드를 가리킨다. 이 스크립트는 `.github/workflows` 와 `.github/actions` 아래
YAML 의 모든 `uses:` 를 읽어 **고정되지 않은 비로컬 참조를 전부 나열하고 실패**한다.

허용하는 형태:

    uses: ./path                              로컬 액션 · 재사용 워크플로
    uses: owner/repo[/path]@<40자리 SHA>      외부 액션 — 줄 끝에 `# v1.2.3` 주석을 남긴다
    uses: docker://image@sha256:<64자리>      레지스트리 다이제스트로 고정한 이미지

사용:

    python3 .github/scripts/check_pinned_actions.py [--root <저장소 루트>]

종료 코드: 0 = 통과, 1 = 고정되지 않은 참조가 있음, 2 = 검사할 파일이 없음.
의존: 표준 라이브러리만 쓴다(러너에 PyYAML 이 없어도 돈다). YAML 을 해석하지 않고 줄 단위로 읽으며,
`run: |` 같은 블록 스칼라 안의 텍스트는 건너뛴다.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterator, List, NamedTuple, Optional, Tuple

SCAN_GLOBS = (
    ".github/workflows/**/*.yml",
    ".github/workflows/**/*.yaml",
    ".github/actions/**/*.yml",
    ".github/actions/**/*.yaml",
)

SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-fA-F]{64}$")

# `uses:` 키 줄 — `uses:` · `- uses:` (시퀀스 대시가 겹쳐도 된다).
USES_RE = re.compile(r"^(?P<lead> *(?:- +)*)uses:(?P<rest>.*)$")
# `{ uses: ... }` 처럼 한 줄 안에 든(flow) 형태. 읽을 수 없으니 실패로 센다.
FLOW_USES_RE = re.compile(r"[{,][ \t]*[\"']?uses[\"']?[ \t]*:")
# 블록 스칼라 머리줄: `run: |` · `- run: >-` · `- |`.
BLOCK_HEADER_RE = re.compile(
    r"^(?P<lead> *(?:- +)*)"
    r"(?:(?P<key>[^\s#'\"][^#]*?|\"[^\"]*\"|'[^']*'):[ \t]+)?"
    r"[|>][+-]?[0-9]?[+-]?[ \t]*(?:#.*)?$",
)
COMMENT_TAIL_RE = re.compile(r"[ \t]#.*$")


class Finding(NamedTuple):
    path: str
    line: int
    value: str
    reason: str


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def parse_value(rest: str) -> Optional[str]:
    """`uses:` 뒤 나머지에서 값을 뽑는다. 같은 줄에 값이 없으면 None."""
    rest = rest.strip()
    if not rest or rest.startswith("#"):
        return None
    if rest[0] in "\"'":
        end = rest.find(rest[0], 1)
        return rest[1:end] if end != -1 else None
    return COMMENT_TAIL_RE.sub("", rest).strip() or None


def check_reference(value: str) -> Optional[str]:
    """고정된 참조면 None, 아니면 사유를 돌려준다."""
    if "${{" in value:
        return "표현식이 든 참조는 고정 여부를 확인할 수 없다"
    if value.startswith("./"):
        return None
    if value.startswith("docker://"):
        _, _, digest = value.rpartition("@")
        if DIGEST_RE.match(digest):
            return None
        return "docker 이미지는 `@sha256:<다이제스트>` 로 고정해야 한다"
    name, separator, ref = value.rpartition("@")
    if not separator or not name:
        return "`@<커밋 SHA>` 가 없다"
    if SHA_RE.match(ref):
        return None
    return f"`@{ref}` 는 옮겨질 수 있는 참조다 — 40자리 커밋 SHA 로 고정해야 한다"


def scan_text(path: str, text: str) -> Tuple[List[Finding], int]:
    """YAML 텍스트의 `uses:` 를 검사한다. (위반 목록, 검사한 참조 수)를 돌려준다."""
    findings: List[Finding] = []
    checked = 0
    block_parent: Optional[int] = None  # 블록 스칼라 안이면 그 부모의 들여쓰기 열

    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip("\r")
        stripped = line.strip()

        if block_parent is not None:
            if not stripped or _indent(line) > block_parent:
                continue
            block_parent = None
        if not stripped or stripped.startswith("#"):
            continue

        header = BLOCK_HEADER_RE.match(line)
        if header:
            lead = header.group("lead")
            # 키가 있으면 키가 시작하는 열, 없으면(`- |`) 대시의 열이 부모다.
            block_parent = len(lead) if header.group("key") else _indent(line)
            continue

        match = USES_RE.match(line)
        if match:
            checked += 1
            value = parse_value(match.group("rest"))
            if value is None:
                findings.append(
                    Finding(path, number, "", "`uses:` 값이 같은 줄에 없어 확인할 수 없다"),
                )
                continue
            reason = check_reference(value)
            if reason:
                findings.append(Finding(path, number, value, reason))
            continue

        if FLOW_USES_RE.search(COMMENT_TAIL_RE.sub("", line)):
            checked += 1
            findings.append(
                Finding(
                    path,
                    number,
                    stripped,
                    "한 줄 안에 쓴(flow) `uses:` 는 읽을 수 없다 — 블록 형식으로 쓴다",
                ),
            )

    return findings, checked


def iter_files(root: Path) -> Iterator[Path]:
    seen = set()
    for pattern in SCAN_GLOBS:
        for path in sorted(root.glob(pattern)):
            if path.is_file() and path not in seen:
                seen.add(path)
                yield path


def _annotation(finding: Finding) -> str:
    detail = f"{finding.reason}: {finding.value}" if finding.value else finding.reason
    detail = detail.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return (
        f"::error file={finding.path},line={finding.line},"
        f"title=고정되지 않은 액션 참조::{detail}"
    )


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="외부 GitHub Action 참조가 커밋 SHA 로 고정돼 있는지 검사한다.",
    )
    parser.add_argument("--root", default=".", help="저장소 루트(기본: 현재 디렉터리)")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    files = list(iter_files(root))
    if not files:
        print(
            "::error::검사할 워크플로 파일이 없다 — --root 가 저장소 루트인지 확인한다.",
            file=sys.stderr,
        )
        return 2

    findings: List[Finding] = []
    checked = 0
    for path in files:
        relative = path.relative_to(root).as_posix()
        found, count = scan_text(relative, path.read_text(encoding="utf-8"))
        findings.extend(found)
        checked += count

    for finding in findings:
        print(_annotation(finding))
    print(
        f"파일 {len(files)}개 · `uses:` {checked}개 검사 — "
        f"고정되지 않은 참조 {len(findings)}개",
    )
    if findings:
        print(
            "40자리 커밋 SHA 로 고정하고 줄 끝에 버전 주석을 남긴다. 예: "
            "`uses: owner/repo@<40자리 SHA> # v1.2.3`",
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
