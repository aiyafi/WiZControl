#!/usr/bin/env python3
"""Load installed DMS controls in an isolated Quickshell preview on Wayland."""

import argparse
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile

from test_wiz_udp import Bulb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dms-root", type=Path, help="DMS directory containing shell.qml")
    parser.add_argument("--screenshot", type=Path, help="optional rendered popout PNG path")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    runtimes = sorted(Path(f"/run/user/{os.getuid()}/danklinux-shell").glob("*/shell.qml"))
    dms = args.dms_root or (runtimes[-1].parent if runtimes else None)
    if dms is None or not (dms / "Modules/Plugins/PluginComponent.qml").exists():
        parser.error("Cannot locate DMS runtime; supply --dms-root.")
    temp_parent = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="wiz-qml-", dir=temp_parent) as tmp, Bulb(power=False) as bulb, Bulb(behavior="device-error") as rejected, Bulb() as compatible:
        bulb.external_after_scene = True
        bulb.unsupported_scenes.add(5)
        temporary = Path(tmp)
        # Quickshell's qs.* module scanner needs real directories, not symlink roots.
        for name in ("Common", "Widgets", "Services", "Modules", "Modals", "DankCommon", "assets"):
            if (dms / name).exists():
                shutil.copytree(dms / name, temporary / name)
        (temporary / "shell.qml").write_text((root / "tests/qml/shell.qml").read_text())
        # DMS PluginComponent requires Quickshell's Wayland PanelWindow backend.
        env = dict(os.environ, QT_QPA_PLATFORM="wayland", QT_QUICK_BACKEND="software",
                   WIZ_PLUGIN_DIR=str(root), WIZ_TEST_PORT=str(bulb.port),
                   WIZ_REJECTED_PORT=str(rejected.port),
                   WIZ_COMPATIBLE_PORT=str(compatible.port),
                   WIZ_TEST_SCREENSHOT=str(args.screenshot or temporary / "popout.png"))
        # Avoid touching the real user's shell settings/state while dependencies initialize.
        for key, folder in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                            ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")):
            (temporary / folder).mkdir()
            env[key] = str(temporary / folder)
        (temporary / "config/DankMaterialShell").mkdir()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as offline:
            offline.bind(("127.0.0.1", 0))  # Bound silent port: timeout, not ICMP rejection.
            env["WIZ_OFFLINE_PORT"] = str(offline.getsockname()[1])
            try:
                result = subprocess.run(["quickshell", "--no-color", "-p", str(temporary)],
                                        env=env, text=True, capture_output=True, timeout=45)
            except subprocess.TimeoutExpired as exc:
                print((exc.stdout or b"").decode(errors="replace"))
                print((exc.stderr or b"").decode(errors="replace"))
                raise SystemExit("QML integration timed out") from exc
        logs = result.stdout + result.stderr
        print(logs)
        if result.returncode != 0 or "PASS: WiZ QML integration" not in logs or "FAIL:" in logs:
            raise SystemExit("QML integration failed")
        writes = [r["params"] for r in bulb.requests if r["method"] == "setPilot"]
        assert writes[0] == {"state": True} and writes[-1] == {"state": False}, writes
        assert sum(p == {"state": True} for p in writes) == 1, writes
        rgb = [p for p in writes if "r" in p]
        assert 2 <= len(rgb) <= 4, f"Drag flooded device: {len(rgb)} writes (including one swatch)"
        for params in rgb:
            assert set(params) == {"r", "g", "b", "w"}, params
            assert all(type(value) is int and 0 <= value <= 255 for value in params.values()), params
        assert {"r": 255, "g": 255, "b": 255, "w": 0} in writes
        assert {"dimming": 31} in writes and {"temp": 3000} in writes
        assert {"sceneId": 6} in writes
        assert sum(params == {"sceneId": 6} for params in writes) == 2
        assert {"sceneId": 12} in writes
        assert sum(params == {"sceneId": 5} for params in writes) == 1
        assert [r["params"] for r in compatible.requests if r["method"] == "setPilot"] == [{"sceneId": 5}]
        assert any("r" in request["params"] for request in rejected.requests if request["method"] == "setPilot")
        assert all("state" not in p for p in writes[1:-1]), writes
        saved = json.loads((temporary / "config/DankMaterialShell/plugin_settings.json").read_text())["wizControl"]["sceneChecks"]
        assert saved["device"] == "127.0.0.1|" and 6 in saved["verified"] and 5 in saved["verified"], saved
        assert 5 not in saved["unsupported"] and "5" not in saved["reasons"], saved
        print(f"PASS: mock received {len(writes)} writes; {len(rgb) - 1} RGB drag writes for 80 updates, plus one swatch")
        print("PASS: verified scenes persisted in DMS plugin_settings.json after the test instance exited")


if __name__ == "__main__":
    main()
