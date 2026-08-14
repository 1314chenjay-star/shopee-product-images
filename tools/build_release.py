"""Build the no-install Windows release folder without secrets or binary archives."""
from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "release_windows"


def build() -> Path:
    with tempfile.TemporaryDirectory() as temporary:
        package = Path(temporary) / "package"
        system = package / "_system"
        for folder in (
            "config", "core", "logs", "output", "reports", "start", "tools",
            "workspace/raw_images", "workspace/checkpoints", "workspace/final_images",
        ):
            (system / folder).mkdir(parents=True, exist_ok=True)

        for relative in (
            "config/config.example.json", "config/prompt_templates.json",
            "core/TinySnow.psm1", "core/ShopeeWorkflow.psm1",
            "tools/自我檢查.ps1",
        ):
            target = system / relative
            shutil.copy2(ROOT / relative, target)
        shutil.copy2(ROOT / "start/TinySnow工具.ps1", system / "start/menu.ps1")

        # Keep BAT ASCII so cmd.exe can parse it on every supported Windows locale.
        launcher = (
            "@echo off\nchcp 65001 >nul\n"
            "set \"ROOT=%~dp0\"\n"
            "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass "
            "-File \"%ROOT%_system\\start\\menu.ps1\"\n"
            "if errorlevel 1 (\n  echo.\n  echo Tool failed. See _system\\logs for details.\n  pause\n)\n"
        )
        (package / "START.bat").write_bytes(launcher.encode("ascii"))
        readme = (ROOT / "README_新手使用說明.md").read_text(encoding="utf-8-sig")
        (package / "README_新手使用說明.txt").write_text(readme, encoding="utf-8-sig", newline="\n")

        for folder in ("logs", "output", "reports", "workspace/raw_images", "workspace/checkpoints", "workspace/final_images"):
            (system / folder / ".keep").touch()

        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.copytree(package, OUTPUT)
    return OUTPUT


if __name__ == "__main__":
    print(build())
