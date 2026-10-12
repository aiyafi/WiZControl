#!/usr/bin/env python3
"""On-demand WiZ UDP client. Stdout is exactly one JSON result; no daemon."""

import argparse
import ipaddress
import json
import re
import socket
import sys
import time

# Mapping verified against pywizlight/scenes.py. Availability is bulb-specific.
SCENES = {6: "Cozy", 12: "Daylight", 14: "Night light", 15: "Focus",
          16: "Relax", 18: "TV time", 1: "Ocean", 5: "Fireplace", 29: "Candlelight"}


class WizError(Exception):
    def __init__(self, code, message, state=None, device_error=None):
        super().__init__(message)
        self.code = code
        self.state = state
        self.device_error = device_error


def device_rejection(method, error):
    detail = error if isinstance(error, dict) else {"message": str(error)}
    detail = {key: detail[key] for key in ("code", "message") if key in detail}
    code = f" (code {detail['code']})" if "code" in detail else ""
    message = f": {detail['message']}" if "message" in detail else ""
    return WizError("rejected", f"Bulb rejected {method}{code}{message}.", device_error=detail)


def integer(value, low, high, name):
    if type(value) is not int or not low <= value <= high:
        raise WizError("validation", f"{name} must be an integer from {low} to {high}.")
    return value


def mac_address(value):
    if not isinstance(value, str):
        raise WizError("validation", "Expected MAC must be text.")
    value = re.sub(r"[:-]", "", value).lower()
    if not re.fullmatch(r"[0-9a-f]{12}", value):
        raise WizError("validation", "Expected MAC must contain 12 hexadecimal digits.")
    return value


def normalize_state(result):
    if type(result.get("state")) is not bool:
        raise WizError("protocol", "Status response is missing a boolean power state.")
    state = {"power": result["state"], "mode": "unknown", "rgb": None,
             "temperature": None, "brightness": None, "scene_id": None}
    for key, output, low, high in (("dimming", "brightness", 0, 100),
                                  ("temp", "temperature", 0, 10000),
                                  ("sceneId", "scene_id", 0, 1000)):
        if key in result:
            state[output] = integer(result[key], low, high, key)
    if state["temperature"] == 0:
        state["temperature"] = None
    if state["scene_id"]:
        state["mode"] = "scene"
    elif all(key in result for key in ("r", "g", "b")):
        state["rgb"] = [integer(result[key], 0, 255, key) for key in ("r", "g", "b")]
        state["mode"] = "rgb"
    elif state["temperature"] is not None:
        state["mode"] = "temperature"
    return state


