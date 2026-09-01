import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// DaVinci Resolve panel. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.davinci-resolve
//
// Presentation and input only: every action is a call into the sibling
// Service.qml instance, which owns the engine processes. That separation is
// what lets the panel be closed mid-install without killing the install —
// the service is keepLoaded, this window is not sacred.
//
// Four tabs: Status (what you have), Install (get or replace it), Health (the
// checks that explain Resolve misbehaving), Log (what it actually said).
Item {
  id: root

  property bool opened: false
  readonly property string selfId: "nosignal.davinci-resolve"

  // Injected by the shell host after the Loader resolves.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  readonly property var svc: (root.shell && typeof root.shell.serviceFor === "function")
                             ? root.shell.serviceFor(root.selfId) : null
  readonly property bool hasService: root.svc !== null && root.svc !== undefined

  property int tab: 0
  readonly property var tabNames: ["Status", "Install", "Health", "Log"]
  property string logSource: "install"   // install | resolve
  // The first preflight is asynchronous, so an open before it lands cannot
  // know whether Resolve is installed. Start on Status and let the answer
  // move us, rather than flashing the Install tab at someone who came to
  // check a log.
  property bool awaitingFirstCheck: false
  property string probePath: ""
  property bool confirmingUninstall: false

  // ------------------------------------------------------------------ theme
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color selBg: Color.menu.selectedBackground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int sectionGap: Style.spacing.md

  function stateColor(state) {
    switch (String(state)) {
    case "ok": return root.accent
    case "warn": return "#c9a227"
    case "fail": return root.urgent
    case "running": return root.accent
    default: return root.dim
    }
  }

  function stateGlyph(state) {
    switch (String(state)) {
    case "ok": return "✓"
    case "warn": return "!"
    case "fail": return "✗"
    case "skip": return "–"
    case "start":
    case "running": return "•"
    default: return "·"
    }
  }

  // ------------------------------------------------- self-reference (bar fix)
  // `omarchy plugin enable` writes only the bar.layout entry for a
  // bar-widget+panel plugin; if the bar icon is later removed the shell finds
  // no reference, stops instantiating the panel, and the keybinding dies.
  // First open claims a plugins[] reference of our own. Idempotent; inert once
  // the shell writes both references itself.
  property bool selfRefEnsured: false
  readonly property string ensureSelfRefScript: [
    'id="$1"',
    'f="$HOME/.config/omarchy/shell.json"',
    '[ -f "$f" ] || exit 0',
    'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
    'tmp="$f.selfref.$$"',
    'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
    '  rm -f "$tmp"; exit 1;',
    '}',
    '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
    'mv "$tmp" "$f"'
  ].join("\n")

  function ensureSelfReference() {
    if (root.selfRefEnsured) return
    root.selfRefEnsured = true
    Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId])
  }

  // ------------------------------------------------------------- open/close
  function open(payloadJson) {
    root.opened = true
    root.ensureSelfReference()
    root.confirmingUninstall = false
    if (root.hasService) {
      root.svc.refresh()
      if (root.svc.checks.length === 0) root.svc.diagnose()
      // Land on whatever the user most likely came for.
      if (root.svc.busy) root.tab = 1
      else if (root.svc.checked) root.tab = root.svc.installed ? 0 : 1
      else { root.tab = 0; root.awaitingFirstCheck = true }
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function setTab(i) {
    root.awaitingFirstCheck = false
    var n = root.tabNames.length
    root.tab = ((i % n) + n) % n
    if (root.tab === 2 && root.hasService && root.svc.checks.length === 0) root.svc.diagnose()
    if (root.tab === 3 && root.logSource === "resolve" && root.hasService) root.svc.tailLogs()
  }

  Connections {
    target: root.svc
    enabled: root.hasService
    // Only ever moves the tab once, and only if the user has not already
    // clicked something themselves.
    function onCheckedChanged() {
      if (!root.awaitingFirstCheck) return
      root.awaitingFirstCheck = false
      if (root.tab === 0 && !root.svc.installed) root.tab = 1
    }
    function onJobFinished(kind, ok) {
      // Leave the log up on failure so the reason is on screen; on success the
      // Status tab is the useful place to be.
      if (ok && kind === "install") root.tab = 0
    }
  }

  // ------------------------------------------------------------------ window
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-davinci-resolve"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
      // Grow to the active tab and stop, rather than standing at full height
      // with the Status tab half empty. The Log tab asks for the maximum
      // because a tail is only useful with room to read it.
      readonly property int maxHeight: Math.min(Style.space(700),
                       Math.min(panel.height * 0.9,
                                panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2))
      readonly property int chromeHeight: contentTopInset + contentBottomInset
                       + headerRow.height + tabsRow.height + headerSep.height
                       + root.sectionGap * 3
      readonly property int tabContentHeight: root.tab === 0 ? statusColumn.height
                       : root.tab === 1 ? installColumn.height
                       : root.tab === 2 ? healthColumn.height
                       : maxHeight
      height: Math.max(Style.space(200), Math.min(maxHeight, chromeHeight + tabContentHeight))
      radius: root.cornerRadius
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut
      anchors.rightMargin: Style.gapsOut
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          else if (event.key === Qt.Key_1) { root.setTab(0); event.accepted = true }
          else if (event.key === Qt.Key_2) { root.setTab(1); event.accepted = true }
          else if (event.key === Qt.Key_3) { root.setTab(2); event.accepted = true }
          else if (event.key === Qt.Key_4) { root.setTab(3); event.accepted = true }
          else if (event.key === Qt.Key_Tab) { root.setTab(root.tab + 1); event.accepted = true }
          else if (event.key === Qt.Key_Backtab) { root.setTab(root.tab - 1); event.accepted = true }
          else if (event.key === Qt.Key_R && root.hasService) {
            root.svc.refresh(); root.svc.diagnose(); event.accepted = true
          }
        }
      }

      // BorderSurface does not inset children itself — its padding only feeds
      // the content*Inset helpers, which children apply as margins.
      Column {
        id: body
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.sectionGap

        // ------------------------------------------------------------ header
        Item {
          id: headerRow
          width: parent.width
          height: Style.font.title + Style.spacing.lg

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰈰  DaVinci Resolve"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              if (!root.hasService) return "service not loaded"
              if (root.svc.busy) return root.svc.jobKind === "install" ? "installing…" : "removing…"
              if (root.svc.resolveRunning) return "running"
              if (!root.svc.installed) return "not installed"
              var v = root.svc.installedVersion
              var e = root.svc.installedEdition
              if (v !== "") return (e !== "" ? e + " " : "") + v
              return "installed"
            }
          }
        }

        // -------------------------------------------------------------- tabs
        Row {
          id: tabsRow
          width: parent.width
          spacing: Style.spacing.xs

          Repeater {
            model: root.tabNames
            delegate: Rectangle {
              required property int index
              required property string modelData
              width: (body.width - Style.spacing.xs * (root.tabNames.length - 1)) / root.tabNames.length
              height: Style.spacing.controlHeight
              radius: root.cornerRadius
              color: root.tab === index ? root.selBg : "transparent"

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: (index + 1) + " " + modelData
                color: root.tab === index ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: root.tab === index
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTab(index)
              }
            }
          }
        }

        PanelSeparator { id: headerSep; width: parent.width }

        // ------------------------------------------------------------ content
        Item {
          id: content
          width: parent.width
          height: body.height - y

          // ============================================================ STATUS
          Flickable {
            anchors.fill: parent
            id: statusFlick
            visible: root.tab === 0
            contentHeight: statusColumn.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
              policy: statusFlick.contentHeight > statusFlick.height
                      ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            }
            onVisibleChanged: if (visible) contentY = 0

            Column {
              id: statusColumn
              width: parent.width
              spacing: root.sectionGap

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                text: {
                  if (!root.hasService) return "Service not loaded"
                  if (!root.svc.installed) return "DaVinci Resolve is not installed"
                  var v = root.svc.installedVersion
                  if (v === "") return "DaVinci Resolve is installed"
                  return "DaVinci Resolve " + (root.svc.installedEdition !== ""
                         ? root.svc.installedEdition + " " : "") + v
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                visible: text !== ""
                text: {
                  if (!root.hasService || !root.svc.installed) return ""
                  var info = root.svc.info
                  if (String(info.installedDate || "") !== "")
                    return "Installed " + String(info.installedDate).split("T")[0]
                        + " from " + String(info.installedZip || "")
                  return "Installed before this plugin existed, so there is no exact version on record — "
                       + "the next install through this panel records one."
                }
              }

              Repeater {
                model: root.hasService ? [
                  // The card Resolve will compute on, named, plus the API it
                  // will use. A machine with two GPUs gets told which one won.
                  { label: "GPU", value: (function() {
                      var s = root.svc
                      if (s.computeVendor === "" || s.computeVendor === "none")
                        return "no GPU detected"
                      var v = s.vendorLabel + (s.computeName !== "" ? " " + s.computeName : "")
                      if (s.computeVendor === "nvidia" && String(s.info.driverVersion || "") !== "")
                        v += ", driver " + s.info.driverVersion
                      if (s.computeGfx !== "") v += " (" + s.computeGfx + ")"
                      return v
                    })(),
                    state: root.svc.stackState === "" ? "warn" : root.svc.stackState },
                  // Whether the compute stack is actually installed. This is
                  // the line that decides whether an install can succeed at
                  // all on an AMD or Intel machine.
                  { label: root.svc.computeApi !== "" ? root.svc.computeApi : "Compute",
                    value: root.svc.stackDetail !== "" ? root.svc.stackDetail : "not checked yet",
                    state: root.svc.stackState === "" ? "warn" : root.svc.stackState },
                  { label: "Installer ZIP", value: root.svc.zips.length > 0
                      ? String(root.svc.info.zipEdition || "") + " " + String(root.svc.info.zipVersion || "")
                        + " in " + String(root.svc.info.zipDir || "")
                      : "none found in " + String(root.svc.info.zipDir || "~/Downloads"),
                    state: root.svc.zips.length > 0 ? "ok" : "warn" },
                  { label: "Free space", value: String(root.svc.info.freeGb || 0) + " GiB (needs "
                      + String(root.svc.info.needGb || 10) + " GiB to install)",
                    state: Number(root.svc.info.freeGb || 0) >= Number(root.svc.info.needGb || 10) ? "ok" : "fail" }
                ] : []

                delegate: Row {
                  required property var modelData
                  width: statusColumn.width
                  spacing: Style.spacing.sm

                  Text {
                    width: Style.space(14)
                    textFormat: Text.PlainText
                    text: root.stateGlyph(modelData.state)
                    color: root.stateColor(modelData.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: Style.space(110)
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: statusColumn.width - Style.space(140)
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: modelData.value
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              // Says something only when the ZIP on disk and the installed
              // build actually differ. A downgrade is called a downgrade
              // rather than dressed up as an update.
              Rectangle {
                width: parent.width
                height: updateText.implicitHeight + Style.spacing.md * 2
                radius: root.cornerRadius
                color: root.selBg
                visible: root.hasService && (root.svc.zipRelation === "newer"
                                             || root.svc.zipRelation === "older")

                Text {
                  id: updateText
                  anchors.centerIn: parent
                  width: parent.width - Style.spacing.md * 2
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  text: {
                    if (!root.hasService) return ""
                    var have = root.svc.installedVersion !== ""
                               ? root.svc.installedVersion
                               : String(root.svc.info.docsVersion || "what is installed")
                    var zip = String(root.svc.info.zipVersion || "")
                    if (root.svc.zipRelation === "newer")
                      return "Update waiting: " + zip + " is newer than " + have
                           + ". Install it from the Install tab — your projects are not touched."
                    if (root.svc.zipRelation === "older")
                      return "The newest ZIP in your Downloads is " + zip + ", older than the "
                           + have + " you have. Installing it would be a downgrade."
                    return ""
                  }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                visible: root.hasService && root.svc.installed && root.svc.zipRelation === "same"
                text: "Up to date — the ZIP in your Downloads is the build you are running."
              }

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Button {
                  text: "Launch Resolve"
                  bordered: true
                  enabled: root.hasService && root.svc.installed && !root.svc.busy
                  fontFamily: root.fontFamily
                  onClicked: { root.svc.launchResolve(); root.close() }
                }
                Button {
                  text: root.hasService && root.svc.installed ? "Reinstall" : "Install"
                  bordered: true
                  enabled: root.hasService && !root.svc.busy
                  fontFamily: root.fontFamily
                  onClicked: root.setTab(1)
                }
                Button {
                  text: root.hasService && root.svc.checking ? "Checking…" : "Re-check"
                  bordered: true
                  enabled: root.hasService && !root.svc.checking
                  fontFamily: root.fontFamily
                  onClicked: { root.svc.refresh(); root.svc.diagnose() }
                }
              }
            }
          }

          // =========================================================== INSTALL
          Flickable {
            anchors.fill: parent
            id: installFlick
            visible: root.tab === 1
            contentHeight: installColumn.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
              policy: installFlick.contentHeight > installFlick.height
                      ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            }
            onVisibleChanged: if (visible) contentY = 0

            Column {
              id: installColumn
              width: parent.width
              spacing: root.sectionGap

              // ---- running job ----
              Column {
                width: parent.width
                spacing: Style.spacing.sm
                visible: root.hasService && (root.svc.busy || root.svc.jobResult !== "")

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  text: {
                    if (!root.hasService) return ""
                    if (root.svc.busy) return root.svc.jobLabel !== "" ? root.svc.jobLabel : "Working…"
                    if (root.svc.jobResult === "ok") return "Finished"
                    if (root.svc.jobResult === "cancelled") return "Cancelled"
                    return "Failed"
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: height / 2
                  color: root.selBg

                  Rectangle {
                    width: parent.width * (root.hasService ? root.svc.jobProgress / 100 : 0)
                    height: parent.height
                    radius: height / 2
                    color: root.hasService && root.svc.jobResult === "failed" ? root.urgent : root.accent
                    Behavior on width { NumberAnimation { duration: 200 } }
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  visible: root.hasService && root.svc.lastError !== ""
                  text: root.hasService ? root.svc.lastError : ""
                }

                // Step list, newest last — the same steps the terminal prints.
                Repeater {
                  model: root.hasService ? root.svc.jobSteps : []
                  delegate: Row {
                    required property var modelData
                    width: installColumn.width
                    spacing: Style.spacing.sm

                    Text {
                      width: Style.space(14)
                      textFormat: Text.PlainText
                      text: root.stateGlyph(modelData.state)
                      color: root.stateColor(modelData.state === "start" ? "running" : modelData.state)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: installColumn.width - Style.space(22)
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: modelData.state === "start" ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Row {
                  spacing: Style.spacing.sm
                  Button {
                    text: "Show log"
                    bordered: true
                    fontFamily: root.fontFamily
                    onClicked: { root.logSource = "install"; root.setTab(3) }
                  }
                  Button {
                    text: root.hasService && root.svc.cancelling ? "Stopping…" : "Cancel"
                    bordered: true
                    visible: root.hasService && root.svc.busy
                    enabled: root.hasService && !root.svc.cancelling
                    foreground: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: root.svc.cancelJob()
                  }
                }
              }

              PanelSeparator {
                width: parent.width
                visible: root.hasService && (root.svc.busy || root.svc.jobResult !== "")
              }

              // ---- setup ----
              Column {
                width: parent.width
                spacing: Style.spacing.sm
                visible: root.hasService && !root.svc.busy

                PanelSectionHeader {
                  text: "INSTALLER ZIP"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  visible: root.hasService && root.svc.zips.length === 0
                  text: "No ZIP in " + (root.hasService ? String(root.svc.info.zipDir || "~/Downloads") : "~/Downloads")
                      + ". Blackmagic requires a form before download, so fetch it yourself from "
                      + "blackmagicdesign.com and drop it there."
                }

                Repeater {
                  model: root.hasService ? root.svc.zips : []
                  delegate: Rectangle {
                    required property var modelData
                    width: installColumn.width
                    height: Style.spacing.popupRowHeight
                    radius: root.cornerRadius
                    color: root.hasService && root.svc.selectedZip === modelData.path ? root.selBg : "transparent"

                    Row {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.spacing.sm
                      anchors.rightMargin: Style.spacing.sm
                      spacing: Style.spacing.sm

                      Text {
                        width: Style.space(14)
                        textFormat: Text.PlainText
                        text: root.hasService && root.svc.selectedZip === modelData.path ? "●" : "○"
                        color: root.hasService && root.svc.selectedZip === modelData.path ? root.accent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: modelData.edition + " " + modelData.version
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: Math.round(modelData.sizeMb / 1024 * 10) / 10 + " GB"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.svc.selectedZip = modelData.path
                    }
                  }
                }

                PanelSectionHeader {
                  text: "GPU"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // What the install will do about the card in this machine.
                // Said before the password prompt rather than after, because
                // on AMD it includes holding a package version back system
                // wide, and that is not a thing to discover afterwards.
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  text: {
                    if (!root.hasService) return ""
                    var s = root.svc
                    if (s.computeVendor === "" || s.computeVendor === "none")
                      return "No GPU detected. Resolve needs one — the install will not get you a working Resolve on this machine."
                    var who = s.vendorLabel + (s.computeName !== "" ? " " + s.computeName : "")
                    if (s.computeVendor === "nvidia")
                      return "Will set up for " + who + ", computing with CUDA from the installed driver. "
                           + "Nothing extra is installed for the GPU."
                    if (s.computeVendor === "amd")
                      return "Will set up for " + who + (s.computeGfx !== "" ? " (" + s.computeGfx + ")" : "")
                           + ", computing with ROCm OpenCL. ROCm 7.1.1 is downloaded from the Arch Linux Archive "
                           + "and held there with an IgnorePkg line in /etc/pacman.conf: later ROCm releases break "
                           + "Resolve, and a routine system update would otherwise stop it launching. Uninstall lifts the hold again."
                    if (s.computeVendor === "intel")
                      return "Will set up for " + who + ", computing with Intel's NEO OpenCL runtime. "
                           + "Blackmagic does not officially support Intel GPUs on Linux — editing and playback "
                           + "generally work, but the Neural Engine, some effects and noise reduction may fall back "
                           + "to the CPU or fail outright. Treat this as experimental."
                    return "Unrecognised GPU. Resolve needs an NVIDIA, AMD or Intel card."
                  }
                }

                PanelSectionHeader {
                  text: "OPTIONS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Toggle {
                  width: parent.width
                  label: "Set up snd-aloop"
                  description: "Virtual ALSA card. Without it Resolve's render can hang forever with no error."
                  checked: root.hasService ? root.svc.optAloop : true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.svc.optAloop = !root.svc.optAloop
                }

                Toggle {
                  width: parent.width
                  label: "Manage Hyprland window rules"
                  description: "Skipped automatically when Omarchy already ships them, which current versions do."
                  checked: root.hasService ? root.svc.optHyprRules : true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.svc.optHyprRules = !root.svc.optHyprRules
                }

                Toggle {
                  width: parent.width
                  label: "Install AAC Fix"
                  description: "Resolve on Linux cannot decode AAC, so phone and camera clips import silent. Adds Workspace › Scripts › Utility › AAC Fix and a resolve-aac-fix command to rewrap them."
                  checked: root.hasService ? root.svc.optAacFix : true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.svc.optAacFix = !root.svc.optAacFix
                }

                Toggle {
                  width: parent.width
                  label: "Dry run"
                  description: "Rehearse the whole thing: same password prompt, same progress, nothing written."
                  checked: root.hasService ? root.svc.optDryRun : false
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.svc.optDryRun = !root.svc.optDryRun
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  text: "You will be asked for your password once. Installing takes 10–20 minutes — "
                      + "most of it patching library paths — and keeps running if you close this panel. "
                      + "Cancelling during the system phase asks for the password a second time."
                }

                Row {
                  spacing: Style.spacing.sm

                  Button {
                    text: root.hasService && root.svc.optDryRun
                          ? "Preview install"
                          : (root.hasService && root.svc.installed ? "Reinstall Resolve" : "Install Resolve")
                    bordered: true
                    foreground: root.accent
                    fontFamily: root.fontFamily
                    enabled: root.hasService && root.svc.zips.length > 0 && !root.svc.busy
                    onClicked: root.svc.install()
                  }

                  Button {
                    text: root.confirmingUninstall ? "Really uninstall?" : "Uninstall"
                    bordered: true
                    foreground: root.confirmingUninstall ? root.urgent : root.dim
                    fontFamily: root.fontFamily
                    visible: root.hasService && root.svc.installed
                    enabled: root.hasService && !root.svc.busy
                    onClicked: {
                      if (!root.confirmingUninstall) { root.confirmingUninstall = true; return }
                      root.confirmingUninstall = false
                      root.svc.uninstall(false)
                    }
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  visible: root.confirmingUninstall
                  text: "Removes /opt/resolve, the launchers and the window rules. Your Project Library "
                      + "in ~/.local/share/DaVinciResolve is kept."
                }
              }
            }
          }

          // ============================================================ HEALTH
          Flickable {
            anchors.fill: parent
            id: healthFlick
            visible: root.tab === 2
            contentHeight: healthColumn.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
              policy: healthFlick.contentHeight > healthFlick.height
                      ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            }
            onVisibleChanged: if (visible) contentY = 0

            Column {
              id: healthColumn
              width: parent.width
              spacing: Style.spacing.sm

              Repeater {
                model: root.hasService ? root.svc.checks : []
                delegate: Column {
                  required property var modelData
                  width: healthColumn.width
                  spacing: Style.space(2)

                  Row {
                    width: parent.width
                    spacing: Style.spacing.sm

                    Text {
                      width: Style.space(14)
                      textFormat: Text.PlainText
                      text: root.stateGlyph(modelData.state)
                      color: root.stateColor(modelData.state)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }

                  Text {
                    x: Style.space(22)
                    width: healthColumn.width - Style.space(22)
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: modelData.detail
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              PanelSeparator { width: parent.width }

              PanelSectionHeader {
                text: "TESTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              // Hardware encode: rules out the driver before blaming Resolve.
              // NVENC on NVIDIA, VA-API on AMD and Intel — the engine picks
              // whichever this machine actually has.
              Button {
                text: root.hasService && root.svc.computeVendor === "nvidia"
                      ? "Test NVENC" : "Test hardware encoder"
                bordered: true
                fontFamily: root.fontFamily
                enabled: root.hasService && root.svc.nvencState !== "running"
                onClicked: root.svc.nvencTest()
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.hasService ? root.svc.nvencDetail : ""
                color: root.hasService ? root.stateColor(root.svc.nvencState) : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Codec probe. The limitation that actually bites on Linux is
              // audio: no AAC decoder, so an ordinary phone or camera file
              // imports with picture and silence and nothing says why.
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                text: "Check what Resolve will make of a clip. The Linux build has no AAC decoder, so an "
                    + "ordinary .mp4 imports with picture and no sound; H.264 and H.265 need Studio. "
                    + "ProRes and ProRes RAW are fine."
              }

              Button {
                text: "Choose a clip…"
                bordered: true
                fontFamily: root.fontFamily
                enabled: root.hasService && root.svc.probeState !== "running"
                onClicked: root.svc.pickFileToProbe()
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                visible: text !== ""
                text: root.hasService && root.svc.probeDetail !== ""
                      ? root.svc.probeFile + ": " + root.svc.probeDetail : ""
                color: root.hasService ? root.stateColor(root.svc.probeState) : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                spacing: Style.spacing.sm
                Button {
                  text: root.hasService && root.svc.diagnosing ? "Checking…" : "Re-run checks"
                  bordered: true
                  fontFamily: root.fontFamily
                  enabled: root.hasService && !root.svc.diagnosing
                  onClicked: root.svc.diagnose()
                }
                Button {
                  text: "Open log folder"
                  bordered: true
                  fontFamily: root.fontFamily
                  onClicked: { root.svc.openLogFolder(); root.close() }
                }
              }
            }
          }

          // =============================================================== LOG
          Item {
            anchors.fill: parent
            visible: root.tab === 3

            Column {
              anchors.fill: parent
              spacing: Style.spacing.sm

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                Button {
                  text: "Install log"
                  bordered: true
                  selected: root.logSource === "install"
                  fontFamily: root.fontFamily
                  onClicked: root.logSource = "install"
                }
                Button {
                  text: "Resolve log"
                  bordered: true
                  selected: root.logSource === "resolve"
                  fontFamily: root.fontFamily
                  onClicked: { root.logSource = "resolve"; root.svc.tailLogs() }
                }
              }

              Flickable {
                id: logFlick
                width: parent.width
                height: parent.height - y
                contentHeight: logText.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {
                  policy: logFlick.contentHeight > logFlick.height
                          ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                }

                // Follow the tail while a job is running, but stop fighting the
                // user the moment they scroll back to read something.
                property bool follow: true
                onContentHeightChanged: if (follow) contentY = Math.max(0, contentHeight - height)
                onMovementStarted: follow = false

                Text {
                  id: logText
                  width: logFlick.width
                  wrapMode: Text.NoWrap
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  text: {
                    if (!root.hasService) return ""
                    if (root.logSource === "resolve") return root.svc.logTail
                    return root.svc.logLines.length > 0
                      ? root.svc.logLines.join("\n")
                      : "Nothing yet. The install log appears here while Resolve is installing."
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Host contract: the shell calls open()/close() and reads `opened`.
  // `show` additionally picks a tab, so a keybinding or script can go straight
  // to the health checks:  omarchy-shell nosignal.davinci-resolve show health
  IpcHandler {
    target: "nosignal.davinci-resolve"
    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function show(tab: string): void {
      root.open("{}")
      var names = ["status", "install", "health", "log"]
      var i = names.indexOf(String(tab || "").toLowerCase())
      if (i >= 0) root.setTab(i)
    }
  }
}
