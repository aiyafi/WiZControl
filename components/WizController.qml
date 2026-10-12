import QtQuick
import Quickshell.Io

// One subprocess in flight, one latest desired value, no background service.
Item {
    id: root

    property string bulbIp: ""
    property string expectedMac: ""
    property string verifiedScenes: ""
    property var sceneChecks: ({})
    property int configuredMin: 0
    property int configuredMax: 0
    property string helperPath: Qt.resolvedUrl("../scripts/wiz_udp.py").toString().replace(/^file:\/\//, "")
    property int port: 38899
    property bool active: false
    property bool online: false
    property var power: null
    property var state: ({})
    property string errorMessage: ""
    property string errorCode: ""
    property var deviceError: null
    property string infoMessage: ""
    property bool busy: false
    property bool powerPending: false
    property bool dragging: false
    property var queued: null
    property int revision: 0
    property int generation: 0
    property var request: null
    property bool refreshNeeded: false
    property bool inspected: false
    property var observedScenes: []
    property var testedScenes: []
    property var unsupportedScenes: []
    property var sceneFailureReasons: ({})
    property int reportedMin: 0
    property int reportedMax: 0
    property real hue: 0
    property real saturation: 0
    property bool hasColor: false
    property int brightness: 50
    property int temperature: 0
    property string previewMode: "unknown"

    readonly property bool manualRange: configuredMin !== 0 || configuredMax !== 0
    readonly property int minKelvin: manualRange ? configuredMin : reportedMin
    readonly property int maxKelvin: manualRange ? configuredMax : reportedMax
    readonly property bool hasCct: minKelvin >= 1000 && maxKelvin <= 10000 && maxKelvin > minKelvin
    readonly property bool sceneTesting: busy && request?.action === "scene-test"
    readonly property bool controlsEnabled: active && online && power === true && !powerPending && !sceneTesting
    readonly property bool powerEnabled: active && online && power !== null && !busy && !queued && !dragging
    readonly property bool pending: powerPending || queued !== null || (busy && request?.action !== "status")
    readonly property string connectionState: pending ? "pending" : busy && !online ? "loading"
        : !online ? (errorMessage ? "offline" : "unknown") : power ? "online-on" : "online-off"
    readonly property var supportedScenes: {
        const configured = verifiedScenes.split(",").map(v => Number(v.trim())).filter(v => v > 0);
        return configured.concat(observedScenes, testedScenes).filter(id => !sceneUnavailable(id));
    }
    readonly property string sceneDeviceKey: bulbIp.trim() + "|" + expectedMac.replace(/[:-]/g, "").toLowerCase()
    signal sceneChecksUpdated(var checks)

    function sceneSupported(id) { return supportedScenes.indexOf(id) !== -1; }
    function sceneUnavailable(id) { return unsupportedScenes.indexOf(id) !== -1; }
    function sceneStatus(id) { return sceneUnavailable(id) ? "Unsupported" : sceneSupported(id) ? "Verified" : "Not Tested"; }
    function sceneUnavailableReason(id) { return sceneFailureReasons[String(id)] || "This bulb rejected the scene."; }

    function restoreSceneChecks() {
        // DMS settings may arrive as QVariant lists rather than JavaScript arrays.
        const record = JSON.parse(JSON.stringify(sceneChecks || {}));
        const saved = record.device === sceneDeviceKey ? record : {};
        testedScenes = Array.isArray(saved.verified) ? saved.verified.slice() : [];
        unsupportedScenes = Array.isArray(saved.unsupported) ? saved.unsupported.slice() : [];
        sceneFailureReasons = saved.reasons && typeof saved.reasons === "object" ? saved.reasons : {};
    }

    function saveSceneChecks() {
        sceneChecksUpdated({device: sceneDeviceKey, verified: testedScenes.slice(), unsupported: unsupportedScenes.slice(),
                            reasons: Object.assign({}, sceneFailureReasons)});
    }

    function rememberScene(id) {
        if (!(id > 0))
            return;
        const changed = testedScenes.indexOf(id) === -1 || sceneUnavailable(id);
        if (testedScenes.indexOf(id) === -1)
            testedScenes = testedScenes.concat([id]);
        unsupportedScenes = unsupportedScenes.filter(value => value !== id);
        if (sceneFailureReasons[String(id)]) {
            const reasons = Object.assign({}, sceneFailureReasons);
            delete reasons[String(id)];
            sceneFailureReasons = reasons;
        }
        if (changed)
            saveSceneChecks();
    }

    function resetConnection() {
        generation++;
        revision++;
        queued = null;
        dragging = false;
        online = false;
        power = null;
        powerPending = false;
        errorMessage = "";
        errorCode = "";
        deviceError = null;
        infoMessage = "";
        state = {};
        inspected = false;
        observedScenes = [];
        restoreSceneChecks();
        reportedMin = reportedMax = 0;
        hasColor = false;
        previewMode = "unknown";
        refreshNeeded = active;
        Qt.callLater(refresh);
    }

    onBulbIpChanged: resetConnection()
    onExpectedMacChanged: resetConnection()
    onSceneChecksChanged: {
        observedScenes = [];
        restoreSceneChecks();
    }
    onSceneDeviceKeyChanged: restoreSceneChecks()
    Component.onCompleted: restoreSceneChecks()
    onConfiguredMinChanged: resetConnection()
    onConfiguredMaxChanged: resetConnection()
    onActiveChanged: {
        revision++;
        dragging = false;
        if (active) {
            // A hidden bar value is last-known, never enough to enable a reopened popup.
            online = false;
            refreshNeeded = true;
            refresh();
        } else {
            queued = null;
            coalesce.stop();
            refreshNeeded = false;
        }
    }

    function refresh() {
        if (!active || busy || queued || dragging)
            return;
        if (!bulbIp.trim()) {
            errorMessage = "Set the bulb IPv4 address in DMS → Plugins → WiZ Control settings.";
            online = false;
            return;
        }
        refreshNeeded = false;
        launch("status", [], !inspected);
    }

    function togglePower() {
        if (!powerEnabled)
            return;
        queued = null;
        revision++;
        errorMessage = infoMessage = errorCode = "";
        deviceError = null;
        powerPending = true;
        launch(power ? "off" : "on", [], false);
    }

    function beginDrag() {
        if (controlsEnabled)
            dragging = true;
    }

    function setColor(h, s, finalValue) {
        if (!controlsEnabled || !isFinite(h) || !isFinite(s))
            return;
        hue = Math.max(0, Math.min(1, h));
        saturation = Math.max(0, Math.min(1, s));
        hasColor = true;
        previewMode = "rgb";
        const c = Qt.hsva(hue, saturation, 1, 1);
        queueControl("rgb", [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255)], finalValue);
    }

    function setBrightness(value, finalValue) {
        if (!controlsEnabled)
            return;
        brightness = Math.max(1, Math.min(100, Math.round(value)));
        queueControl("brightness", [brightness], finalValue);
    }

    function setTemperature(value, finalValue) {
        if (!controlsEnabled || !hasCct)
            return;
        temperature = Math.max(minKelvin, Math.min(maxKelvin, Math.round(value)));
        previewMode = "temperature";
        queueControl("temperature", [temperature], finalValue);
    }

    function setScene(id) {
        if (!controlsEnabled || pending || !sceneSupported(id))
            return;
        queueControl("scene", [id], true);
    }

    // The UI asks explicitly before calling this: one scene, no automatic sweep.
    function testScene(id, retry) {
        if (!controlsEnabled || busy || pending || dragging || (!retry && (sceneSupported(id) || sceneUnavailable(id))))
            return;
        revision++;
        errorMessage = infoMessage = errorCode = "";
        deviceError = null;
        launch("scene-test", [id], false);
    }

    function queueControl(action, values, finalValue) {
        if (!controlsEnabled)
            return;
        revision++;
        queued = {action: action, values: values};
        errorMessage = "";
        errorCode = "";
        deviceError = null;
        infoMessage = "";
        if (finalValue) {
            dragging = false;
            coalesce.stop();
            flush();
        } else if (!coalesce.running) {
            coalesce.start();
        }
    }

    function flush() {
        if (!queued || busy || !controlsEnabled)
            return;
        const next = queued;
        queued = null;
        launch(next.action, next.values, false);
    }

    function launch(action, values, inspect) {
        if (busy || !active)
            return;
        if (action !== "status" && action !== "on" && action !== "off" && !controlsEnabled)
            return;
        if ((action === "on" || action === "off") && (!online || power === null))
            return;
        const argv = ["python3", helperPath, "--ip", bulbIp.trim(), "--port", String(port)];
        if (expectedMac.trim())
            argv.push("--expected-mac", expectedMac.trim());
        if (inspect)
            argv.push("--inspect");
        if (action === "temperature")
            argv.push("--min-kelvin", String(minKelvin), "--max-kelvin", String(maxKelvin));
        if (action === "scene")
            argv.push("--supported-scenes", supportedScenes.join(","));
        request = {action: action, values: values, revision: revision, generation: generation, inspect: inspect};
        busy = true;
        output = "";
        outputReady = false;
        exitReady = false;
        exitCode = -1;
        process.command = argv.concat([action], values.map(v => String(v)));
        process.running = true;
        watchdog.restart();
    }

    function syncState(next, syncControls) {
        state = next;
        online = true;
        power = next.power;
        if (next.scene_id > 0 && !sceneSupported(next.scene_id))
            observedScenes = observedScenes.concat([next.scene_id]);
        rememberScene(next.scene_id);
        if (!power) {
            queued = null;
            dragging = false;
            coalesce.stop();
        }
        if (!syncControls)
            return;
        previewMode = next.mode;
        hasColor = next.mode === "rgb" && next.rgb !== null;
        if (hasColor) {
            const c = Qt.rgba(next.rgb[0] / 255, next.rgb[1] / 255, next.rgb[2] / 255, 1);
            // Normalize RGB value away: the field represents hue/saturation, not brightness.
            hue = Math.max(0, c.hsvHue);
            saturation = c.hsvSaturation;
        }
        if (next.brightness !== null)
            brightness = Math.max(1, next.brightness);
        if (next.temperature !== null)
            temperature = next.temperature;
    }

    function finish() {
        if (!exitReady || !outputReady || !busy)
            return;
        watchdog.stop();
        const previous = request;
        busy = false;
        powerPending = false;
        if (previous.generation !== generation) {
            if (active)
                refresh();
            return;
        }
        let reply;
        try { reply = JSON.parse(output); } catch (_) { reply = null; }
        const validState = reply?.state && typeof reply.state.power === "boolean";
        if (validState)
            syncState(reply.state, !dragging && !queued && previous.revision === revision);
        if (!reply || !reply.ok || exitCode !== 0) {
            errorMessage = reply?.error?.message || "WiZ helper failed. Check Python 3 and the plugin files.";
            errorCode = reply?.error?.code || "protocol";
            deviceError = reply?.error?.device_error || null;
            infoMessage = "";
            if (!validState)
                online = false;
            queued = null;
            dragging = false;
            coalesce.stop();
            if (validState)
                syncState(reply.state, true);
            if ((previous.action === "scene-test" || previous.action === "scene") && errorCode === "rejected"
                    && validState && reply.state.scene_id !== previous.values[0]) {
                const id = previous.values[0];
                testedScenes = testedScenes.filter(value => value !== id);
                if (!sceneUnavailable(id))
                    unsupportedScenes = unsupportedScenes.concat([id]);
                const reasons = Object.assign({}, sceneFailureReasons);
                reasons[String(id)] = errorMessage;
                sceneFailureReasons = reasons;
                saveSceneChecks();
            }
        } else {
            if (previous.action !== "status" || ["timeout", "network", "identity", "protocol"].indexOf(errorCode) !== -1) {
                errorMessage = errorCode = "";
                deviceError = null;
            }
            if (previous.action === "scene-test" && reply.verified_scene === previous.values[0]) {
                rememberScene(reply.verified_scene);
                infoMessage = "Scene verified and saved. Select it normally next time.";
            }
            if (reply.capabilities) {
                reportedMin = reply.capabilities.temperature_min || 0;
                reportedMax = reply.capabilities.temperature_max || 0;
                inspected = true;
            }
        }
        if (queued && !coalesce.running)
            Qt.callLater(flush);
        else if (refreshNeeded && active)
            Qt.callLater(refresh);
        else if (active && previous.revision !== revision && !dragging && !queued)
            Qt.callLater(refresh);
    }

    property string output: ""
    property bool outputReady: false
    property bool exitReady: false
    property int exitCode: -1

    Process {
        id: process
        stdout: StdioCollector {
            onStreamFinished: { root.output = text; root.outputReady = true; root.finish(); }
        }
        stderr: StdioCollector {} // Diagnostics are surfaced once through structured stdout.
        onExited: (code, status) => { root.exitCode = code; root.exitReady = true; root.finish(); }
    }
    Timer {
        id: watchdog
        interval: 12000
        onTriggered: {
            process.running = false;
            // A failed process start may not emit exited or streamFinished.
            root.output = '{"ok":false,"error":{"message":"WiZ helper timed out. Check Python 3, then Retry."}}';
            root.outputReady = true;
            root.exitReady = true;
            root.exitCode = 124;
            root.finish();
        }
    }
    Timer {
        id: coalesce
        interval: 200
        onTriggered: root.flush()
    }
    Timer {
        interval: 4000
        repeat: true
        running: root.active
        onTriggered: root.refresh()
    }
}
