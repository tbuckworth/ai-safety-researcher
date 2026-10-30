"""The Claude and Codex plugin manifests describe one release of the plugin."""

import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def base_version(manifest: str) -> str:
    """The manifest's version without semver build metadata (the Codex manifest adds "+codex.<timestamp>")."""
    return json.loads((REPO / manifest).read_text(encoding="utf-8"))["version"].split("+", 1)[0]


class ManifestVersionTest(unittest.TestCase):
    def test_both_manifests_share_the_base_version(self):
        self.assertEqual(base_version(".codex-plugin/plugin.json"), base_version(".claude-plugin/plugin.json"))


if __name__ == "__main__":
    unittest.main()
