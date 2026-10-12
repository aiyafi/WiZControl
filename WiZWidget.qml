import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.Common
import "components"

PluginComponent {
    id: root
    layerNamespacePlugin: "wiz-control"
    popoutWidth: 420
    property alias sceneController: controller
    property bool popoutActive: false
    property bool sceneSettingsActive: false

    // DMS's in-process plugin globals let Settings reuse this exact controller.
    function publishSceneWidget() {
        if (pluginService && pluginId)
            pluginService.setGlobalVar(pluginId, "sceneWidget", root);
    }
    Connections {
        target: root
        Component.onCompleted: root.publishSceneWidget()
        function onPluginServiceChanged() { root.publishSceneWidget(); }
        function onPluginIdChanged() { root.publishSceneWidget(); }
        Component.onDestruction: {
            if (root.pluginService && root.pluginService.getGlobalVar(root.pluginId, "sceneWidget", null) === root)
                root.pluginService.setGlobalVar(root.pluginId, "sceneWidget", null);
        }
    }

    readonly property string deviceLabel: pluginData.deviceLabel || "WiZ light"
    readonly property color lightColor: controller.hasColor && controller.previewMode === "rgb"
        ? Qt.hsva(controller.hue, controller.saturation, 1, 1) : Theme.primary
    readonly property string statusText: {
        switch (controller.connectionState) {
        case "pending": return "Applying…";
        case "loading": return "Connecting…";
        case "online-on": return "Connected · On";
        case "online-off": return "Connected · Off";
        case "offline": return "Unavailable";
        default: return "Open to connect";
        }
    }
    readonly property var scenes: [
        {id: 14, name: "Night light", dynamic: false},
        {id: 6, name: "Cozy", dynamic: false},
        {id: 16, name: "Relax", dynamic: false},
        {id: 15, name: "Focus", dynamic: false},
        {id: 18, name: "TV time", dynamic: false},
        {id: 12, name: "Daylight", dynamic: false},
        {id: 1, name: "Ocean", dynamic: true},
        {id: 5, name: "Fireplace", dynamic: true},
        {id: 29, name: "Candlelight", dynamic: true}
    ]

    function sceneName(id) {
        const scene = scenes.find(s => s.id === id);
        return scene ? scene.name : "Scene " + id;
    }

    WizController {
        id: controller
        objectName: "wizController"
        active: root.popoutActive || root.sceneSettingsActive
        bulbIp: root.pluginData.bulbIp || ""
        expectedMac: root.pluginData.expectedMac || ""
        verifiedScenes: root.pluginData.verifiedScenes || ""
        sceneChecks: root.pluginData.sceneChecks || ({})
        configuredMin: Number(root.pluginData.minKelvin) || 0
        configuredMax: Number(root.pluginData.maxKelvin) || 0
        onSceneChecksUpdated: checks => {
            if (root.pluginService)
                root.pluginService.savePluginData(root.pluginId || "wizControl", "sceneChecks", checks);
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS
            DankIcon {
                name: controller.power === false ? "lightbulb_outline" : "lightbulb"
                size: root.iconSize
                color: controller.online && controller.power ? root.lightColor : Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: "WiZ"
                color: Theme.widgetTextColor
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale)
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
    verticalBarPill: Component {
        DankIcon {
            name: controller.power === false ? "lightbulb_outline" : "lightbulb"
            size: root.iconSize
            color: controller.online && controller.power ? root.lightColor : Theme.widgetIconColor
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            objectName: "wizPopout"
            property int selectedTab: 0
            property int sceneToTest: 0
            property var sceneDialog: ConfirmDialogOverlay {
                objectName: "sceneTestDialog"
                parent: dialogContainer
                enabled: controller.controlsEnabled && !controller.busy && !controller.pending && !controller.dragging
            }
            function requestSceneTest(id) {
                if (!controller.controlsEnabled || controller.pending || controller.dragging
                        || controller.sceneUnavailable(id) || controller.sceneSupported(id))
                    return;
                sceneToTest = id;
                sceneDialog.showWithOptions({
                    title: "Try " + root.sceneName(id) + "?",
                    message: "This scene hasn't been tested with your light. Test & Enable will apply it and remember it if supported.",
                    confirmText: "Test & Enable",
                    cancelText: "Cancel",
                    onConfirm: () => popout.confirmSceneTest(),
                    onCancel: () => { popout.sceneToTest = 0; }
                });
            }
            function confirmSceneTest() {
                const id = sceneToTest;
                sceneToTest = 0;
                if (id > 0)
                    controller.testScene(id);
            }
            Connections {
                target: controller
                function onControlsEnabledChanged() {
                    if (!controller.controlsEnabled) {
                        popout.sceneToTest = 0;
                        popout.sceneDialog.close();
                    }
                }
            }
            readonly property bool opened: parentPopout?.shouldBeVisible ?? false
            onOpenedChanged: {
                root.popoutActive = opened;
                if (!opened) {
                    sceneToTest = 0;
                    sceneDialog.close();
                }
            }
            Component.onDestruction: {
                root.popoutActive = false;
                sceneDialog.close();
            }

            Item {
                id: dialogContainer
                // Keep the native modal overlay out of the popout's Column sizing.
                width: parent.width
                implicitHeight: popoutBody.implicitHeight
                height: implicitHeight
            Column {
                id: popoutBody
                width: parent.width
                spacing: Theme.spacingM

                Item {
                    width: parent.width
                    height: 68
                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 46
                        height: 46
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.primary, 0.12)
                        DankIcon {
                            anchors.centerIn: parent
                            name: "lightbulb"
                            color: controller.online && controller.power ? root.lightColor : Theme.surfaceVariantText
                            size: 28
                        }
                    }
                    Column {
                        x: 58
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - powerButton.width - Theme.spacingM
                        spacing: Theme.spacingXS
                        StyledText {
                            width: parent.width
                            text: root.deviceLabel
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                        }
                        StyledText {
                            text: root.statusText
                            color: controller.online ? Theme.primary : Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }
                    DankButton {
                        id: powerButton
                        objectName: "powerButton"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: controller.powerPending ? "Wait…" : controller.power === null ? "Power" : controller.power ? "On" : "Off"
                        iconName: "power_settings_new"
                        enabled: controller.powerEnabled
                        backgroundColor: controller.power === true ? Theme.primary : Theme.surfaceContainerHighest
                        textColor: controller.power === true ? Theme.onPrimary : Theme.surfaceText
                        Accessible.role: Accessible.Button
                        Accessible.name: "Toggle light power"
                        onClicked: controller.togglePower()
                    }
                }

                Column {
                    id: lightControls
                    objectName: "lightControls"
                    width: parent.width
                    spacing: Theme.spacingM
                    enabled: controller.controlsEnabled
                    opacity: enabled ? 1 : 0.38

                    DankTabBar {
                        id: tabs
                        objectName: "lightTabs"
                        width: parent.width
                        tabHeight: 36
                        showIcons: false
                        model: [{text: "Color"}, {text: "Scenes"}]
                        currentIndex: popout.selectedTab
                        activeFocusOnTab: enabled
                        onTabClicked: index => {
                            if (controller.controlsEnabled)
                                popout.selectedTab = index;
                        }
                    }

                    Item {
                        width: parent.width
                        height: 298

                        Column {
                            width: parent.width
                            visible: popout.selectedTab === 0
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width
                                height: 26
                                StyledText {
                                    text: controller.previewMode === "scene" ? root.sceneName(controller.state.scene_id)
                                        : controller.previewMode === "temperature" ? "White light" : "Choose a color"
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22
                                    height: 22
                                    radius: 11
                                    color: controller.hasColor && controller.previewMode === "rgb" ? root.lightColor : "transparent"
                                    border.width: 1
                                    border.color: Theme.outline
                                }
                            }
                            ColorSpectrum {
                                objectName: "colorSpectrum"
                                width: parent.width
                                height: 136
                                hue: controller.hue
                                saturation: controller.saturation
                                showMarker: controller.hasColor && controller.previewMode === "rgb"
                                onDragStarted: controller.beginDrag()
                                onSelected: (h, s, finalValue) => controller.setColor(h, s, finalValue)
                            }
                            Row {
                                width: parent.width
                                spacing: (width - 8 * 30) / 7
                                Repeater {
                                    model: [
                                        {h: 0, s: 0, name: "White"}, {h: 0, s: 1, name: "Red"},
                                        {h: 0.08, s: 1, name: "Amber"}, {h: 0.16, s: 1, name: "Yellow"},
                                        {h: 0.33, s: 1, name: "Green"}, {h: 0.50, s: 1, name: "Cyan"},
                                        {h: 0.66, s: 1, name: "Blue"}, {h: 0.78, s: 0.73, name: "Violet"}
                                    ]
                                    Rectangle {
                                        required property var modelData
                                        objectName: "colorSwatch"
                                        width: 30
                                        height: 30
                                        radius: 15
                                        color: Qt.hsva(modelData.h, modelData.s, 1, 1)
                                        border.color: activeFocus ? Theme.primary : Theme.outline
                                        border.width: activeFocus ? 3 : 1
                                        activeFocusOnTab: enabled
                                        Accessible.role: Accessible.Button
                                        Accessible.name: modelData.name
                                        function select() { controller.setColor(modelData.h, modelData.s, true); }
                                        Keys.onSpacePressed: select()
                                        Keys.onReturnPressed: select()
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: parent.select()
                                        }
                                    }
                                }
                            }
                            Item {
                                width: parent.width
                                height: 22
                                StyledText {
                                    text: "White temperature"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                StyledText {
                                    anchors.right: parent.right
                                    text: !controller.hasCct ? "Range unknown" : controller.temperature > 0 ? controller.temperature + " K" : "— K"
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                            Item {
                                width: parent.width
                                height: 36
                                Canvas {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    height: 8
                                    onWidthChanged: requestPaint()
                                    onPaint: {
                                        const ctx = getContext("2d");
                                        ctx.reset();
                                        const gradient = ctx.createLinearGradient(0, 0, width, 0);
                                        gradient.addColorStop(0, "#ffbc76");
                                        gradient.addColorStop(0.5, "#fff3dd");
                                        gradient.addColorStop(1, "#bddbff");
                                        ctx.fillStyle = gradient;
                                        ctx.fillRect(0, 0, width, height);
                                    }
                                }
                                DankSlider {
                                    id: cctSlider
                                    objectName: "temperatureSlider"
                                    anchors.fill: parent
                                    minimum: controller.hasCct ? controller.minKelvin : 2700
                                    maximum: controller.hasCct ? controller.maxKelvin : 6500
                                    enabled: controller.controlsEnabled && controller.hasCct
                                    trackColor: "transparent"
                                    trackOpacity: 0
                                    step: 50
                                    unit: " K"
                                    activeFocusOnTab: enabled
                                    Accessible.role: Accessible.Slider
                                    Accessible.name: "White temperature in Kelvin"
                                    onIsDraggingChanged: { if (isDragging) controller.beginDrag(); }
                                    onSliderValueChanged: value => controller.setTemperature(value, false)
                                    onSliderDragFinished: value => controller.setTemperature(value, true)
                                    Keys.onLeftPressed: controller.setTemperature(value - 50, true)
                                    Keys.onRightPressed: controller.setTemperature(value + 50, true)
                                    Binding {
                                        target: cctSlider
                                        property: "value"
                                        value: Math.max(cctSlider.minimum, Math.min(cctSlider.maximum, controller.temperature || cctSlider.minimum))
                                        when: !cctSlider.isDragging
                                    }
                                }
                            }
                        }

                        Column {
                            width: parent.width
                            visible: popout.selectedTab === 1
                            spacing: Theme.spacingS
                            Grid {
                                width: parent.width
                                columns: 3
                                spacing: Theme.spacingS
                                Repeater {
                                    model: root.scenes
                                    Item {
                                        required property var modelData
                                        width: (parent.width - Theme.spacingS * 2) / 3
                                        height: 72
                                        DankButton {
                                            objectName: "sceneButton"
                                            readonly property var modelData: parent.modelData
                                            anchors.fill: parent
                                            buttonHeight: 72
                                            horizontalPadding: Theme.spacingXS
                                            text: modelData.name + (controller.sceneUnavailable(modelData.id) ? "\nUnsupported" : "")
                                            iconName: ""
                                            enabled: controller.controlsEnabled && !controller.pending && !controller.sceneUnavailable(modelData.id)
                                                && !popout.sceneDialog.visible
                                            backgroundColor: controller.state.scene_id === modelData.id ? Theme.primary : Theme.surfaceContainerHigh
                                            textColor: controller.state.scene_id === modelData.id ? Theme.onPrimary : Theme.surfaceText
                                            Accessible.name: text + (modelData.dynamic ? " dynamic scene" : " scene")
                                            Accessible.description: controller.sceneUnavailable(modelData.id)
                                                ? controller.sceneUnavailableReason(modelData.id) : controller.sceneStatus(modelData.id)
                                            onClicked: {
                                                if (controller.sceneSupported(modelData.id))
                                                    controller.setScene(modelData.id);
                                                else
                                                    popout.requestSceneTest(modelData.id);
                                            }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            acceptedButtons: Qt.NoButton
                                            hoverEnabled: true
                                            enabled: controller.controlsEnabled && controller.sceneUnavailable(parent.modelData.id)
                                            onEntered: sceneTooltip.show(controller.sceneUnavailableReason(parent.modelData.id)
                                                + " Retry in Advanced → Scene Compatibility.", parent)
                                            onExited: sceneTooltip.hide()
                                        }
                                    }
                                }
                            }
                            Item {
                                width: parent.width
                                height: 58
                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    text: "Choose a scene. New scenes ask before testing. Unsupported scenes were rejected by this light; retry them in Advanced Settings."
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    maximumLineCount: 3
                                }
                            }
                            DankTooltipV2 { id: sceneTooltip }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        Item {
                            width: parent.width
                            height: 22
                            StyledText { text: "Brightness"; font.pixelSize: Theme.fontSizeMedium }
                            StyledText {
                                anchors.right: parent.right
                                text: controller.state.brightness == null && !controller.pending ? "—" : controller.brightness + "%"
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.primary
                            }
                        }
                        DankSlider {
                            id: brightnessSlider
                            objectName: "brightnessSlider"
                            width: parent.width
                            height: 36
                            minimum: 1
                            maximum: 100
                            leftIcon: "brightness_low"
                            rightIcon: "brightness_high"
                            activeFocusOnTab: enabled
                            Accessible.role: Accessible.Slider
                            Accessible.name: "Brightness percent"
                            onIsDraggingChanged: { if (isDragging) controller.beginDrag(); }
                            onSliderValueChanged: value => controller.setBrightness(value, false)
                            onSliderDragFinished: value => controller.setBrightness(value, true)
                            Keys.onLeftPressed: controller.setBrightness(value - 1, true)
                            Keys.onRightPressed: controller.setBrightness(value + 1, true)
                            Binding {
                                target: brightnessSlider
                                property: "value"
                                value: controller.brightness
                                when: !brightnessSlider.isDragging
                            }
                        }
                    }
                }

                Item {
                    objectName: "connectionFeedback"
                    width: parent.width
                    visible: !controller.online || controller.errorMessage.length > 0
                    height: visible ? 54 : 0
                    StyledText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - (retryButton.visible ? retryButton.width + Theme.spacingM : 0)
                        text: controller.errorMessage || "Connecting to light…"
                        color: controller.errorMessage ? Theme.error : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                    DankButton {
                        id: retryButton
                        objectName: "retryButton"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Retry"
                        visible: !controller.online && !controller.busy
                        iconName: "refresh"
                        enabled: visible && controller.active && !controller.busy && !controller.pending && !controller.dragging
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: { if (enabled) controller.refresh(); }
                    }
                }
            }
            }
        }
    }
}
