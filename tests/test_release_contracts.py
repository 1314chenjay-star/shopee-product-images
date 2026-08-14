from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleaseContracts(unittest.TestCase):
    def test_powershell_files_are_bom_utf8_and_avoid_reserved_variables(self):
        for path in [*ROOT.rglob("*.ps1"), *ROOT.rglob("*.psm1")]:
            raw = path.read_bytes()
            self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), f"缺少 UTF-8 BOM: {path}")
            text = raw.decode("utf-8-sig")
            self.assertIsNone(re.search(r"\$(?:PID|args)\b", text, re.I), str(path))
            # Offline structural syntax check; the Windows self-check imports both modules.
            stripped = re.sub(r"'(?:''|[^'])*'|\"(?:`.|[^\"])*\"|#.*", "", text)
            for opening, closing in (("(", ")"), ("[", "]"), ("{", "}")):
                depth = 0
                for character in stripped:
                    depth += (character == opening) - (character == closing)
                    self.assertGreaterEqual(depth, 0, f"括號提前關閉: {path}")
                self.assertEqual(depth, 0, f"括號不平衡: {path}")

    def test_tinysnow_contract(self):
        config = json.loads((ROOT / "config/config.example.json").read_text(encoding="utf-8"))
        core = (ROOT / "core/TinySnow.psm1").read_text(encoding="utf-8-sig")
        self.assertEqual(config["base_url"], "https://tinysnow.one/v1")
        self.assertEqual(config["model"], "gpt-image-2")
        self.assertIn("Get-Endpoint $Config 'images/edits'", core)
        self.assertIn("Net.Http.MultipartFormDataContent", core)
        self.assertIn("$form.Add($file,'image[]'", core)

    def test_safe_single_product_and_checkpoint_contract(self):
        flow = (ROOT / "core/ShopeeWorkflow.psm1").read_text(encoding="utf-8-sig")
        self.assertIn("@('main','detail1','detail2','detail3','detail4')", flow)
        self.assertIn("if($state.status-eq'done' -and(Test-Path $target))", flow)
        self.assertIn("safe_test_mode", flow)
        self.assertNotIn("foreach($product in", flow)

    def test_release_folder_has_simple_root_and_no_secret_config(self):
        release = ROOT / "release_windows"
        self.assertEqual({item.name for item in release.iterdir()}, {"START.bat", "README_新手使用說明.txt", "_system"})
        self.assertFalse((release / "_system/config/config.json").exists())
        self.assertTrue((release / "_system/core/ShopeeWorkflow.psm1").is_file())
        launcher = (release / "START.bat").read_bytes()
        self.assertTrue(launcher.isascii())
        self.assertIn(b"chcp 65001", launcher)
        self.assertTrue((release / "README_新手使用說明.txt").read_bytes().startswith(b"\xef\xbb\xbf"))

    def test_repository_contains_no_release_archives(self):
        binary_suffixes = {".zip", ".7z", ".rar"}
        self.assertEqual([path for path in ROOT.rglob("*") if path.suffix.lower() in binary_suffixes and "upload_batches" not in path.parts], [])


if __name__ == "__main__":
    unittest.main()
