import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: connectionPage

    property alias cfg_accessUrl: accessUrlField.text
    property alias cfg_profile: profileField.text
    property alias cfg_localPort: localPortField.value

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading {
            text: i18n("Connection Settings")
            level: 2
        }

        GridLayout {
            columns: 2
            columnSpacing: Kirigami.Units.largeSpacing
            rowSpacing: Kirigami.Units.smallSpacing
            Layout.fillWidth: true

            Label {
                text: i18n("Access URL (ssconf://):")
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }

            TextField {
                id: accessUrlField
                Layout.fillWidth: true
                placeholderText: i18n("ssconf://...")
            }

            Label {
                text: i18n("Profile:")
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }

            TextField {
                id: profileField
                Layout.fillWidth: true
                placeholderText: i18n("default")
            }

            Label {
                text: i18n("Local SOCKS5 Port:")
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }

            SpinBox {
                id: localPortField
                from: 1024
                to: 65535
                value: 1080
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
