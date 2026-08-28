import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget entry point: the colour-coded icon plus the session panel.
// Pure view — every fact it renders comes from the shared Service singleton,
// so all monitors show the same state (§8.5). The bar shows a colour and
// never a hostname; destinations only appear in the tooltip and the panel.
Panel {
  id: root
  moduleName: "io.github.CHANGEME.sshwatch"
  ipcTarget: "io.github.CHANGEME.sshwatch"
  manageIpc: false

  // The shared service (kind: service in the same manifest). The lookup
  // binding re-evaluates when the shell registers services, so load order
  // does not matter.
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("io.github.CHANGEME.sshwatch") : null

  // Settings live on this widget's shell.json entry; the service applies
  // them. Every instance pushes the same values, so this is idempotent.
  function pushSettings() { if (svc) svc.applySettings(settings) }
  onSvcChanged: pushSettings()
  onSettingsChanged: pushSettings()
  Component.onCompleted: pushSettings()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function mixColor(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1.0)
  }

  // §8.1 — colours derive from the active theme, never hard-coded hex.
  // "Stale" sits between the normal foreground and the urgent colour so it
  // reads as a warning without claiming the error state.
  readonly property string iconState: svc ? svc.barState : "error"
  readonly property color barIconColor: {
    var fg = bar ? bar.barForeground : Color.foreground
    var urg = bar ? bar.urgent : Color.urgent
    if (iconState === "error") return urg
    if (iconState === "stale") return mixColor(fg, urg, 0.6)
    if (iconState === "idle") return Qt.darker(fg, 1.8)
    return fg
  }

  readonly property var activeSessions: svc ? svc.sessions : []
  readonly property var recentEntries: svc ? svc.recent.slice(0, svc.recentCount) : []
  readonly property bool showRecent: svc && svc.recentCount > 0 && recentEntries.length > 0
  readonly property double nowSec: svc ? svc.nowSec : 0

  // Keyboard cursor over the ACTIVE rows (§8.4: Esc r arrows Enter y).
  property int sessionIndex: 0
  property bool cursorActive: false

  function clampCursor() {
    if (sessionIndex >= activeSessions.length) sessionIndex = Math.max(0, activeSessions.length - 1)
    if (sessionIndex < 0) sessionIndex = 0
  }

  function selectedSession() {
    if (activeSessions.length === 0) return null
    return activeSessions[Math.max(0, Math.min(sessionIndex, activeSessions.length - 1))]
  }

  function moveCursor(dy) {
    if (activeSessions.length === 0) return
    cursorActive = true
    sessionIndex = Math.max(0, Math.min(activeSessions.length - 1, sessionIndex + dy))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    sessionIndex = index
  }

  function focusSelected() {
    var session = selectedSession()
    if (session && svc) svc.focusSession(session)
  }

  function copySelected() {
    var session = selectedSession()
    if (session && svc) svc.copySshCommand(session)
  }

  function rescan() { if (svc) svc.rescan() }

  function scrollCursorIntoView() {
    if (!sessionColumn || sessionIndex < 0 || sessionIndex >= sessionColumn.children.length) return
    var item = sessionColumn.children[sessionIndex]
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    sessionIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    rescan()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onActiveSessionsChanged: clampCursor()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.rescan(); return "ok" }
  }

  // --- bar icon ----------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.svc ? root.svc.tooltip : "SSH Watch service is not loaded"
    iconComponent: Component {
      Item {
        SshIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          badgeColor: root.urgent
          showBadge: root.iconState === "error"
        }
      }
    }
    onPressed: function(buttonCode) {
      // Right click stays unbound: decision 13 forbids a destructive quick
      // action, and there is no non-destructive one worth a mystery binding.
      if (buttonCode === Qt.MiddleButton) root.rescan()
      else if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  // --- panel -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.focusSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.rescan()
        else if (t === "y" || t === "Y") root.copySelected()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "SSH Watch"
            meta: {
              if (!root.svc) return "Service is not loaded — re-enable the plugin"
              if (!root.svc.ok) return "Scan failed"
              if (root.activeSessions.length === 0) return "No outgoing SSH connections"
              if (root.activeSessions.length === 1) return "1 outgoing SSH connection"
              return root.activeSessions.length + " outgoing SSH connections"
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              SshIcon {
                iconSize: Style.font.display
                color: root.iconState === "error" ? root.urgent : root.foreground
                badgeColor: root.urgent
                showBadge: root.iconState === "error"
              }
            }
          }

          // --- ACTIVE ---------------------------------------------------

          Column {
            visible: root.activeSessions.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACTIVE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: sessionColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.activeSessions
                SessionRow {
                  required property var modelData
                  required property int index
                  width: sessionColumn.width
                  session: modelData
                  rowIndex: index
                }
              }
            }
          }

          // --- RECENT ---------------------------------------------------

          PanelSeparator {
            visible: root.showRecent
            foreground: root.foreground
          }

          Column {
            visible: root.showRecent
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "RECENT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.recentEntries
                Text {
                  required property var modelData
                  width: parent.width
                  text: Model.recentLine(modelData, root.nowSec)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  leftPadding: Style.space(10)
                }
              }
            }
          }

          // --- footer -----------------------------------------------------

          Text {
            visible: root.svc !== null && root.svc.lastError !== ""
            width: parent.width
            text: root.svc ? root.svc.lastError : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // --- components ----------------------------------------------------------

  // Terminal-prompt mark, drawn natively: Qt's SVG rendering is unreliable in
  // tiny bar slots, and a drawn mark recolours with the theme for free.
  component SshIcon: Item {
    id: icon

    property real iconSize: Style.font.icon
    property color color: Color.foreground
    property color badgeColor: Color.urgent
    property bool showBadge: false

    width: iconSize
    height: iconSize
    implicitWidth: iconSize
    implicitHeight: iconSize

    readonly property real stroke: Math.max(1.5, iconSize * 0.14)

    // Chevron ">" — two strokes meeting at the point.
    Rectangle {
      x: icon.iconSize * 0.04
      y: icon.iconSize * 0.22
      width: icon.iconSize * 0.46
      height: icon.stroke
      radius: height / 2
      color: icon.color
      rotation: 38
      transformOrigin: Item.Left
    }
    Rectangle {
      x: icon.iconSize * 0.04
      y: icon.iconSize * 0.78
      width: icon.iconSize * 0.46
      height: icon.stroke
      radius: height / 2
      color: icon.color
      rotation: -38
      transformOrigin: Item.Left
    }

    // Cursor underscore.
    Rectangle {
      x: icon.iconSize * 0.55
      y: icon.iconSize * 0.78
      width: icon.iconSize * 0.42
      height: icon.stroke
      radius: height / 2
      color: icon.color
    }

    Rectangle {
      visible: icon.showBadge
      width: Math.max(6, icon.iconSize * 0.42)
      height: width
      radius: width / 2
      color: icon.badgeColor
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: -width * 0.25
      anchors.topMargin: -width * 0.25

      Text {
        anchors.centerIn: parent
        text: "!"
        color: Color.background
        font.family: Style.font.family
        font.pixelSize: Math.max(5, parent.height * 0.72)
        font.bold: true
      }
    }
  }

  component SessionRow: CursorSurface {
    id: row

    property var session: null
    property int rowIndex: 0
    readonly property bool stale: root.svc
      ? Model.isStale(session, root.nowSec, root.svc.staleAfterHours) : false
    readonly property string duration: session
      ? Model.formatDuration(root.nowSec - session.startedAt) : ""
    readonly property var forwardLines: {
      if (!session || !root.svc || !root.svc.showForwards) return []
      var lines = []
      for (var i = 0; i < session.forwards.length; i++)
        lines.push(Model.forwardLine(session.forwards[i]))
      var flags = Model.flagLine(session)
      if (flags !== "") lines.push(flags)
      return lines
    }

    hasCursor: root.cursorActive && root.sessionIndex === rowIndex
    foreground: root.foreground

    implicitHeight: rowInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.setCursor(row.rowIndex)
    }

    RowLayout {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            visible: row.stale
            text: "⚠"
            color: root.mixColor(root.foreground, root.urgent, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            Layout.fillWidth: true
            text: row.session ? Model.rowTitle(row.session) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            text: row.duration
            color: row.stale ? root.mixColor(root.foreground, root.urgent, 0.6) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          Layout.fillWidth: true
          text: row.session ? Model.rowSubtitle(row.session) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Repeater {
          model: row.forwardLines
          Text {
            required property string modelData
            Layout.fillWidth: true
            text: modelData
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            leftPadding: Style.space(12)
          }
        }
      }

      PanelActionButton {
        iconText: "↗"
        tooltipText: row.session && row.session.focusable
          ? "Focus terminal window"
          : "No window to focus (" + (row.session ? row.session.ownerKind : "unknown") + ")"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: row.session ? row.session.focusable === true : false
        opacity: enabled ? 1.0 : 0.35
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (root.svc) root.svc.focusSession(row.session)
      }

      PanelActionButton {
        iconText: "󰆏"
        tooltipText: row.session ? "Copy `" + Model.copyCommand(row.session) + "`" : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (root.svc) root.svc.copySshCommand(row.session)
      }
    }
  }
}
