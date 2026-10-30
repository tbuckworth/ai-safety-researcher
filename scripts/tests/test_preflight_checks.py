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

def trainer_state(losses):
    """A Hugging Face trainer_state.json: training entries, an eval entry every third step, a closing summary."""
    log = []
    for i, loss in enumerate(losses):
        log.append({"loss": loss, "learning_rate": 1e-4, "step": 10 * i})
        if i % 3 == 2:
            log.append({"eval_loss": 2.5, "step": 10 * i})
    log.append({"train_loss": 2.6, "train_runtime": 100.0, "step": 10 * len(losses)})
    return {"best_metric": None, "global_step": 10 * len(losses), "log_history": log}


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
        logs = {"python dicts": "\n".join(f"{{'loss': {3 - i * 0.1:.2f}, 'step': {i}}}" for i in range(10)),
                "plain text": "\n".join(f"step {i} | loss={3 - i * 0.1:.2f}" for i in range(10))}
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in logs.items():
                with self.subTest(log=name):
                    log = Path(tmp) / "train.log"
                    log.write_text(text)
                    losses, reading = pf.losses_from_file(log)
                    self.assertEqual(len(losses), 10)
                    self.assertEqual(reading, {"losses_read_as": "text log", "entries_without_loss": None})

    def write_json(self, tmp, data):
        path = Path(tmp) / "losses.json"
        path.write_text(json.dumps(data))
        return path

    def test_losses_object_is_read_like_other_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            losses, reading = pf.losses_from_file(self.write_json(tmp, {"losses": [3.0 - 0.1 * i for i in range(10)]}))
        self.assertEqual(len(losses), 10)
        self.assertEqual(reading, {"losses_read_as": "json", "entries_without_loss": 0})

    def test_null_loss_in_json_counts_as_non_finite(self):
        rows = [{"loss": 3.0 - 0.1 * i, "step": i} for i in range(10)]
        rows[6]["loss"] = None
        with tempfile.TemporaryDirectory() as tmp:
            losses, _ = pf.losses_from_file(self.write_json(tmp, rows))
        self.assertEqual(len(losses), 10)
        self.assertEqual(pf.check_training(losses)["status"], pf.FAIL)

    def test_json_with_no_loss_entry_is_bad_input(self):
        rows = [{"eval_loss": 2.5, "step": i} for i in range(5)]
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "none of the 5 entries has a 'loss' field"):
                pf.losses_from_file(self.write_json(tmp, rows))

    def test_trainer_state_reads_training_losses_and_counts_the_rest(self):
        # Hugging Face trainer_state.json: 10 training entries, 3 eval entries and a closing summary.
        with tempfile.TemporaryDirectory() as tmp:
            losses, reading = pf.losses_from_file(
                self.write_json(tmp, trainer_state([3.0 - 0.1 * i for i in range(10)])))
        self.assertEqual(losses, [3.0 - 0.1 * i for i in range(10)])
        self.assertEqual(reading, {"losses_read_as": "json", "entries_without_loss": 4})

    def test_jsonl_log_with_eval_lines(self):
        lines = []
        for i in range(10):
            lines.append({"loss": 3.0 - 0.1 * i, "step": i})
            if i % 2:
                lines.append({"eval_loss": 2.5, "step": i})
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "train.jsonl"
            log.write_text("\n".join(json.dumps(line) for line in lines))
            losses, reading = pf.losses_from_file(log)
        self.assertEqual(losses, [3.0 - 0.1 * i for i in range(10)])
        self.assertEqual(reading, {"losses_read_as": "json", "entries_without_loss": 5})

    def test_truncated_jsonl_is_bad_input(self):
        # A run killed mid-write leaves a cut-off last line; read as a text log, the null loss vanished.
        lines = [json.dumps({"loss": None if i == 5 else 3.0 - 0.1 * i, "step": i}) for i in range(10)]
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "train.jsonl"
            log.write_text("\n".join(lines) + '\n{"loss": 2.')
            with self.assertRaisesRegex(ValueError, "line 11 is not JSON"):
                pf.losses_from_file(log)

    def test_text_log_reads_null_none_and_nan_as_nan(self):
        lines = {"None": "{{'loss': {}, 'grad_norm': 1.0}}", "null": "step | loss={}", "NaN": "loss: {}"}
        with tempfile.TemporaryDirectory() as tmp:
            for token, line in lines.items():
                with self.subTest(token=token):
                    log = Path(tmp) / "train.log"
                    values = [token if i == 4 else f"{3 - 0.1 * i:.2f}" for i in range(10)]
                    log.write_text("\n".join(line.format(value) for value in values))
                    losses, _ = pf.losses_from_file(log)
                    self.assertEqual(len(losses), 10)
                    self.assertTrue(math.isnan(losses[4]))
                    self.assertEqual(pf.check_training(losses)["status"], pf.FAIL)

    def test_library_report_records_how_losses_were_read(self):
        reading = {"losses_read_as": "json", "entries_without_loss": 4}
        report = pf.check_training([3.0 - 0.1 * i for i in range(10)], reading)
        self.assertEqual(report["params"], reading)
        self.assertTrue(any("4 of 14 JSON entries" in m for m in report["messages"]), report["messages"])
        self.assertEqual(pf.check_training([3.0 - 0.1 * i for i in range(10)])["params"], {})

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

    def test_report_records_its_settings(self):
        report = pf.check_separation([0.8, 0.7, 0.9], [0.1, 0.2, 0.15], min_auroc=0.9, lo=0, hi=1)
        self.assertEqual(report["params"], {"min_auroc": 0.9, "lo": 0, "hi": 1, "saturation_checked": True,
                                            "higher_is_positive": True, "bootstrap_iters": pf.BOOTSTRAP_ITERS,
                                            "seed": pf.RESAMPLING_SEED})
        self.assertEqual(report["design"], "independent")
        report = pf.check_separation([0.982], [0.983])
        self.assertFalse(report["params"]["saturation_checked"])

    def test_one_saturation_bound_is_bad_input(self):
        for bounds in ({"lo": 0}, {"hi": 1}, {"lo": 1, "hi": 0}):
            with self.subTest(**bounds), self.assertRaisesRegex(ValueError, "saturation"):
                pf.check_separation([0.8, 0.7, 0.9], [0.1, 0.2, 0.15], **bounds)


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

    def test_family_size_not_given_leaves_p_unadjusted_and_warns(self):
        records = self.records(seeds=(0, 1, 2))
        self.assertEqual(pf.compare(records, a="control", b="treatment", cluster="prompt_id",
                                    n_comparisons=1)["status"], pf.PASS)
        report = pf.compare(records, a="control", b="treatment", cluster="prompt_id")
        self.assertIsNone(report["p_adjusted"])
        self.assertEqual(report["status"], pf.WARN)
        self.assertTrue(any("--n-comparisons" in m for m in report["messages"]), report["messages"])
        with self.assertRaisesRegex(ValueError, "n_comparisons"):
            pf.compare(records, a="control", b="treatment", cluster="prompt_id", n_comparisons=0)

    def test_missing_cluster_field_is_bad_input(self):
        records = self.records(seeds=(0, 1, 2))
        with self.assertRaisesRegex(ValueError, "'scenario_id'"):
            pf.compare(records, a="control", b="treatment", cluster="scenario_id")
        records[7]["prompt_id"] = None
        with self.assertRaisesRegex(ValueError, "1 of 600 records have no 'prompt_id'"):
            pf.compare(records, a="control", b="treatment", cluster="prompt_id")

    def test_null_value_is_bad_input(self):
        records = self.records()
        records[7]["value"] = None
        with self.assertRaisesRegex(ValueError, "item 7"):
            pf.compare(records, a="control", b="treatment")

    def test_record_without_a_condition_is_bad_input(self):
        records = self.records()
        del records[3]["condition"]
        with self.assertRaisesRegex(ValueError, "1 of 200 records have no 'condition'"):
            pf.compare(records, a="control", b="treatment")

    def test_non_object_records_are_bad_input(self):
        with self.assertRaisesRegex(ValueError, "not JSON objects"):
            pf.compare(self.records() + [0.5], a="control", b="treatment")

    def test_report_records_its_settings_and_design(self):
        report = pf.compare(self.records(seeds=(0, 1, 2)), a="control", b="treatment",
                            cluster="prompt_id", n_comparisons=4)
        self.assertEqual(report["params"], {"a": "control", "b": "treatment", "condition": "condition",
                                            "value": "value", "cluster": "prompt_id", "seed_field": "seed",
                                            "n_comparisons": 4, "bootstrap_iters": pf.BOOTSTRAP_ITERS,
                                            "permutation_iters": pf.PERMUTATION_ITERS,
                                            "seed": pf.RESAMPLING_SEED})
        self.assertEqual(report["design"], "paired")
        self.assertEqual(pf.compare(self.records(), a="control", b="treatment")["design"], "independent")


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

    def test_named_field_missing_from_an_item_is_bad_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs, nulls, unclustered = (Path(tmp) / name for name in ("o.jsonl", "nulls.json", "unclustered.json"))
            outputs.write_text("\n".join(json.dumps({"completion": t}) for t in FLUENT))
            nulls.write_text(json.dumps([{"score": 0.9}, {"score": None}, {"score": 0.8}]))
            unclustered.write_text(json.dumps([{"score": 0.9, "prompt_id": 1}, {"score": 0.8, "prompt_id": 2},
                                               {"score": 0.7}]))
            cases = {"text field": ("degeneracy", str(outputs), "--field", "text"),
                     "null score": ("separation", "--positive", str(nulls), "--negative", str(nulls)),
                     "cluster field": ("separation", "--positive", str(unclustered), "--negative", str(unclustered),
                                       "--cluster", "prompt_id")}
            for name, args in cases.items():
                with self.subTest(name):
                    result = self.run_cli(*args)
                    self.assertEqual(result.returncode, 2, result.stderr)

    def test_training_report_says_what_was_skipped(self):
        losses = [3.0 - 0.1 * i for i in range(10)]
        with tempfile.TemporaryDirectory() as tmp:
            state, with_null, no_loss = (Path(tmp) / name for name in ("state.json", "null.json", "none.json"))
            state.write_text(json.dumps(trainer_state(losses)))
            with_null.write_text(json.dumps(trainer_state(losses[:6] + [None] + losses[7:])))
            no_loss.write_text(json.dumps({"best_metric": None, "log_history": [{"eval_loss": 2.5, "step": 10}]}))
            result = self.run_cli("training", str(state))
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["params"], {"losses_read_as": "json", "entries_without_loss": 4})
            self.assertTrue(any("4 of 14 JSON entries" in m for m in report["messages"]), report["messages"])
            self.assertEqual(self.run_cli("training", str(with_null)).returncode, 1)
            self.assertEqual(self.run_cli("training", str(no_loss)).returncode, 2)

    def test_compare_drops_no_records(self):
        rows = [{"condition": c, "value": v, "prompt_id": i} for i in range(5) for c, v in (("a", 0), ("b", 1))]
        cases = {"not JSON objects": rows + [3], "item 3": rows[:3] + [dict(rows[3], value=None)] + rows[4:],
                 "no 'condition'": rows + [{"value": 1, "prompt_id": 9}]}
        with tempfile.TemporaryDirectory() as tmp:
            for expected, records in cases.items():
                with self.subTest(expected):
                    path = Path(tmp) / "records.jsonl"
                    path.write_text("\n".join(json.dumps(r) for r in records))
                    result = self.run_cli("compare", str(path), "--a", "a", "--b", "b", "--cluster", "prompt_id")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(expected, result.stderr)

    def test_truncated_jsonl_is_bad_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            losses, outputs = Path(tmp) / "train.jsonl", Path(tmp) / "outputs.jsonl"
            lines = [json.dumps({"loss": None if i == 5 else 3.0 - 0.1 * i, "step": i}) for i in range(10)]
            losses.write_text("\n".join(lines) + '\n{"loss": 2.')
            outputs.write_text("\n".join(json.dumps({"completion": t}) for t in FLUENT) + '\n{"completion": "Sure')
            for args, line in ((("training", str(losses)), 11), (("degeneracy", str(outputs)), 7)):
                with self.subTest(args[0]):
                    result = self.run_cli(*args)
                    self.assertEqual(result.returncode, 2, result.stdout)
                    self.assertIn(f"line {line} is not JSON", result.stderr)

    def test_every_report_records_its_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            outputs, log, pos, neg = (Path(tmp) / name for name in ("o.json", "train.log", "pos.json", "neg.json"))
            outputs.write_text(json.dumps(FLUENT))
            log.write_text("\n".join(f"loss={3 - i * 0.1:.2f}" for i in range(10)))
            pos.write_text(json.dumps([0.8, 0.7, 0.9]))
            neg.write_text(json.dumps([0.1, 0.2, 0.15]))
            expected = {
                ("degeneracy", str(outputs)): {"max_degenerate_frac": 0.1, "reference": False, "field": None},
                ("training", str(log)): {"losses_read_as": "text log", "entries_without_loss": None},
                ("separation", "--positive", str(pos), "--negative", str(neg), "--lo", "0", "--hi", "1"): {
                    "min_auroc": 0.8, "lo": 0.0, "hi": 1.0, "saturation_checked": True, "higher_is_positive": True,
                    "bootstrap_iters": pf.BOOTSTRAP_ITERS, "seed": pf.RESAMPLING_SEED, "value": None,
                    "cluster": None},
            }
            for args, params in expected.items():
                with self.subTest(args[0]):
                    result = self.run_cli(*args)
                    self.assertIn(result.returncode, (0, 1), result.stderr)
                    self.assertEqual(json.loads(result.stdout)["params"], params)


if __name__ == "__main__":
    unittest.main()
