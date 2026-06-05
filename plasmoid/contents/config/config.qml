import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.configuration
import org.kde.kirigami as Kirigami

ConfigModel {
    ConfigCategory {
        name: i18n("Connection")
        icon: "network-vpn"
        source: "config/ConfigConnection.qml"
    }
}
