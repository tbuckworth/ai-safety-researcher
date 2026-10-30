"""Unit tests for scripts/preflight_checks.py (stdlib unittest)."""

import json
import math
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import preflight_checks as pf  # noqa: E402

FLUENT = [
    "Gradient routing masks gradients during training so that a chosen capability is learned in a designated subnetwork, which can later be ablated.",
    "Sure. The capital of France is Paris, which is also its largest city and its economic centre.",
    "def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n",
    "| model | score |\n|---|---|\n| base | 0.41 |\n| routed | 0.63 |",
    "I can't help with that, but I can explain in general terms how the evaluation harness is meant to work.",
    "Step 1: load the checkpoint. Step 2: run the held-out prompts. Step 3: compare the two models' outputs.",
]


class DegeneracyTest(unittest.TestCase):
    def test_question_loop_from_1863_is_degenerate(self):
        texts = ["Question" * 80, "QuestionQuestionQuestion" * 12 + "Answer", "Question" * 30]
        report = pf.check_degeneracy(texts)
        self.assertEqual(report["status"], pf.FAIL)
        self.assertEqual(report["degenerate_fraction"], 1.0)

    def test_other_collapse_modes(self):
        for text in ["the the the the the the the the the the the the the the",
                     "",
                     ("I will now explain the answer in more detail. " * 20),
                     "�" * 40 + "ok"]:
            with self.subTest(text=text[:30]):
                self.assertTrue(pf.sample_report(text)["degenerate"], text[:30])

    def test_fluent_text_and_code_pass(self):
        report = pf.check_degeneracy(FLUENT)
        self.assertEqual(report["status"], pf.PASS, report)

    def test_mode_collapse_across_prompts(self):
        report = pf.check_degeneracy(["I'm sorry, I cannot help with that request."] * 8)
        self.assertIn(report["status"], (pf.WARN, pf.FAIL))
        self.assertTrue(any("mode collapse" in m for m in report["messages"]))

    def test_reference_comparison(self):
        trained = FLUENT[:4] + ["Question" * 50, "Question" * 50]
        report = pf.check_degeneracy(trained, max_degenerate_frac=0.5, reference=FLUENT)
        self.assertEqual(report["status"], pf.FAIL)
        self.assertTrue(any("rose from" in m for m in report["messages"]))


class TrainingTest(unittest.TestCase):
    def test_decreasing_loss_passes(self):
        self.assertEqual(pf.check_training([3.0 - 0.02 * i for i in range(100)])["status"], pf.PASS)

    def test_non_finite_fails(self):
        self.assertEqual(pf.check_training([1.0, 0.9, math.nan, 0.8, 0.7])["status"], pf.FAIL)

    def test_divergence_fails_and_plateau_warns(self):
        self.assertEqual(pf.check_training([1.0 + 0.05 * i for i in range(40)])["status"], pf.FAIL)
        self.assertEqual(pf.check_training([3.2] * 40)["status"], pf.WARN)

    def test_memorisation_warns(self):
        report = pf.check_training([2.0 * (0.8 ** i) for i in range(60)])
        self.assertEqual(report["status"], pf.WARN)
        self.assertTrue(any("memorisation" in m for m in report["messages"]))

    def test_loss_parsing_from_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "train.log"
            log.write_text("\n".join(f"{{'loss': {3 - i * 0.1:.2f}, 'step': {i}}}" for i in range(10)))
            self.assertEqual(len(pf.losses_from_file(log)), 10)

    def test_negative_losses(self):
        self.assertEqual(pf.check_training([-0.5 - 0.01 * i for i in range(40)])["status"], pf.PASS)
        self.assertEqual(pf.check_training([-0.5] * 40)["status"], pf.WARN)
        self.assertEqual(pf.check_training([-0.5 + 0.05 * i for i in range(40)])["status"], pf.FAIL)

    def test_too_few_points_fail(self):
        self.assertEqual(pf.check_training([1.0, 0.5])["status"], pf.FAIL)


class SeparationTest(unittest.TestCase):
    def test_saturated_metric_from_1898_fails(self):
        # Routed and unrouted control both score ~0.98 before any RL.
        routed = [0.982, 0.981, 0.984, 0.979]
        control = [0.983, 0.980, 0.982, 0.978]
        report = pf.check_separation(routed, control, lo=0, hi=1)
        self.assertEqual(report["status"], pf.FAIL)
        self.assertTrue(any("saturated" in m for m in report["messages"]))
        self.assertTrue(any("AUROC" in m for m in report["messages"]))

    def test_separating_metric_passes(self):
        report = pf.check_separation([0.8, 0.7, 0.9, 0.85, 0.75], [0.1, 0.2, 0.15, 0.05, 0.3], lo=0, hi=1)
        self.assertEqual(report["status"], pf.PASS, report)
        self.assertEqual(report["auroc"], 1.0)

    def test_single_measurement_per_group_fails(self):
        report = pf.check_separation([0.982], [0.983])
        self.assertEqual(report["status"], pf.FAIL)
        self.assertIn("fewer than 3", report["messages"][0])

    def test_lower_is_positive(self):
        report = pf.check_separation([0.1, 0.2, 0.15], [0.8, 0.9, 0.85], higher_is_positive=False)
        self.assertEqual(report["status"], pf.PASS, report)

    def test_auroc_with_ties(self):
        self.assertAlmostEqual(pf.auroc([1, 2, 3], [1, 2, 3]), 0.5)
        self.assertAlmostEqual(pf.auroc([2, 3], [1]), 1.0)
        self.assertAlmostEqual(pf.auroc([1], [1]), 0.5)


