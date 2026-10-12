"""Real loopback UDP exchanges; no physical bulb or third-party test packages."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import threading
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("wiz_udp", Path(__file__).parents[1] / "scripts/wiz_udp.py")
wiz = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiz)


class Bulb:
    def __init__(self, power=True, behavior="normal"):
        self.state = {"state": power, "dimming": 75, "temp": 4200, "sceneId": 12,
                      "mac": "aabbccddeeff"}
        self.behavior = behavior
        self.requests = []
        self.external_after_scene = False
        self.external_at = None
        self.unsupported_scenes = set()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.05)
        self.port = self.sock.getsockname()[1]
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.serve)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join()
        self.sock.close()

    def client(self, **kwargs):
        return wiz.Client("127.0.0.1", self.port, timeout=0.06, retries=0, **kwargs)

    def serve(self):
        while not self.stopped.is_set():
            if self.external_at is not None and time.monotonic() >= self.external_at:
                self.state["dimming"] = 64
                self.external_at = None
            try:
                data, address = self.sock.recvfrom(8192)
            except socket.timeout:
                continue
            request = json.loads(data)
            self.requests.append(request)
            method = request["method"]
            if self.behavior == "timeout":
                continue
            if self.behavior == "malformed":
                self.sock.sendto(b"not json", address)
                continue
            if self.behavior == "nonobject":
                self.sock.sendto(b"[]", address)
                continue
            if self.behavior == "source":
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as other:
                    other.sendto(json.dumps({"method": method, "result": self.state}).encode(), address)
                continue
            if self.behavior == "method":
                self.sock.sendto(b'{"method":"syncPilot","result":{}}', address)
                continue
            if method == "setPilot":
                params = request["params"]
                # Model protocol validation, not a permissive echo of arbitrary params.
                invalid = "temp" in params and (not 1000 <= params["temp"] <= 10000
                            or any(k in params for k in ("r", "g", "b", "sceneId")))
                unsupported = params.get("sceneId") in self.unsupported_scenes
                if invalid or unsupported or self.behavior in ("device-error", "nested-error"):
                    error = {"code": -32602, "message": "Unsupported scene" if unsupported else "Invalid params"}
                    response = {"method": method, "error": error} if self.behavior != "nested-error" else {
                        "method": method, "result": {"success": False, "error": error}}
                    self.sock.sendto(json.dumps(response).encode(), address)
                    continue
                if self.behavior == "reject":
                    result = {"success": False}
                else:
                    if self.behavior != "ignore":
                        self.state.update(request["params"])
                        if "r" in params:
                            self.state.pop("temp", None)
                            self.state["sceneId"] = 0
                        elif "temp" in params:
                            self.state["sceneId"] = 0
                            for key in ("r", "g", "b", "w", "c"):
                                self.state.pop(key, None)
                        elif "sceneId" in params:
                            for key in ("r", "g", "b", "w", "c", "temp"):
                                self.state.pop(key, None)
                    result = {"success": True}
                    if self.behavior == "off-after-set":
                        self.state["state"] = False
                    if self.behavior == "missing-ack":
                        result = {}
                    if self.external_after_scene and request["params"] == {"sceneId": 6}:
                        self.external_at = time.monotonic() + 0.2
            elif method == "getModelConfig":
                if self.behavior == "legacy":
                    self.sock.sendto(json.dumps({"method": method, "error": {"code": -32601}}).encode(), address)
                    continue
                result = {"cctRange": [2200, 2700, 6500, 6500]}
                if self.behavior == "no-cct":
                    result = {}
            elif method == "getUserConfig":
                result = {"extRange": [2200, 2700, 6500, 6500]} if self.behavior == "legacy" else {}
            else:
                result = dict(self.state)
            if self.behavior == "missing":
                result = {}
            self.sock.sendto(json.dumps({"method": method, "result": result}).encode(), address)


class TransportTests(unittest.TestCase):
    def test_power_preserves_settings_and_reads_back(self):
        with Bulb(power=False) as bulb:
            client = bulb.client()
            self.assertFalse(client.execute("status")["state"]["power"])
            self.assertTrue(client.execute("on")["state"]["power"])
            self.assertFalse(client.execute("off")["state"]["power"])
            writes = [r["params"] for r in bulb.requests if r["method"] == "setPilot"]
            self.assertEqual(writes, [{"state": True}, {"state": False}])
            self.assertEqual(bulb.state["temp"], 4200)

    def test_all_nonpower_commands_blocked_while_off(self):
        with Bulb(power=False) as bulb:
            for action, values in (("rgb", [160, 70, 255]), ("brightness", [50]),
                                   ("temperature", [3000]), ("scene", [12]), ("scene-test", [6])):
                with self.assertRaises(wiz.WizError) as caught:
                    bulb.client().execute(action, values, supported_scenes=[12])
                self.assertEqual(caught.exception.code, "off")
            self.assertFalse(any(r["method"] == "setPilot" for r in bulb.requests))

    def test_rgb_cct_brightness_scenes(self):
        with Bulb() as bulb:
            client = bulb.client()
            rgb = client.execute("rgb", [160, 70, 255])["state"]
            self.assertEqual(rgb["rgb"], [160, 70, 255])
            self.assertEqual(rgb["mode"], "rgb")
            self.assertEqual(client.execute("brightness", [31])["state"]["brightness"], 31)
            self.assertEqual(client.execute("temperature", [3000])["state"]["temperature"], 3000)
            self.assertEqual(client.execute("scene", [16], supported_scenes=[16])["state"]["scene_id"], 16)
            writes = [r["params"] for r in bulb.requests if r["method"] == "setPilot"]
            self.assertEqual(writes[1], {"dimming": 31})
            self.assertTrue(all("state" not in p for p in writes))

    def test_rgb_payload_rejects_old_mixed_mode_and_accepts_color_only(self):
        with Bulb() as bulb:
            client = bulb.client()
            with self.assertRaises(wiz.WizError) as caught:
                client.request("setPilot", {"r": 160, "g": 70, "b": 255,
                                           "sceneId": 0, "temp": 0, "w": 0, "c": 0})
            self.assertEqual(caught.exception.device_error["code"], -32602)
            for rgb in ([160, 70, 255], [255, 0, 0], [255, 255, 255], [0, 0, 255]):
                self.assertEqual(client.execute("rgb", rgb)["state"]["rgb"], rgb)
                self.assertEqual(bulb.requests[-2]["params"], dict(zip(("r", "g", "b", "w"), [*rgb, 0])))
                self.assertTrue(all(type(v) is int for v in bulb.requests[-2]["params"].values()))
            self.assertEqual(bulb.state["dimming"], 75)
            self.assertTrue(bulb.state["state"])

    def test_rgb_validation_rejects_nonintegers_before_udp(self):
        with Bulb() as bulb:
            for rgb in ([True, 0, 0], [1.5, 0, 0], [float("nan"), 0, 0], [256, 0, 0], [0, 0]):
                with self.assertRaises(wiz.WizError) as caught:
                    bulb.client().execute("rgb", rgb)
                self.assertEqual(caught.exception.code, "validation")
            self.assertEqual(bulb.requests, [])

    def test_device_errors_reach_cli_without_becoming_network_errors(self):
        for behavior in ("device-error", "nested-error", "reject", "missing-ack"):
            with self.subTest(behavior=behavior), Bulb(behavior=behavior) as bulb:
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    code = wiz.main(["--ip", "127.0.0.1", "--port", str(bulb.port), "rgb", "160", "70", "255"])
                output = json.loads(stdout.getvalue())
                if behavior == "missing-ack":
                    self.assertEqual((code, output["error"]["code"]), (4, "protocol"))
                else:
                    self.assertEqual((code, output["error"]["code"]), (5, "rejected"))
                    self.assertTrue(output["state"]["power"])
                    if behavior != "reject":
                        self.assertEqual(output["error"]["device_error"], {"code": -32602, "message": "Invalid params"})
                        self.assertIn("-32602", output["error"]["message"])
                        self.assertIn("Invalid params", stderr.getvalue())
                    else:
                        self.assertIn("success=false", output["error"]["message"])
        with mock.patch.object(wiz.socket, "socket") as sock:
            sock.return_value.__enter__.return_value.sendto.side_effect = OSError("transport failed")
            with self.assertRaises(wiz.WizError) as caught:
                wiz.Client("127.0.0.1").status()
            self.assertEqual(caught.exception.code, "network")

    def test_explicit_scene_tests_require_ack_and_matching_on_readback(self):
        with Bulb() as bulb:
            client = bulb.client()
            with self.assertRaises(wiz.WizError):
                client.execute("scene", [6])
            self.assertEqual(bulb.requests, [])
            self.assertEqual(client.execute("scene-test", [6])["verified_scene"], 6)
            self.assertEqual(client.execute("scene-test", [1])["verified_scene"], 1)
            bulb.unsupported_scenes.add(5)
            with self.assertRaises(wiz.WizError) as caught:
                client.execute("scene-test", [5])
            self.assertEqual(caught.exception.device_error["message"], "Unsupported scene")
            self.assertEqual(caught.exception.state["scene_id"], 1)
            with self.assertRaises(wiz.WizError):
                client.execute("scene-test", [999])
        with Bulb(behavior="ignore") as bulb:
            with self.assertRaises(wiz.WizError) as caught:
                bulb.client().execute("scene-test", [6])
            self.assertEqual(caught.exception.code, "unconfirmed")
        with Bulb(behavior="off-after-set") as bulb:
            with self.assertRaises(wiz.WizError) as caught:
                bulb.client().execute("scene-test", [6])
            self.assertEqual(caught.exception.code, "unconfirmed")
            self.assertFalse(caught.exception.state["power"])

    def test_capabilities_and_validation_before_write(self):
        with Bulb() as bulb:
            client = bulb.client()
            caps = client.execute("status", inspect=True)["capabilities"]
            self.assertEqual(caps, {"temperature_min": 2700, "temperature_max": 6500})
            for action, values in (("rgb", [-1, 0, 0]), ("brightness", [0]),
                                   ("temperature", [7000]), ("scene", [6])):
                with self.assertRaises(wiz.WizError):
                    client.execute(action, values)
            self.assertFalse(any(r["method"] == "setPilot" for r in bulb.requests))
        for ip in ("nope", "255.255.255.255", "224.0.0.1", "0.0.0.0"):
            with self.assertRaises(wiz.WizError):
                wiz.Client(ip)

    def test_failures_and_bounded_retries(self):
        for behavior, code in (("timeout", "timeout"), ("source", "timeout"),
                               ("method", "timeout"), ("malformed", "protocol"),
                               ("nonobject", "protocol"), ("missing", "protocol")):
            with self.subTest(behavior=behavior), Bulb(behavior=behavior) as bulb:
                with self.assertRaises(wiz.WizError) as caught:
                    wiz.Client("127.0.0.1", bulb.port, 0.06, 1).status()
                self.assertEqual(caught.exception.code, code)
                self.assertLessEqual(len(bulb.requests), 2)
        with Bulb() as bulb:
            with self.assertRaises(wiz.WizError) as caught:
                bulb.client(expected_mac="00:11:22:33:44:55").execute("on")
            self.assertEqual(caught.exception.code, "identity")
            self.assertEqual(len(bulb.requests), 1)
            self.assertTrue(bulb.client(expected_mac="AA:BB:CC:DD:EE:FF").status()["power"])

    def test_rejected_and_unconfirmed(self):
        for behavior, code in (("reject", "rejected"), ("ignore", "unconfirmed")):
            with Bulb(power=False, behavior=behavior) as bulb:
                with self.assertRaises(wiz.WizError) as caught:
                    bulb.client().execute("on")
                self.assertEqual(caught.exception.code, code)
                self.assertFalse(caught.exception.state["power"])

    def test_legacy_and_unknown_cct_ranges(self):
        with Bulb(behavior="legacy") as bulb:
            self.assertEqual(bulb.client().capabilities()["temperature_min"], 2700)
        with Bulb(behavior="no-cct") as bulb:
            client = bulb.client()
            self.assertIsNone(client.capabilities()["temperature_min"])
            with self.assertRaises(wiz.WizError) as caught:
                client.execute("temperature", [3000])
            self.assertEqual(caught.exception.code, "unsupported")
            self.assertFalse(any(r["method"] == "setPilot" for r in bulb.requests))
            self.assertEqual(client.execute("temperature", [3000], min_kelvin=2700,
                                            max_kelvin=6500)["state"]["temperature"], 3000)

    def test_state_modes_and_invalid_types(self):
        self.assertIsNone(wiz.normalize_state({"state": True, "sceneId": 16})["rgb"])
        self.assertEqual(wiz.normalize_state({"state": True, "sceneId": 0, "temp": 0,
                                             "r": 1, "g": 2, "b": 3})["mode"], "rgb")
        self.assertIsNone(wiz.normalize_state({"state": False})["brightness"])
        for response in ({"state": "false"}, {"state": True, "dimming": 101},
                         {"state": True, "r": True, "g": 2, "b": 3}):
            with self.assertRaises(wiz.WizError):
                wiz.normalize_state(response)

    def test_cli_json_and_exit_codes(self):
        for argv, expected in ((["--ip", "bad", "status"], 2),
                               (["--ip", "127.0.0.1", "rgb", "1"], 2)):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(wiz.main(argv), expected)
            self.assertFalse(json.loads(stdout.getvalue())["ok"])
            self.assertTrue(stderr.getvalue())
        with Bulb(power=False) as bulb:
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(wiz.main(["--ip", "127.0.0.1", "--port", str(bulb.port), "status"]), 0)
            self.assertFalse(json.loads(stdout.getvalue())["state"]["power"])


if __name__ == "__main__":
    unittest.main()
