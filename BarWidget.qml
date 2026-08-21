import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the DaVinci Resolve panel. A filmstrip glyph that toggles the
// panel through the same IPC route a keybinding would use. It is accented
// while Resolve is running, and badged while an install or removal is in
// progress — the one time you want to know without opening anything.
BarWidget {
  id: root
  moduleName: "nosignal.davinci-resolve"

  readonly property string pluginId: "nosignal.davinci-resolve"
  readonly property var service: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
                                 ? bar.shell.serviceFor(pluginId) : null

  readonly property bool installed: service ? service.installed : false
  readonly property bool resolveRunning: service ? service.resolveRunning : false
  readonly property bool busy: service ? service.busy : false
  readonly property int progress: service ? service.jobProgress : 0
  readonly property bool updateAvailable: service ? service.updateAvailable : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰈰"
    tooltipText: {
      if (root.busy) {
        var what = root.service && root.service.jobKind === "uninstall" ? "Removing" : "Installing"
        return "DaVinci Resolve — " + what + " " + root.progress + "%"
      }
      if (!root.installed) return "DaVinci Resolve — not installed"
      if (root.updateAvailable) return "DaVinci Resolve — a newer installer ZIP is waiting"
      if (root.resolveRunning) return "DaVinci Resolve — running"
      return "DaVinci Resolve"
    }
    foreground: root.resolveRunning || root.busy ? Color.accent : Color.muted
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle nosignal.davinci-resolve")
    }
  }

  Rectangle {
    visible: root.busy || root.updateAvailable
    width: Style.space(7)
    height: width
    radius: width / 2
    color: root.busy ? Color.accent : Color.urgent
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(4)
    anchors.rightMargin: Style.space(3)
  }
}