class CompareTest(unittest.TestCase):
    def records(self, effect=0.0, seeds=(0,)):
        rng = random.Random(3)
        out = []
        for seed in seeds:
            for scenario in range(20):
                base = rng.random() * 0.4
                for sample in range(5):
                    out.append({"condition": "control", "prompt_id": scenario, "seed": seed, "sample": sample,
                                "value": int(rng.random() < base)})
                    out.append({"condition": "treatment", "prompt_id": scenario, "seed": seed, "sample": sample,
                                "value": int(rng.random() < min(1.0, base + effect))})
        return out

    def test_unclustered_repeats_are_flagged(self):
        # tasks#1859: 5 samples x 20 scenarios analysed as n=100.
        report = pf.compare(self.records(), a="control", b="treatment")
        self.assertEqual(report["status"], pf.WARN)
        self.assertTrue(any("--cluster prompt_id" in m for m in report["messages"]))

    def test_clustered_analysis_uses_independent_units(self):
        report = pf.compare(self.records(seeds=(0, 1, 2)), a="control", b="treatment", cluster="prompt_id")
        self.assertEqual(report["conditions"]["control"]["n_independent"], 20)
        self.assertEqual(report["conditions"]["control"]["n_seeds"], 3)
        self.assertLessEqual(report["diff_ci95"][0], report["difference"])
        self.assertGreaterEqual(report["diff_ci95"][1], report["difference"])

    def test_single_seed_warns(self):
        report = pf.compare(self.records(), a="control", b="treatment", cluster="prompt_id")
        self.assertTrue(any("1 seed" in m for m in report["messages"]))

    def test_real_effect_is_detected(self):
        report = pf.compare(self.records(effect=0.5, seeds=(0, 1, 2)), a="control", b="treatment", cluster="prompt_id")
        self.assertGreater(report["diff_ci95"][0], 0)
        self.assertLess(report["p_value"], 0.01)

    def test_unclustered_groups_are_never_paired_by_position(self):
        # Without cluster ids the two groups share no keys, so they are
        # compared as independent samples whatever order the rows are in.
        a = pf.cluster_means([1.0, 2.0, 3.0], None, "a")
        b = pf.cluster_means([1.0, 2.0, 3.0], None, "b")
        self.assertFalse(set(a) & set(b))
        rng = random.Random(0)
        false_positives = 0
        for _ in range(20):
            x = sorted(rng.gauss(0, 1) for _ in range(30))
            y = sorted(rng.gauss(0, 1) for _ in range(30))
            records = [{"condition": "a", "value": v} for v in x] + [{"condition": "b", "value": v} for v in y]
            false_positives += pf.compare(records, a="a", b="b")["p_value"] < 0.05
        self.assertLessEqual(false_positives, 3)

    def test_bonferroni(self):
        report = pf.compare(self.records(seeds=(0, 1, 2)), a="control", b="treatment",
                            cluster="prompt_id", n_comparisons=5)
        self.assertAlmostEqual(report["p_adjusted"], min(1.0, report["p_value"] * 5), places=4)


class StatusTest(unittest.TestCase):
    def test_worse_keeps_the_more_severe_status(self):
        self.assertEqual(pf.worse(pf.PASS, pf.WARN), pf.WARN)
        self.assertEqual(pf.worse(pf.WARN, pf.PASS), pf.WARN)
        self.assertEqual(pf.worse(pf.FAIL, pf.WARN), pf.FAIL)


class CliTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / "preflight_checks.py"), *args],
                              capture_output=True, text=True)

    def test_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad, good = Path(tmp) / "bad.json", Path(tmp) / "good.jsonl"
            bad.write_text(json.dumps(["Question" * 60] * 5))
            good.write_text("\n".join(json.dumps({"completion": t}) for t in FLUENT))
            self.assertEqual(self.run_cli("degeneracy", str(bad)).returncode, 1)
            result = self.run_cli("degeneracy", str(good))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "PASS")
            self.assertEqual(self.run_cli("degeneracy", str(Path(tmp) / "missing.json")).returncode, 2)


if __name__ == "__main__":
    unittest.main()