class Client:
    def __init__(self, ip, port=38899, timeout=0.65, retries=1, expected_mac=""):
        try:
            address = ipaddress.IPv4Address(ip)
        except ipaddress.AddressValueError as exc:
            raise WizError("validation", "Enter a valid bulb IPv4 address.") from exc
        if address.is_multicast or address.is_unspecified or int(address) == 0xffffffff:
            raise WizError("validation", "Use a unicast bulb address, not broadcast or multicast.")
        self.address = (str(address), integer(port, 1, 65535, "port"))
        if not 0.05 <= timeout <= 3:
            raise WizError("validation", "Timeout must be from 0.05 to 3 seconds.")
        self.timeout = timeout
        self.retries = integer(retries, 0, 2, "retries")
        self.expected_mac = mac_address(expected_mac) if expected_mac else ""

    def request(self, method, params=None):
        payload = json.dumps({"method": method, "params": params or {}},
                             separators=(",", ":")).encode()
        # A fresh socket per exchange prevents late same-method replies crossing requests.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            for _ in range(self.retries + 1):
                try:
                    sock.sendto(payload, self.address)
                    deadline = time.monotonic() + self.timeout
                    while time.monotonic() < deadline:
                        sock.settimeout(max(0.001, deadline - time.monotonic()))
                        data, source = sock.recvfrom(8192)
                        if source != self.address:
                            continue
                        try:
                            response = json.loads(data)
                        except (ValueError, UnicodeError) as exc:
                            raise WizError("protocol", "Bulb returned malformed JSON.") from exc
                        if not isinstance(response, dict):
                            raise WizError("protocol", "Bulb response must be a JSON object.")
                        if response.get("method") != method:
                            continue
                        if response.get("error") is not None:
                            raise device_rejection(method, response["error"])
                        result = response.get("result")
                        if not isinstance(result, dict):
                            raise WizError("protocol", "Bulb response is missing a result object.")
                        if result.get("error") is not None:
                            raise device_rejection(method, result["error"])
                        return result
                except socket.timeout:
                    continue
                except OSError as exc:
                    raise WizError("network", "Cannot reach the bulb over UDP.") from exc
        raise WizError("timeout", "No reply from bulb. Check its IP, power and Allow local setting.")

    def status(self):
        result = self.request("getPilot")
        if self.expected_mac:
            try:
                matches = mac_address(result.get("mac", "")) == self.expected_mac
            except WizError:
                matches = False
            if not matches:
                raise WizError("identity", "Bulb identity does not match the configured MAC.")
        return normalize_state(result)

    def capabilities(self):
        """Read normal CCT range, never infer capabilities from cached pilot values."""
        for method in ("getModelConfig", "getUserConfig"):
            try:
                result = self.request(method)
            except WizError as exc:
                if exc.code in ("timeout", "rejected", "protocol", "network"):
                    continue
                raise
            for key in ("cctRange", "extRange", "whiteRange"):
                values = result.get(key)
                if not isinstance(values, list) or len(values) not in (2, 4):
                    continue
                low, high = values[1:3] if len(values) == 4 else values
                if type(low) is int and type(high) is int and 1000 <= low < high <= 10000:
                    return {"temperature_min": low, "temperature_max": high}
        return {"temperature_min": None, "temperature_max": None}

    def execute(self, action, values=(), inspect=False, min_kelvin=None, max_kelvin=None,
                supported_scenes=()):
        # Validate every argument before any state-changing datagram can be sent.
        counts = {"rgb": 3, "brightness": 1, "temperature": 1, "scene": 1, "scene-test": 1}
        if len(values) != counts.get(action, 0):
            raise WizError("validation", "Wrong number of action values.")
        params = {}
        if action == "rgb":
            if len(values) != 3:
                raise WizError("validation", "RGB requires three channels.")
            params = dict(zip(("r", "g", "b"),
                              [integer(v, 0, 255, "RGB channel") for v in values]))
            # RGB(W) selects color mode itself. temp=0 is an invalid CCT command,
            # not a way to clear white mode. Do not mix it with scene parameters.
            params["w"] = 0
        elif action == "brightness":
            params = {"dimming": integer(values[0], 1, 100, "brightness")}
        elif action == "temperature":
            integer(values[0], 1000, 10000, "temperature")
            if (min_kelvin is None) != (max_kelvin is None):
                raise WizError("validation", "Supply both verified Kelvin limits.")
            if min_kelvin is not None:
                integer(min_kelvin, 1000, 10000, "minimum Kelvin")
                integer(max_kelvin, min_kelvin + 1, 10000, "maximum Kelvin")
            params = {"temp": values[0]}
        elif action in ("scene", "scene-test"):
            scene = integer(values[0], 1, 1000, "scene ID")
            if scene not in SCENES:
                raise WizError("validation", "Unknown built-in scene ID.")
            if action == "scene" and scene not in supported_scenes:
                raise WizError("validation", "Scene is unverified; use the explicit scene-test action first.")
            params = {"sceneId": scene}
        elif action in ("on", "off"):
            params = {"state": action == "on"}
        elif action != "status":
            raise WizError("validation", "Unknown action.")

        state = self.status()
        if action == "status":
            output = {"ok": True, "state": state}
            if inspect:
                output["capabilities"] = self.capabilities()
            return output
        if action not in ("on", "off") and not state["power"]:
            raise WizError("off", "Light is off; turn it on before changing controls.", state)
        if action == "temperature":
            if min_kelvin is None:
                caps = self.capabilities()
                min_kelvin, max_kelvin = caps["temperature_min"], caps["temperature_max"]
            if min_kelvin is None or max_kelvin is None:
                raise WizError("unsupported", "CCT range unknown. Set verified Kelvin limits in settings.", state)
            integer(values[0], min_kelvin, max_kelvin, "temperature")
        try:
            ack = self.request("setPilot", params)
            if ack.get("success") is False:
                raise device_rejection("setPilot", {key: ack[key] for key in ("code", "message") if key in ack}
                                       or {"message": "success=false; no device error detail supplied"})
            if ack.get("success") is not True:
                raise WizError("protocol", "setPilot reply is missing a boolean success acknowledgement.")
        except WizError as exc:
            if exc.code == "rejected":
                exc.state = state
            raise
        # Power is finalized only after readback. Never restore cached UI settings on ON.
        for attempt in range(3):
            state = self.status()
            matched = (state["power"] == params["state"] if action in ("on", "off")
                       else state["power"] and state["scene_id"] == values[0]
                       if action in ("scene", "scene-test") else True)
            if matched:
                output = {"ok": True, "state": state}
                if action in ("scene", "scene-test"):
                    output["verified_scene"] = values[0]
                return output
            if attempt < 2:
                time.sleep(0.08)
        raise WizError("unconfirmed", "Command acknowledged, but requested state was not confirmed.", state)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise WizError("validation", message)


def main(argv=None):
    parser = Parser(description=__doc__)
    parser.add_argument("--ip", required=True)
    parser.add_argument("--port", type=int, default=38899)
    parser.add_argument("--timeout", type=float, default=0.65)
    parser.add_argument("--retries", type=int, default=1)
    parser.add_argument("--expected-mac", default="")
    parser.add_argument("--inspect", action="store_true", help="read CCT capabilities with status")
    parser.add_argument("--min-kelvin", type=int)
    parser.add_argument("--max-kelvin", type=int)
    parser.add_argument("--supported-scenes", default="", help="comma-separated verified scene IDs")
    parser.add_argument("action", choices=("status", "on", "off", "rgb", "brightness", "temperature", "scene", "scene-test"))
    parser.add_argument("values", nargs="*", type=int)
    try:
        args = parser.parse_args(argv)
        counts = {"rgb": 3, "brightness": 1, "temperature": 1, "scene": 1, "scene-test": 1}
        if len(args.values) != counts.get(args.action, 0):
            raise WizError("validation", "Wrong number of action values.")
        try:
            scenes = [int(v.strip()) for v in args.supported_scenes.split(",") if v.strip()]
        except ValueError as exc:
            raise WizError("validation", "Supported scenes must be comma-separated numeric IDs.") from exc
        client = Client(args.ip, args.port, args.timeout, args.retries, args.expected_mac)
        output = client.execute(args.action, args.values, args.inspect,
                                args.min_kelvin, args.max_kelvin, scenes)
        code = 0
    except WizError as exc:
        output = {"ok": False, "error": {"code": exc.code, "message": str(exc)}}
        if exc.device_error is not None:
            output["error"]["device_error"] = exc.device_error
        if exc.state is not None:
            output["state"] = exc.state
        print(str(exc), file=sys.stderr)
        code = {"validation": 2, "timeout": 3, "network": 3, "identity": 4,
                "protocol": 4, "off": 5, "unsupported": 5, "rejected": 5,
                "unconfirmed": 5}.get(exc.code, 1)
    print(json.dumps(output, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
