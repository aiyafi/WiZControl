import QtQuick
import QtQuick.Window
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.Common
import qs.DankCommon.Common as DC

// Executed by validate_qml.py in an isolated preview using installed DMS imports.
ShellRoot {
    id: test
    property var widget: null
    property var settings: null
    property var popup: null
    property var control: null
    property var nativePopout: null
    property int step: -1
    property int ticks: 0
    property var results: []
    property bool swatchDone: false
    property bool verifiedClickDone: false
    property bool testedClickDone: false
    property bool confirmationCaptureStarted: false
    property bool confirmationCaptured: false
    property bool settingsCaptureStarted: false
    property bool settingsCaptured: false

    Window {
        id: window
        width: 420
        height: 600
        title: "WiZ Control — mocked validation"
        visible: true
        color: "#202020"
    }

    function require(condition, message) {
        if (!condition)
            throw new Error(message);
    }
    function find(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    function complete(message) {
        results.push(message);
        console.log("CHECK:", message);
        ticks = 0;
        step++;
    }
    function findScene(item, id, name) {
        const objectName = name || "sceneButton";
        if (item.objectName === objectName && item.modelData.id === id) return item;
        for (const child of item.children || []) {
            const found = findScene(child, id, objectName);
            if (found) return found;
        }
        return null;
    }
    function create(file, parent, properties) {
        const component = Qt.createComponent("file://" + Quickshell.env("WIZ_PLUGIN_DIR") + "/" + file);
        require(component.status === Component.Ready, component.errorString());
        const object = component.createObject(parent, properties || {});
        require(object !== null, component.errorString());
        return object;
    }

    Component.onCompleted: {
        try {
            DC.Style.theme = Theme;
            DC.Style.settings = SettingsData;
            DC.I18n.backend = I18n;
            DC.Paths.backend = Paths;
            DC.Log.backend = Log;
            widget = create("WiZWidget.qml", window.contentItem);
            widget.pluginId = "wizControl";
            widget.pluginService = PluginService;
            PluginService.savePluginData("wizControl", "bulbIp", "127.0.0.1");
            settings = create("Settings.qml", window.contentItem, {width: 400, visible: false, pluginService: PluginService});
            control = find(widget, "wizController");
            require(control !== null, "Controller missing");
            control.port = Number(Quickshell.env("WIZ_TEST_PORT"));
            widget.parentScreen = Quickshell.screens[0];
            nativePopout = widget.children.find(child => child.pluginContent !== undefined);
            require(nativePopout !== undefined, "Native plugin popout missing");
            widget.triggerPopout();
        } catch (error) {
            console.error("FAIL:", error.message);
            Qt.callLater(Qt.quit);
        }
    }

    Timer {
        interval: 25
        repeat: true
        running: test.widget !== null
        onTriggered: {
            try {
                test.ticks++;
                test.require(test.ticks < 600, "Timed out at step " + test.step + " active=" + test.control.active
                    + " busy=" + test.control.busy + " state=" + JSON.stringify(test.control.state) + " error=" + test.control.errorMessage);
                switch (test.step) {
                case -1:
                    if (!test.nativePopout.contentLoader.item) return;
                    test.popup = test.find(test.nativePopout.contentLoader.item, "wizPopout");
                    if (!test.popup) return;
                    test.require(test.nativePopout.shouldBeVisible && test.control.active, "Native popout did not activate controller");
                    test.complete("Native DMS bar pill opens its real PluginPopout and activates polling");
                    break;
                case 0:
                    if (test.control.busy || !test.control.online) return;
                    test.require(test.control.connectionState === "online-off", "OFF mistaken for offline");
                    test.require(!test.find(test.popup, "connectionFeedback").visible && !test.find(test.popup, "retryButton").visible,
                        "Routine connected footer still shown");
                    test.require(!test.find(test.popup, "lightControls").enabled, "OFF controls enabled");
                    test.require(!test.find(test.popup, "verifyScenesButton"), "Verify scenes button still shown");
                    for (const name of ["colorSpectrum", "brightnessSlider", "temperatureSlider", "lightTabs", "colorSwatch", "sceneButton", "sceneTestDialog"])
                        test.require(!test.find(test.popup, name).enabled, name + " accepts OFF events");
                    test.require(test.find(test.popup, "powerButton").enabled, "Power unavailable while online-off");
                    test.require(test.control.minKelvin === 2700 && test.control.maxKelvin === 6500, "Wrong CCT capability range");
                    test.require(test.popup.implicitHeight > 400 && test.popup.implicitHeight <= 600, "Popup geometry invalid");
                    test.control.setColor(0.8, 0.7, true);
                    test.control.setBrightness(40, true);
                    test.control.setTemperature(3000, true);
                    test.control.setScene(6);
                    test.control.testScene(6);
                    test.control.testScene(6, true);
                    test.popup.requestSceneTest(6);
                    test.popup.sceneToTest = 6;
                    test.popup.confirmSceneTest();
                    test.require(test.settings.sceneController === test.control, "Settings created a separate controller");
                    test.settings.visible = true;
                    test.find(test.settings, "advancedSection").expanded = true;
                    test.find(test.settings, "sceneCompatibilitySection").expanded = true;
                    test.require(!test.find(test.settings, "retrySceneButton").enabled, "OFF advanced retry enabled");
                    test.require(!test.find(test.settings, "resetSceneChecksButton").enabled, "OFF reset enabled");
                    test.settings.requestSceneRetry(6);
                    test.settings.sceneToRetry = 6;
                    test.settings.confirmSceneRetry();
                    test.settings.resetSceneChecks();
                    test.find(test.settings, "advancedSection").expanded = false;
                    test.settings.visible = false;
                    test.find(test.popup, "colorSpectrum").selected(0.8, 0.7, true);
                    test.find(test.popup, "brightnessSlider").sliderValueChanged(40);
                    test.find(test.popup, "temperatureSlider").sliderValueChanged(3000);
                    test.find(test.popup, "colorSwatch").select();
                    test.find(test.popup, "sceneButton").clicked();
                    test.find(test.popup, "lightTabs").tabClicked(1);
                    test.require(test.popup.selectedTab === 0, "OFF tab handler active");
                    test.require(!test.control.busy && !test.control.queued, "Disabled handler queued a write");
                    test.complete("Actual DMS widget/settings load; OFF controls and invoked handlers disabled");
                    break;
                case 1:
                    test.control.togglePower();
                    test.control.togglePower();
                    test.require(test.control.powerPending, "Power pending not exposed");
                    test.require(test.control.power === false, "Power switched optimistically");
                    test.require(!test.find(test.popup, "lightControls").enabled, "Pending power did not disable controls");
                    test.complete("Power remains confirmed-OFF until ACK plus status; duplicate click blocked");
                    break;
                case 2:
                    if (test.control.busy) return;
                    test.require(test.control.power === true && test.control.online, test.control.errorMessage);
                    test.require(test.find(test.popup, "lightControls").enabled, "Controls not enabled after ON readback");
                    if (!test.verifiedClickDone) {
                        test.findScene(test.popup, 12).clicked();
                        test.require(test.control.busy && test.control.request.action === "scene" && !test.popup.sceneDialog.visible,
                            "Verified scene did not activate with one click");
                        test.verifiedClickDone = true;
                        return;
                    }
                    test.require(!test.control.sceneSupported(6), "Unverified scene was enabled");
                    test.control.setScene(6);
                    test.require(!test.control.busy, "Unverified scene launched a command");
                    const revision = test.control.revision;
                    test.control.setColor(NaN, 1, true);
                    test.find(test.popup, "colorSpectrum").choose(Infinity, 10, true);
                    test.require(test.control.revision === revision, "Nonfinite RGB input queued a write");
                    test.control.refresh();
                    test.control.beginDrag();
                    for (let i = 0; i < 80; i++) test.control.setColor(i / 100, 0.73, false);
                    test.complete("Verified scenes gated; drag started during an in-flight poll");
                    break;
                case 3:
                    if (test.control.busy || test.ticks < 12) return;
                    test.require(test.control.hue === 0.79 && test.control.saturation === 0.73, "Stale poll overwrote drag preview");
                    test.find(test.popup, "colorSpectrum").selected(0.78, 0.73, true);
                    test.complete("Poll does not overwrite local drag; 80 moves coalesced and final value flushed");
                    break;
                case 4:
                    if (test.control.busy || test.control.queued) return;
                    test.require(test.control.state.mode === "rgb", test.control.errorMessage);
                    test.popup.grabToImage(result => {
                        result.saveToFile(Quickshell.env("WIZ_TEST_SCREENSHOT") + ".color.png");
                        test.find(test.popup, "colorSwatch").select();
                    });
                    test.complete("RGB readback confirmed");
                    break;
                case 5:
                    if (test.control.busy) return;
                    if (!test.swatchDone) {
                        if (!test.control.state.rgb || test.control.state.rgb[0] !== 255) return;
                        test.require(test.control.state.rgb.every(value => value === 255), "White swatch readback incorrect");
                        test.control.setTemperature(3000, true);
                        test.swatchDone = true;
                        return;
                    }
                    if (test.control.state.temperature !== 3000) return;
                    test.require(test.control.state.temperature === 3000, test.control.errorMessage);
                    test.require(!test.control.hasColor, "CCT fabricated an RGB marker");
                    test.find(test.popup, "brightnessSlider").sliderDragFinished(31);
                    test.complete("CCT range-constrained readback; RGB marker cleared in white mode");
                    break;
                case 6:
                    if (test.control.busy) return;
                    test.require(test.control.state.brightness === 31, test.control.errorMessage);
                    test.require(test.find(test.popup, "brightnessSlider").value === 31, "Slider binding lost after edit");
                    test.popup.selectedTab = 1;
                    if (!test.confirmationCaptureStarted) {
                        test.require(test.findScene(test.popup, 6).enabled, "Untested scene not selectable");
                        test.findScene(test.popup, 6).clicked();
                        test.popup.sceneDialog.grabToImage(result => {
                            result.saveToFile(Quickshell.env("WIZ_TEST_SCREENSHOT") + ".confirmation.png");
                            test.confirmationCaptured = true;
                        });
                        test.confirmationCaptureStarted = true;
                        return;
                    }
                    if (!test.confirmationCaptured) return;
                    test.require(test.popup.sceneToTest === 6 && test.popup.sceneDialog.visible && !test.control.busy,
                        "Unverified scene did not ask before changing the lamp");
                    test.require(test.popup.sceneDialog.confirmButtonText === "Test & Enable"
                        && test.popup.sceneDialog.cancelButtonText === "Cancel", "Wrong first-use confirmation choices");
                    test.popup.sceneDialog._activate(0);
                    test.require(test.popup.sceneToTest === 0 && !test.control.busy, "Cancelled scene test launched a write");
                    test.findScene(test.popup, 6).clicked();
                    test.popup.sceneDialog._activate(1);
                    test.require(test.control.sceneTesting && !test.control.controlsEnabled, "Scene test not serialized");
                    test.complete("Brightness uses raw percent and keeps its readback binding");
                    break;
                case 7:
                    if (test.control.busy) return;
                    test.require(test.control.state.scene_id === 6, test.control.errorMessage);
                    if (test.control.state.brightness !== 64) return;
                    test.require(test.find(test.popup, "brightnessSlider").value === 64, "External change did not resync slider");
                    if (!test.testedClickDone) {
                        const saved = PluginService.loadPluginData("wizControl", "sceneChecks", {});
                        test.require(saved.verified.includes(6), "Tested scene not persisted through DMS settings API");
                        const restored = test.create("components/WizController.qml", window.contentItem,
                            {bulbIp: "127.0.0.1", sceneChecks: saved});
                        test.require(restored.sceneSupported(6), "Verified scene lost on controller reload");
                        restored.observedScenes = [6];
                        restored.sceneChecks = {};
                        test.require(!restored.sceneSupported(6), "Reset scene checks retained stale observations");
                        restored.sceneChecks = saved;
                        restored.bulbIp = "127.0.0.2";
                        test.require(!restored.sceneSupported(6), "Scene checks leaked to another configured bulb");
                        restored.destroy();
                        test.findScene(test.popup, 6).clicked();
                        test.require(test.control.request.action === "scene" && !test.popup.sceneDialog.visible,
                            "Successfully tested scene asked for confirmation again");
                        test.testedClickDone = true;
                        return;
                    }
                    test.findScene(test.popup, 5).clicked();
                    test.popup.sceneDialog._activate(1);
                    test.complete("Verified scenes are one-click; first-use confirmation persists and survives reload");
                    break;
                case 8:
                    if (test.control.busy) return;
                    test.require(test.control.sceneUnavailable(5) && !test.findScene(test.popup, 5).enabled, "Rejected scene not disabled");
                    test.require(PluginService.loadPluginData("wizControl", "sceneChecks", {}).unsupported.includes(5), "Rejected scene not saved");
                    test.require(test.control.online && test.control.errorCode === "rejected", "Scene rejection treated as offline");
                    test.require(test.control.sceneUnavailableReason(5).includes("Unsupported scene"), "Scene rejection reason not saved");
                    test.findScene(test.popup, 5).clicked();
                    test.require(!test.popup.sceneDialog.visible && !test.control.busy, "Unsupported tile started a normal activation");
                    test.control.testScene(5);
                    test.require(!test.control.busy, "Known rejected scene retested without reset");
                    test.settings.visible = true;
                    test.find(test.settings, "advancedSection").expanded = true;
                    test.find(test.settings, "sceneCompatibilitySection").expanded = true;
                    test.require(test.findScene(test.settings, 6, "sceneCompatibilityRow").verificationStatus === "Verified", "Verified status missing");
                    test.require(test.findScene(test.settings, 14, "sceneCompatibilityRow").verificationStatus === "Not Tested", "Not Tested status missing");
                    const row = test.findScene(test.settings, 5, "sceneCompatibilityRow");
                    test.require(row.verificationStatus === "Unsupported", "Unsupported status missing");
                    test.widget.closePopout();
                    test.require(test.control.active && test.widget.sceneSettingsActive, "Advanced Settings cannot use the closed widget's controller");
                    test.find(row, "retrySceneButton").clicked();
                    test.require(test.settings.sceneToRetry === 5 && test.control.sceneUnavailable(5) && !test.control.busy,
                        "Retry erased incompatibility or sent a write without confirmation");
                    test.find(test.settings, "settingsSceneTestContent").buttonActivated(0);
                    test.require(!test.control.busy && test.control.sceneUnavailable(5), "Cancel retried or enabled unsupported scene");
                    test.control.port = Number(Quickshell.env("WIZ_COMPATIBLE_PORT"));
                    test.find(row, "retrySceneButton").clicked();
                    test.find(test.settings, "settingsSceneTestContent").buttonActivated(1);
                    test.complete("Unsupported scenes remain disabled; Advanced lists statuses and explicitly retries one scene");
                    break;
                case 9:
                    if (test.control.busy) return;
                    test.require(test.control.state.scene_id === 5 && test.control.sceneSupported(5), test.control.errorMessage);
                    test.require(!test.control.sceneUnavailable(5) && !test.control.sceneFailureReasons["5"], "Successful retry retained unsupported result");
                    test.require(test.findScene(test.settings, 5, "sceneCompatibilityRow").verificationStatus === "Verified", "Settings did not resync after retry");
                    const retried = PluginService.loadPluginData("wizControl", "sceneChecks", {});
                    test.require(retried.verified.includes(5) && !retried.unsupported.includes(5), "Retry result not persisted");
                    if (!test.settingsCaptureStarted) {
                        test.settings.grabToImage(result => {
                            result.saveToFile(Quickshell.env("WIZ_TEST_SCREENSHOT") + ".settings.png");
                            test.settingsCaptured = true;
                        });
                        test.settingsCaptureStarted = true;
                        return;
                    }
                    if (!test.settingsCaptured) return;
                    test.find(test.settings, "resetSceneChecksButton").clicked();
                    test.require(test.control.sceneStatus(5) === "Not Tested" && test.control.sceneStatus(6) === "Not Tested", "Reset retained saved verification");
                    PluginService.savePluginData("wizControl", "sceneChecks", retried);
                    test.find(test.settings, "advancedSection").expanded = false;
                    test.require(!test.control.active && !test.widget.sceneSettingsActive, "Collapsed Advanced section kept polling alive");
                    test.settings.visible = false;
                    test.control.port = Number(Quickshell.env("WIZ_TEST_PORT"));
                    test.widget.triggerPopout();
                    test.complete("Successful advanced retry updates persistence; reset works; collapsed settings release polling");
                    break;
                case 10:
                    if (!test.nativePopout.contentLoader.item) return;
                    test.popup = test.find(test.nativePopout.contentLoader.item, "wizPopout");
                    if (!test.popup || test.control.busy || !test.control.online) return;
                    test.require(test.control.state.scene_id === 6, "Active scene not resynchronized from hardware");
                    test.require(test.findScene(test.popup, 5).enabled, "Retested scene not available in main grid after reopening");
                    test.control.port = Number(Quickshell.env("WIZ_REJECTED_PORT"));
                    test.find(test.popup, "colorSpectrum").selected(0.66, 1, true);
                    test.complete("Reopening synchronizes active scene and shows the retested scene normally");
                    break;
                case 11:
                    if (test.control.busy) return;
                    test.require(test.control.online && test.control.errorCode === "rejected", "RGB rejection confused with transport failure");
                    test.require(test.find(test.popup, "connectionFeedback").visible && !test.find(test.popup, "retryButton").visible,
                        "Connected error feedback or removed Refresh button incorrect");
                    test.require(test.control.deviceError.code === -32602 && test.control.errorMessage.includes("Invalid params"), "Actual device error not surfaced");
                    test.control.port = Number(Quickshell.env("WIZ_TEST_PORT"));
                    test.control.refresh();
                    test.complete("RGB device code/message surfaced without falsely marking bulb offline");
                    break;
                case 12:
                    if (test.control.busy) return;
                    test.require(test.control.errorMessage.includes("-32602"), "Poll cleared the device diagnostic before it could be read");
                    test.control.togglePower();
                    test.complete("Read-only poll preserves device diagnostics; power remains usable");
                    break;
                case 13:
                    if (test.control.busy) return;
                    test.require(test.control.power === false, test.control.errorMessage);
                    test.require(!test.find(test.popup, "lightControls").enabled, "OFF after ON did not disable");
                    test.settings.visible = true;
                    test.find(test.settings, "advancedSection").expanded = true;
                    test.require(!test.settings.canTestScenes && !test.find(test.settings, "retrySceneButton").enabled, "OFF advanced interaction enabled");
                    test.settings.requestSceneRetry(5);
                    test.settings.sceneToRetry = 5;
                    test.settings.confirmSceneRetry();
                    test.settings.resetSceneChecks();
                    test.control.port = Number(Quickshell.env("WIZ_OFFLINE_PORT"));
                    test.control.refresh();
                    test.complete("ON → OFF disables controls with stable geometry");
                    break;
                case 14:
                    if (test.control.busy) return;
                    test.require(!test.control.online && test.control.connectionState === "offline", "Timeout mistaken for OFF");
                    test.require(!test.find(test.popup, "powerButton").enabled, "Offline power enabled");
                    test.require(test.find(test.popup, "retryButton").enabled, "Offline retry unavailable");
                    test.control.togglePower();
                    test.control.setBrightness(50, true);
                    test.control.testScene(14);
                    test.popup.requestSceneTest(14);
                    test.settings.requestSceneRetry(5);
                    test.settings.sceneToRetry = 5;
                    test.settings.confirmSceneRetry();
                    test.settings.resetSceneChecks();
                    test.require(!test.settings.canTestScenes && !test.find(test.settings, "resetSceneChecksButton").enabled, "Offline Advanced reset enabled");
                    test.require(!test.control.busy, "Offline handler started a write");
                    test.control.port = Number(Quickshell.env("WIZ_TEST_PORT"));
                    test.find(test.popup, "retryButton").clicked();
                    test.complete("OFFLINE distinct from OFF; power blocked and Retry functional");
                    break;
                case 15:
                    if (test.control.busy) return;
                    test.require(test.control.online, test.control.errorMessage);
                    test.require(test.control.errorMessage === "", "Recovered transport error remained visible");
                    test.find(test.settings, "advancedSection").expanded = false;
                    test.settings.visible = false;
                    test.popup.grabToImage(result => {
                        result.saveToFile(Quickshell.env("WIZ_TEST_SCREENSHOT"));
                        test.widget.closePopout();
                    });
                    test.complete("Retry recovers; closing native popup stops polling");
                    break;
                case 16:
                    if (test.ticks < 170) return;
                    test.require(!test.control.active && !test.control.busy && !test.control.queued, "Hidden popup kept work alive");
                    console.log("PASS: WiZ QML integration (" + test.results.length + " checks)");
                    Qt.quit();
                    timer.stop();
                    break;
                }
            } catch (error) {
                console.error("FAIL: step", test.step, error.message);
                timer.stop();
                Qt.quit();
            }
        }
        id: timer
    }
}
