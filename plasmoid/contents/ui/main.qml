/*
 * Outline SS Plasmoid — main.qml
 *
 * Single-file plasmoid: button UI + data sources all in one place
 * to avoid QML scoping issues between files.
 *
 * The executable data engine runs commands and captures stdout.
 * - Status: polls every 3s via interval
 * - Actions: one-shot via connectSource, disconnectSource after
 */

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami 2.0 as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support 2.0 as P5Support

PlasmoidItem {
    id: root
    switchWidth: Kirigami.Units.gridUnit * 7
    switchHeight: Kirigami.Units.gridUnit * 3

    property string outlineStatus: "disconnected"
    property string serverLabel: ""
    property string methodLabel: ""
    property string errorMessage: ""

    fullRepresentation: ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing

        QQC2.Button {
            id: mainButton
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 2
            flat: true
            display: QQC2.AbstractButton.TextBesideIcon

            icon.name: {
                switch (root.outlineStatus) {
                    case "connected":   return "network-vpn"
                    case "connecting":  return "network-connect"
                    case "error":       return "dialog-error"
                    default:            return "network-offline"
                }
            }
            icon.width: Kirigami.Units.iconSizes.medium
            icon.height: Kirigami.Units.iconSizes.medium

            text: {
                switch (root.outlineStatus) {
                    case "connected":   return root.serverLabel || "Connected"
                    case "connecting":  return "Connecting\u2026"
                    case "error":       return "Error"
                    default:            return "Outline"
                }
            }

            QQC2.ToolTip {
                visible: mainButton.hovered
                delay: 500
                text: {
                    switch (root.outlineStatus) {
                        case "connected":
                            return "Connected to " + root.serverLabel +
                                   "\n" + root.methodLabel +
                                   "\n\nClick to disconnect"
                        case "connecting":
                            return "Connecting to Outline proxy\u2026"
                        case "error":
                            return "Error: " + root.errorMessage
                        default:
                            return "Disconnected \u2022 Click to connect"
                    }
                }
            }

            onClicked: {
                if (root.outlineStatus === "connected" ||
                    root.outlineStatus === "connecting") {
                    doDisconnect()
                } else {
                    doConnect()
                }
            }
        }

        // Status dot
        Rectangle {
            Layout.preferredWidth: Kirigami.Units.smallSpacing * 2.5
            Layout.preferredHeight: width
            Layout.alignment: Qt.AlignHCenter
            radius: width / 2
            color: {
                switch (root.outlineStatus) {
                    case "connected":   return "#27ae60"
                    case "connecting":  return "#f39c12"
                    case "error":       return "#e74c3c"
                    default:            return "#95a5a6"
                }
            }

            SequentialAnimation on opacity {
                running: root.outlineStatus === "connecting"
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 600 }
                NumberAnimation { to: 1.0; duration: 600 }
            }
        }
    }

    // ── Status polling (every 3s via DataSource interval) ─────────────
    // Uses full path to outline-ss so plasmashell can find it.
    P5Support.DataSource {
        id: statusSource
        engine: "executable"
        interval: 3000
        connectedSources: ["outline-ss status --profile default"]

        onNewData: function(sourceName, data) {
            try {
                var out = (data.value || data.stdout || "").trim()
                var s = JSON.parse(out)
                root.outlineStatus = s.status || "disconnected"
                root.serverLabel = s.server || ""
                root.methodLabel = s.method || ""
                root.errorMessage = s.error || ""
            } catch(e) {
                // Command not found or not running — treat as disconnected
                root.outlineStatus = "disconnected"
            }
        }
    }

    // ── Action source (one-shot connect/disconnect) ────────────────────
    P5Support.DataSource {
        id: actionSource
        engine: "executable"
        interval: 0

        onNewData: function(sourceName, data) {
            var resp = ((data.value || data.stdout || "").trim()).toLowerCase()
            if (resp.indexOf("error:") >= 0) {
                root.outlineStatus = "error"
                root.errorMessage = resp.substring(resp.indexOf("error:") + 6).trim()
            }
            // Release the source so we can re-fire next click
            disconnectSource(sourceName)
        }
    }

    // ── Connect / Disconnect actions ───────────────────────────────────
    // All args go BEFORE the positional URL arg (argparse requirement).
    function doConnect() {
        var url = plasmoid.configuration.accessUrl
        if (!url) {
            root.outlineStatus = "error"
            root.errorMessage = "Set Access URL in widget settings (right-click → Configure)"
            return
        }
        var profile = plasmoid.configuration.profile || "default"
        var port = plasmoid.configuration.localPort || 1080
        root.outlineStatus = "connecting"
        actionSource.connectSource(
            "outline-ss connect" +
            " --profile " + profile +
            " --local-port " + port +
            " \"" + url + "\""
        )
    }

    function doDisconnect() {
        var profile = plasmoid.configuration.profile || "default"
        root.outlineStatus = "disconnected"
        actionSource.connectSource(
            "outline-ss disconnect" +
            " --profile " + profile
        )
    }
}
