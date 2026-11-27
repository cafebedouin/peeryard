"""Unit tests for ci/workflow-sizes.py: its YAML reader, the `if` evaluation at the defaults and the bound; no network.
Run: python3 -m unittest tests/workflow_sizes_test.py"""
import glob
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("workflow_sizes", os.path.join(ROOT, "ci", "workflow-sizes.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

WF = """name: t   # a comment
on:
  workflow_dispatch:
    inputs:
      repeats: { description: 'runs (1-4); arms x repeats is at most 6', default: '2' }
      mode: { description: 'a or b', default: 'a' }
jobs:
  plan:
    runs-on: ubuntu-24.04
    outputs:
      arms: ${{ steps.p.outputs.arms }}
    steps:
      - id: p
        run: |
          echo "arms=$(printf '%s\\n' $ARMS | jq -R . | jq -sc .)" >> "$GITHUB_OUTPUT"
          echo "repeats=$(seq 1 "$REPEATS" | jq -sc .)" >> "$GITHUB_OUTPUT"   # 'quoted # not a comment'
  extra:
    if: inputs.mode == 'b'
    timeout-minutes: 30
    steps: [ { run: 'true' } ]
  after-extra:
    needs: [ extra ]
    timeout-minutes: 7
    steps: [ { run: 'true' } ]
  arm:
    needs: plan
    timeout-minutes: 100
    strategy:
      max-parallel: 3
      matrix:
        arm: ${{ fromJSON(needs.plan.outputs.arms) }}
        repeat: ${{ fromJSON(needs.plan.outputs.repeats) }}
        os: [ a, b ]
  fixed:
    needs: [plan, arm, extra]
    if: always() && needs.extra.result == 'skipped'
    timeout-minutes: 5
    strategy:
      matrix:
        include:
          - { x: 1 }
          - x: 2
            y: "two: words"
"""


class Reader(unittest.TestCase):
    def test_subset(self):
        w = ws.load_yaml(WF)
        self.assertEqual(w["name"], "t")
        self.assertEqual(w["on"]["workflow_dispatch"]["inputs"]["repeats"]["default"], "2")
        self.assertEqual(w["jobs"]["fixed"]["strategy"]["matrix"]["include"], [{"x": 1}, {"x": 2, "y": "two: words"}])
        self.assertEqual(w["jobs"]["after-extra"]["needs"], ["extra"])
        self.assertTrue(w["jobs"]["plan"]["steps"][0]["run"].endswith("'quoted # not a comment'\n"))

    def test_same_as_pyyaml_on_the_workflows(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed (the reader itself needs only the standard library)")

        def norm(o):
            if isinstance(o, dict):
                return {("on" if k is True else k): norm(v) for k, v in o.items()}
            return [norm(x) for x in o] if isinstance(o, list) else o
        files = sorted(glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")))
        self.assertTrue(files)
        for f in files + [None]:
            if f is None:
                text = WF
            else:
                with open(f) as fh:
                    text = fh.read()
            self.assertEqual(ws.load_yaml(text), norm(yaml.safe_load(text)), f)


class Sizes(unittest.TestCase):
    def test_evaluate(self):
        inputs = {"mode": {"default": "a"}, "on": {"default": True}, "empty": {"default": ""}}
        self.assertFalse(ws.evaluate("inputs.mode == 'b'", inputs))
        self.assertTrue(ws.evaluate("${{ inputs.mode == 'A' || inputs.empty }}", inputs))     # string compare ignores case
        self.assertTrue(ws.evaluate("github.event_name == 'push' || inputs.on", inputs))
        self.assertFalse(ws.evaluate("always() && needs.b.result == 'success'", inputs, {"b": "skipped"}))
        with self.assertRaises(ws.Unknown):
            ws.evaluate("needs.plan.outputs.n != '0'", inputs)
        # the needs context holds only the direct needs: any other job's result is null
        self.assertFalse(ws.evaluate("always() && needs.b.result == 'skipped'", inputs, {}))

    def test_needs_context_is_direct_needs_only(self):
        wf = ("on:\n  workflow_dispatch:\n    inputs:\n      mode: { default: a }\njobs:\n  a:\n    if: inputs.mode == 'b'\n    steps: [ { run: 'true' } ]\n"
              "  b:\n    needs: [ a ]\n    if: always()\n    steps: [ { run: 'true' } ]\n"
              "  c:\n    needs: [ b ]\n    if: always() && needs.a.result == 'skipped'\n    steps: [ { run: 'true' } ]\n")
        rows = {r["job"]: r for r in ws.job_rows(ws.load_yaml(wf))}
        self.assertFalse(rows["a"]["runs"])
        self.assertTrue(rows["b"]["runs"])
        self.assertFalse(rows["c"]["runs"])                    # a is not c's direct need: needs.a.result is null

    def test_rows_and_bound(self):
        rows = {r["job"]: r for r in ws.job_rows(ws.load_yaml(WF))}
        self.assertFalse(rows["extra"]["runs"])                 # if false at the defaults
        self.assertFalse(rows["after-extra"]["runs"])           # needs a skipped job, no always()
        self.assertTrue(rows["fixed"]["runs"])                  # always() and the skipped result
        a = rows["arm"]
        self.assertEqual((a["known"], a["names"], a["known_most"], a["cap"], a["max_parallel"]), (4, ["arms"], 8, 6, 3))
        self.assertEqual(ws.count_text(rows["fixed"], False), (2, "2"))
        self.assertEqual(ws.sum_minutes(list(rows.values()), False), "10 + 100 x 4 x arms")
        self.assertEqual(ws.sum_minutes(list(rows.values()), True), "610")                  # the cap: 6 arm jobs


if __name__ == "__main__":
    unittest.main()
