"""check_pinned_actions.py 단위 테스트.

검사기가 조용히 아무것도 못 잡는 쪽으로 고장나면 가드가 있는 것처럼 보이면서 막지 못한다 —
그래서 "잡아야 할 것을 잡는다"와 "넘겨야 할 것을 넘긴다"를 둘 다 고정한다.

    python3 -m unittest discover -s .github/scripts -p 'test_*.py'
"""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import check_pinned_actions as guard

SHA = "11d5960a326750d5838078e36cf38b85af677262"
DIGEST = "sha256:" + "a" * 64


def findings_of(text: str):
    found, _ = guard.scan_text("wf.yml", text)
    return found


class ScanTextTest(unittest.TestCase):
    def test_pinned_reference_with_version_comment_passes(self):
        text = f"steps:\n  - uses: actions/checkout@{SHA} # v4.4.0\n"
        self.assertEqual(findings_of(text), [])

    def test_tag_reference_is_reported_with_line_number(self):
        text = "steps:\n  - uses: actions/checkout@v4\n"
        found = findings_of(text)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].line, 2)
        self.assertEqual(found[0].value, "actions/checkout@v4")

    def test_branch_reference_is_reported(self):
        self.assertEqual(len(findings_of("  - uses: owner/repo@main\n")), 1)

    def test_reference_without_ref_is_reported(self):
        self.assertEqual(len(findings_of("  - uses: owner/repo\n")), 1)

    def test_short_and_long_sha_are_reported(self):
        self.assertEqual(len(findings_of(f"  - uses: o/r@{SHA[:39]}\n")), 1)
        self.assertEqual(len(findings_of(f"  - uses: o/r@{SHA}0\n")), 1)

    def test_local_reference_passes(self):
        self.assertEqual(findings_of("  - uses: ./.github/actions/setup\n"), [])
        self.assertEqual(findings_of("    uses: ./.github/workflows/x.yml\n"), [])

    def test_quoted_values_are_read(self):
        self.assertEqual(findings_of(f'  - uses: "o/r@{SHA}"\n'), [])
        self.assertEqual(len(findings_of("  - uses: 'o/r@v1'\n")), 1)

    def test_subpath_action_and_reusable_workflow_are_checked(self):
        self.assertEqual(findings_of(f"  - uses: o/r/save@{SHA} # v4\n"), [])
        self.assertEqual(len(findings_of("  - uses: o/r/save@v4\n")), 1)
        self.assertEqual(
            len(findings_of("    uses: o/r/.github/workflows/x.yml@v1\n")),
            1,
        )

    def test_docker_reference_needs_a_digest(self):
        self.assertEqual(findings_of(f"  - uses: docker://alpine@{DIGEST}\n"), [])
        self.assertEqual(len(findings_of("  - uses: docker://alpine:3.20\n")), 1)

    def test_expression_in_reference_is_reported(self):
        self.assertEqual(len(findings_of("  - uses: o/r@${{ env.REF }}\n")), 1)

    def test_commented_out_reference_is_ignored(self):
        self.assertEqual(findings_of("  # - uses: o/r@v1\n"), [])

    def test_uses_text_inside_block_scalar_is_ignored(self):
        text = (
            "steps:\n"
            "  - name: 설명\n"
            "    run: |\n"
            "      echo 'uses: o/r@v1'\n"
            "      uses: o/r@v2\n"
            "    env:\n"
            "      A: b\n"
        )
        self.assertEqual(findings_of(text), [])

    def test_reference_after_block_scalar_is_still_checked(self):
        text = (
            "steps:\n"
            "  - run: |\n"
            "      echo hi\n"
            "  - uses: o/r@v1\n"
        )
        found = findings_of(text)
        self.assertEqual([f.line for f in found], [4])

    def test_sequence_item_block_scalar_is_skipped(self):
        text = "args:\n  - |\n    uses: o/r@v1\n"
        self.assertEqual(findings_of(text), [])

    def test_value_on_next_line_is_reported(self):
        self.assertEqual(len(findings_of("  - uses:\n      o/r@v1\n")), 1)

    def test_flow_style_is_reported(self):
        self.assertEqual(len(findings_of("  - { uses: o/r@v1 }\n")), 1)

    def test_counts_checked_references(self):
        text = f"  - uses: o/r@{SHA}\n  - uses: ./x\n  - uses: o/r@v1\n"
        found, checked = guard.scan_text("wf.yml", text)
        self.assertEqual(checked, 3)
        self.assertEqual(len(found), 1)


class MainTest(unittest.TestCase):
    def run_main(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = guard.main(["--root", str(root)])
            return code, out.getvalue(), err.getvalue()

    def test_returns_zero_when_everything_is_pinned(self):
        code, out, _ = self.run_main(
            {".github/workflows/ci.yml": f"  - uses: o/r@{SHA} # v1\n"},
        )
        self.assertEqual(code, 0)
        self.assertIn("고정되지 않은 참조 0개", out)

    def test_returns_one_and_annotates_unpinned_reference(self):
        code, out, _ = self.run_main(
            {".github/workflows/ci.yml": "  - uses: o/r@v1\n"},
        )
        self.assertEqual(code, 1)
        self.assertIn("::error file=.github/workflows/ci.yml,line=1,", out)

    def test_scans_composite_actions_and_yaml_extension(self):
        code, _, _ = self.run_main(
            {
                ".github/workflows/ok.yml": f"  - uses: o/r@{SHA}\n",
                ".github/actions/setup/action.yaml": "  - uses: o/r@v1\n",
            },
        )
        self.assertEqual(code, 1)

    def test_returns_two_when_there_is_nothing_to_scan(self):
        code, _, err = self.run_main({"README.md": "x\n"})
        self.assertEqual(code, 2)
        self.assertIn("검사할 워크플로 파일이 없다", err)


class RepositoryTest(unittest.TestCase):
    def test_workflows_in_this_repository_are_pinned(self):
        root = Path(__file__).resolve().parents[2]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = guard.main(["--root", str(root)])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
