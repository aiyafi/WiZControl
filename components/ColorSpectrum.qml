import QtQuick
import qs.Common

Item {
    id: root
    property real hue: 0
    property real saturation: 0
    property bool showMarker: false
    signal dragStarted()
    signal selected(real hue, real saturation, bool finalValue)
    implicitHeight: 144
    activeFocusOnTab: enabled
    Accessible.role: Accessible.Slider
    Accessible.name: "Color hue and saturation"
    Accessible.description: "Left/right changes hue; up/down changes saturation."

    function choose(x, y, finalValue) {
        if (!enabled || width <= 0 || height <= 0 || !isFinite(x) || !isFinite(y))
            return;
        selected(Math.max(0, Math.min(1, x / width)), Math.max(0, Math.min(1, y / height)), finalValue);
    }

    Canvas {
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const rainbow = ctx.createLinearGradient(0, 0, width, 0);
            for (let i = 0; i <= 6; i++)
                rainbow.addColorStop(i / 6, Qt.hsva(i / 6, 1, 1, 1).toString());
            ctx.fillStyle = rainbow;
            ctx.fillRect(0, 0, width, height);
            const white = ctx.createLinearGradient(0, 0, 0, height);
            white.addColorStop(0, "rgba(255,255,255,1)");
            white.addColorStop(1, "rgba(255,255,255,0)");
            ctx.fillStyle = white;
            ctx.fillRect(0, 0, width, height);
        }
    }
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? Theme.primary : Theme.outline
    }
    Rectangle {
        visible: root.showMarker
        x: Math.max(2, Math.min(root.width - width - 2, root.hue * root.width - width / 2))
        y: Math.max(2, Math.min(root.height - height - 2, root.saturation * root.height - height / 2))
        width: 18
        height: 18
        radius: 9
        color: Qt.hsva(root.hue, root.saturation, 1, 1)
        border.color: "white"
        border.width: 3
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            radius: 10
            color: "transparent"
            border.color: "#66000000"
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: root.enabled
        preventStealing: true
        cursorShape: enabled ? Qt.CrossCursor : Qt.ArrowCursor
        onPressed: mouse => {
            root.forceActiveFocus();
            root.dragStarted();
            root.choose(mouse.x, mouse.y, false);
        }
        onPositionChanged: mouse => { if (pressed) root.choose(mouse.x, mouse.y, false); }
        onReleased: mouse => root.choose(mouse.x, mouse.y, true)
        onCanceled: root.choose(root.hue * root.width, root.saturation * root.height, true)
    }
    Keys.onPressed: event => {
        if (!root.enabled)
            return;
        const step = event.modifiers & Qt.ShiftModifier ? 0.05 : 0.01;
        let h = root.hue, s = root.saturation;
        if (event.key === Qt.Key_Left) h -= step;
        else if (event.key === Qt.Key_Right) h += step;
        else if (event.key === Qt.Key_Up) s -= step;
        else if (event.key === Qt.Key_Down) s += step;
        else return;
        root.choose(h * root.width, s * root.height, true);
        event.accepted = true;
    }
}
