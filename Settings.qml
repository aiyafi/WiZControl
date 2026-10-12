import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.Common

PluginSettings {
    id: root
    pluginId: "wizControl"
    readonly property var sceneWidget: {
        const widget = pluginService?.getGlobalVar(pluginId, "sceneWidget", null);
        return Qt.isQtObject(widget) ? widget : null;
    }
    readonly property var sceneController: sceneWidget?.sceneController ?? null
    readonly property bool compatibilityVisible: visible && advancedSection.expanded && compatibilitySection.expanded
    readonly property bool canTestScenes: compatibilityVisible && sceneController?.controlsEnabled === true
        && !sceneController.busy && !sceneController.pending && !sceneController.dragging && hasPermission
    property var sessionWidget: null
    property int sceneToRetry: 0

    function syncCompatibilitySession() {
        if (Qt.isQtObject(sessionWidget) && sessionWidget !== sceneWidget)
            sessionWidget.sceneSettingsActive = false;
        sessionWidget = sceneWidget;
        if (sceneWidget)
            sceneWidget.sceneSettingsActive = compatibilityVisible;
        if (!compatibilityVisible)
            sceneToRetry = 0;
    }
    function requestSceneRetry(id) {
        if (!canTestScenes)
            return;
        sceneToRetry = id;
        retryContent.reset();
        retryCard.forceActiveFocus();
        Qt.callLater(() => root.ensureItemVisible(retryCard));
    }
    function confirmSceneRetry() {
        const id = sceneToRetry;
        sceneToRetry = 0;
        if (id > 0 && canTestScenes)
            sceneController.testScene(id, true);
    }
    function resetSceneChecks() {
        if (!canTestScenes)
            return;
        sceneToRetry = 0;
        saveValue("sceneChecks", {});
        saveValue("verifiedScenes", "");
        sceneController.infoMessage = "Saved checks reset. The active scene can be learned again on refresh.";
    }
    function sceneName(id) { return sceneWidget?.sceneName(id) ?? "scene"; }

    onCompatibilityVisibleChanged: syncCompatibilitySession()
    onSceneWidgetChanged: { sceneToRetry = 0; syncCompatibilitySession(); }
    Component.onDestruction: {
        if (Qt.isQtObject(sessionWidget))
            sessionWidget.sceneSettingsActive = false;
    }
    Connections {
        target: root.sceneController
        function onControlsEnabledChanged() { if (!root.sceneController.controlsEnabled) root.sceneToRetry = 0; }
        function onSceneDeviceKeyChanged() { root.sceneToRetry = 0; }
    }

    StyledText {
        width: parent.width
        text: "One light. Your local network."
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Medium
    }
    StringSetting {
        settingKey: "bulbIp"
        label: "Bulb IPv4 address"
        description: "Enable Allow local → Allow all controls in WiZ V2. A DHCP reservation is recommended."
        placeholder: "Enter the light's LAN address"
        defaultValue: ""
    }
    StringSetting {
        settingKey: "deviceLabel"
        label: "Light name"
        defaultValue: "WiZ light"
    }
    StringSetting {
        settingKey: "expectedMac"
        label: "Expected MAC (optional)"
        description: "Prevents controlling a different bulb if its IP changes. Colons are accepted."
        defaultValue: ""
    }
    StyledText {
        width: parent.width
        text: "White-temperature limits are read from the bulb. Only set both overrides below if you have verified your model's range; otherwise leave them empty."
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }
    StringSetting {
        settingKey: "minKelvin"
        label: "Verified minimum Kelvin (optional)"
        defaultValue: ""
    }
    StringSetting {
        settingKey: "maxKelvin"
        label: "Verified maximum Kelvin (optional)"
        defaultValue: ""
    }
    DankCollapsibleSection {
        id: advancedSection
        objectName: "advancedSection"
        width: parent.width
        title: "Advanced"
        expanded: false

        DankCollapsibleSection {
            id: compatibilitySection
            objectName: "sceneCompatibilitySection"
            Layout.fillWidth: true
            title: "Scene Compatibility"
            expanded: false
            description: "Test one scene at a time. Retry keeps the existing result until the bulb accepts the scene and reports it active."

            Column {
                Layout.fillWidth: true
                spacing: Theme.spacingM
                StyledText {
                    width: parent.width
                    text: !root.sceneController ? "Add WiZ Control to DankBar to view compatibility and test scenes."
                        : !root.sceneController.online ? root.sceneController.errorMessage || "Reading bulb status…"
                        : root.sceneController.power !== true ? "Turn the light ON from the widget to test scenes."
                        : root.sceneController.errorMessage || root.sceneController.infoMessage || "Connected · Ready to test"
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: root.sceneController?.errorMessage ? Theme.error : Theme.surfaceVariantText
                }
                Rectangle {
                    id: retryCard
                    objectName: "settingsSceneTestDialog"
                    width: parent.width
                    height: visible ? retryContent.implicitHeight + Theme.spacingM * 2 : 0
                    visible: root.sceneToRetry > 0
                    enabled: root.canTestScenes
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 1
                    border.color: Theme.outline
                    focus: visible
                    Keys.onPressed: event => retryContent.handleKey(event)
                    ConfirmDialogContent {
                        id: retryContent
                        objectName: "settingsSceneTestContent"
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: Theme.spacingM
                        confirmTitle: "Test " + root.sceneName(root.sceneToRetry) + "?"
                        confirmMessage: "This applies the scene to your light. It will be enabled only after the bulb confirms it."
                        confirmButtonText: "Test & Enable"
                        cancelButtonText: "Cancel"
                        onButtonActivated: button => {
                            if (button === 1) root.confirmSceneRetry();
                            else root.sceneToRetry = 0;
                        }
                        onCancelled: root.sceneToRetry = 0
                    }
                }
                Repeater {
                    model: root.sceneWidget?.scenes ?? []
                    Column {
                        required property var modelData
                        objectName: "sceneCompatibilityRow"
                        readonly property string verificationStatus: root.sceneController?.sceneStatus(modelData.id) ?? "Not Tested"
                        width: parent.width
                        spacing: Theme.spacingXS
                        RowLayout {
                            width: parent.width
                            Column {
                                Layout.fillWidth: true
                                spacing: Theme.spacingXS
                                StyledText {
                                    width: parent.width
                                    text: modelData.name
                                    elide: Text.ElideRight
                                    font.pixelSize: Theme.fontSizeMedium
                                }
                                StyledText {
                                    text: verificationStatus
                                    color: verificationStatus === "Verified" ? Theme.primary : Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                            DankButton {
                                objectName: "retrySceneButton"
                                readonly property int sceneId: modelData.id
                                text: verificationStatus === "Not Tested" ? "Test" : "Retry"
                                buttonHeight: 32
                                horizontalPadding: Theme.spacingS
                                enabled: root.canTestScenes && root.sceneToRetry === 0
                                backgroundColor: Theme.surfaceContainerHigh
                                textColor: Theme.surfaceText
                                Accessible.name: text + " " + modelData.name
                                onClicked: root.requestSceneRetry(modelData.id)
                            }
                        }
                        StyledText {
                            width: parent.width
                            visible: verificationStatus === "Unsupported"
                            text: root.sceneController?.sceneUnavailableReason(modelData.id) ?? ""
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }
                Row {
                    spacing: Theme.spacingS
                    DankButton {
                        objectName: "refreshCompatibilityButton"
                        text: "Refresh status"
                        enabled: root.compatibilityVisible && root.sceneController !== null && !root.sceneController.busy
                            && !root.sceneController.pending && !root.sceneController.dragging
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: { if (enabled) root.sceneController.refresh(); }
                    }
                    DankButton {
                        objectName: "resetSceneChecksButton"
                        text: "Reset saved checks"
                        enabled: root.canTestScenes && root.sceneToRetry === 0
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: root.resetSceneChecks()
                    }
                }
            }
        }
    }
}
