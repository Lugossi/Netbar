pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: netbar
  moduleName: "lugossi.netbar"
  ipcTarget: "lugossi.netbar"

  manageIpc: false

  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    return decodeURIComponent(u).replace(/\/+$/, "")
  }

  property string query: ""
  property int selectedIndex: 0
  property bool cursorActive: false

  property string pendingKillKey: ""
  property string pendingForceKey: ""
  property bool pendingKillAll: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var filtered: {
    var out = []
    var list = svc.listed
    for (var i = 0; i < list.length; i++) {
      if (Model.matches(list[i], netbar.query)) out.push(list[i])
    }
    return out
  }

  readonly property var selectedEntry: {
    if (filtered.length === 0) return null
    return filtered[Math.max(0, Math.min(selectedIndex, filtered.length - 1))]
  }

  readonly property bool hideWhenIdle: String(setting("hideWhenIdle", false)) === "true"
  readonly property bool dockerPrompt: String(setting("dockerPrompt", true)) !== "false"

  readonly property string barLabel: {
    var glyph = ""
    return svc.strayCount > 0 ? glyph + " " + svc.strayCount : glyph
  }

  readonly property string heroMeta: {
    if (!svc.everScanned) return "Scanning…"
    if (svc.lastError !== "") return svc.lastError
    var bits = []
    bits.push(svc.strayCount === 1 ? "1 dev server" : svc.strayCount + " dev servers")
    if (svc.exposedStrayCount > 0) bits.push(svc.exposedStrayCount + " exposed")
    if (svc.ignoredCount > 0) bits.push(svc.ignoredCount + " ignored")
    return bits.join("  ·  ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: !hideWhenIdle || svc.strayCount > 0 || opened

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      selectedIndex = 0
      query = ""
      pendingKillKey = ""
      pendingForceKey = ""
      pendingKillAll = false
      if (panelFlick) panelFlick.contentY = 0
      svc.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      pendingKillKey = ""
      pendingForceKey = ""
      pendingKillAll = false
    }
  }

  onFilteredChanged: {
    if (selectedIndex >= filtered.length) selectedIndex = Math.max(0, filtered.length - 1)
  }

  function isPrimaryInstance() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var items = bar.moduleWidgets(moduleName)
    return items.length === 0 || items[0] === netbar
  }

  Service {
    id: svc
    settings: netbar.settings
    pluginDir: netbar.pluginDir
    active: netbar.opened
    ownsSideEffects: function() { return netbar.isPrimaryInstance() }
    onPortsUpdated: function(payload) { netbar.pushToPeers(payload) }
  }

  function pushToPeers(payload) {
    if (!bar || typeof bar.moduleWidgets !== "function") return
    var items = bar.moduleWidgets(moduleName)
    for (var i = 0; i < items.length; i++) {
      if (items[i] !== netbar && typeof items[i].receiveScan === "function") {
        items[i].receiveScan(payload)
      }
    }
  }

  function receiveScan(payload) { svc.adoptScan(payload) }

  IpcHandler {
    target: netbar.ipcTarget
    function open(): void { netbar.open() }
    function close(): void { netbar.close() }
    function show(): void { netbar.open() }
    function hide(): void { netbar.close() }
    function toggle(): void { netbar.toggle() }
    function refresh(): string { svc.refresh(); return "ok" }
    function killAll(): string { svc.killAllStrays(); return "ok" }
    function count(): string { return String(svc.strayCount) }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || filtered.length === 0) return
    selectedIndex = Math.max(0, Math.min(filtered.length - 1, selectedIndex + dy))
    scrollSelectedIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    selectedIndex = index
  }

  function scrollSelectedIntoView() {
    if (!panelFlick || !rowColumn) return
    if (selectedIndex < 0 || selectedIndex >= rowColumn.children.length) return
    var item = rowColumn.children[selectedIndex]
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function requestKill(entry, force) {
    if (!entry) return
    if (entry.canKill === false) {
      svc.actionStatus = "Port " + entry.port + " is held by "
        + (entry.user || "another user") + " — NetBar cannot signal it."
      return
    }
    if (!entry.isDev && pendingKillKey !== entry.key) {
      pendingKillKey = entry.key
      pendingKillAll = false
      confirmTimer.restart()
      return
    }
    pendingKillKey = ""
    pendingForceKey = ""
    svc.terminate(entry, force)
  }

  function requestForceKill(entry) {
    if (!entry) return
    if (entry.canKill === false) {
      svc.actionStatus = "Port " + entry.port + " is held by "
        + (entry.user || "another user") + " — NetBar cannot signal it."
      return
    }
    if (entry.container) {
      svc.terminate(entry, false)
      return
    }
    if (pendingForceKey !== entry.key) {
      pendingForceKey = entry.key
      pendingKillKey = ""
      pendingKillAll = false
      confirmTimer.restart()
      return
    }
    pendingForceKey = ""
    svc.terminate(entry, true)
  }

  function requestKillAll() {
    if (svc.strayCount === 0) return
    if (!pendingKillAll) {
      pendingKillAll = true
      pendingKillKey = ""
      confirmTimer.restart()
      return
    }
    pendingKillAll = false
    svc.killAllStrays()
  }

  function activateSelected() {
    var e = selectedEntry
    if (e && Model.isWebLike(e)) svc.openUrl(e)
  }

  Timer {
    id: confirmTimer
    interval: 4000
    repeat: false
    onTriggered: {
      netbar.pendingKillKey = ""
      netbar.pendingForceKey = ""
      netbar.pendingKillAll = false
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: netbar.bar
    text: netbar.barLabel
    fontSize: Style.font.body

    active: svc.exposedStrayCount > 0
    tooltipText: Model.barTooltip(svc.strayCount, svc.exposedStrayCount, svc.ignoredCount)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) svc.refresh()
      else netbar.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: netbar
    bar: netbar.bar
    open: netbar.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      blocked: search.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!netbar.cursorActive) { netbar.cursorActive = true; return }
        netbar.moveCursor(dx, dy)
      }
      onActivateRequested: if (netbar.cursorActive) netbar.activateSelected()
      onCloseRequested: netbar.close()
      onDeleteRequested: netbar.requestKill(netbar.selectedEntry, false)
      onTabRequested: function(direction) { netbar.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") { search.forceActiveFocus() }
        else if (t === "r" || t === "R") svc.refresh()
        else if (t === "o" || t === "O") netbar.activateSelected()
        else if (t === "c" || t === "C") svc.copyUrl(netbar.selectedEntry)
        else if (t === "i" || t === "I") svc.toggleIgnore(netbar.selectedEntry)
        else if (t === "s" || t === "S") svc.showSystem = !svc.showSystem
        else if (t === "f" || t === "F") netbar.requestForceKill(netbar.selectedEntry)
        else if (t === "a" || t === "A") netbar.requestKillAll()
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
            id: hero
            width: parent.width
            title: "Ports"
            meta: netbar.heroMeta
            foreground: netbar.foreground
            fontFamily: netbar.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""
                color: svc.exposedStrayCount > 0 ? netbar.urgent : netbar.foreground
                font.family: netbar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: ""
                tooltipText: "Rescan now"
                foreground: netbar.foreground
                fontFamily: netbar.fontFamily
                enabled: !svc.loading
                onClicked: svc.refresh()
              }
            }
          }

          TextField {
            id: search
            width: parent.width
            foreground: netbar.foreground
            placeholderText: "Filter by port, process, or project…"
            text: netbar.query
            onTextChanged: netbar.query = text
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text.length > 0) text = ""
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                keyCatcher.forceActiveFocus()
                netbar.cursorActive = true
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                keyCatcher.forceActiveFocus()
                netbar.cursorActive = true
                netbar.activateSelected()
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: svc.actionStatus !== ""
            width: parent.width
            text: svc.actionStatus
            color: netbar.dim
            font.family: netbar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: netbar.filtered.length === 0
            width: parent.width
            text: {
              if (!svc.everScanned) return "Scanning…"
              if (netbar.query !== "") return "Nothing matches “" + netbar.query + "”."
              return "No dev servers listening. Nothing to clean up."
            }
            color: netbar.dim
            font.family: netbar.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: netbar.filtered
              PortRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                entry: modelData
                rowIndex: index
              }
            }
          }

          PanelSeparator {
            visible: netbar.filtered.length > 0
            foreground: netbar.foreground
          }

          RowLayout {
            visible: svc.dockerNeedsEnable && netbar.dockerPrompt
            width: parent.width
            spacing: Style.space(8)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Docker is running, but NetBar can't read it"
                color: netbar.foreground
                font.family: netbar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Grants one narrow sudo rule, not docker-group access"
                color: netbar.dim
                font.family: netbar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Button {
              text: svc.dockerBusy ? "Authorizing…" : "Enable"
              enabled: !svc.dockerBusy
              onClicked: svc.enableDocker()
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "↵ open · c copy · i ignore · x kill · f force"
              color: netbar.dim
              font.family: netbar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              visible: svc.strayCount > 0
              text: netbar.pendingKillAll
                ? "Press again to confirm"
                : "Kill all " + svc.strayCount
              onClicked: netbar.requestKillAll()
            }
          }
        }
      }
    }
  }

  component PortRow: CursorSurface {
    id: portRow
    property var entry: null
    property int rowIndex: 0

    readonly property bool ignoredRow: svc.isIgnored(entry)
    readonly property bool exposed: Model.isExposed(entry)
    readonly property bool confirming: netbar.pendingKillKey === (entry ? entry.key : "")
    readonly property bool confirmingForce: netbar.pendingForceKey === (entry ? entry.key : "")

    readonly property bool forceOffered: !!entry && svc.termedKeys[entry.key] === true
    readonly property bool webLike: Model.isWebLike(entry)

    hasCursor: netbar.cursorActive && netbar.selectedIndex === rowIndex
    foreground: netbar.foreground
    opacity: ignoredRow ? 0.55 : 1.0
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: portRow.webLike ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: netbar.setCursor(portRow.rowIndex)
      onClicked: function(mouse) {
        netbar.setCursor(portRow.rowIndex)
        if (mouse.button === Qt.MiddleButton) svc.copyUrl(portRow.entry)
        else if (portRow.webLike) svc.openUrl(portRow.entry)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(9)

      Text {
        textFormat: Text.PlainText
        text: Model.kindGlyph(portRow.entry ? portRow.entry.kind : "other")
        color: netbar.foreground
        font.family: netbar.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(7)

          Text {
            textFormat: Text.PlainText
            text: portRow.entry ? String(portRow.entry.port) : ""
            color: netbar.foreground
            font.family: netbar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.titleFor(portRow.entry)
            color: netbar.foreground
            font.family: netbar.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: portRow.exposed
            text: Model.exposureGlyph(portRow.entry ? portRow.entry.exposure : "local")
              + " " + Model.exposureShort(portRow.entry ? portRow.entry.exposure : "local")
            color: netbar.urgent
            font.family: netbar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            visible: portRow.ignoredRow
            text: "IGNORED"
            color: netbar.dim
            font.family: netbar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            if (portRow.confirmingForce) return "SIGKILL — press f again to confirm"
            if (portRow.confirming) return "Not clearly yours — press again to kill"
            if (portRow.forceOffered) return "Ignored SIGTERM — click ✕ again to force"
            return Model.subtitle(portRow.entry)
          }
          color: portRow.confirming || portRow.confirmingForce || portRow.forceOffered
            ? netbar.urgent : netbar.dim
          font.family: netbar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: ""
        tooltipText: "Open " + Model.urlFor(portRow.entry)
        visible: portRow.webLike
        foreground: netbar.foreground
        fontFamily: netbar.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: svc.openUrl(portRow.entry)
      }

      PanelActionButton {
        iconText: ""
        tooltipText: "Copy " + Model.urlFor(portRow.entry)
        visible: portRow.webLike
        foreground: netbar.foreground
        fontFamily: netbar.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: svc.copyUrl(portRow.entry)
      }

      PanelActionButton {
        iconText: portRow.ignoredRow ? "" : ""
        tooltipText: portRow.ignoredRow
          ? "Stop ignoring port " + (portRow.entry ? portRow.entry.port : "")
          : "Always expect port " + (portRow.entry ? portRow.entry.port : "") + " — stop counting it"
        foreground: netbar.foreground
        fontFamily: netbar.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: svc.toggleIgnore(portRow.entry)
      }

      PanelActionButton {
        iconText: portRow.forceOffered ? "" : ""

        enabled: !!portRow.entry && portRow.entry.canKill !== false
        tooltipText: {
          if (!portRow.entry) return ""
          if (portRow.entry.container) return "docker stop " + portRow.entry.container.name
          if (portRow.entry.canKill === false) {
            var owner = String(portRow.entry.user || "another user")
            return "Held by " + owner + " — NetBar cannot signal it"
          }
          if (portRow.forceOffered) return "Still running — force kill (SIGKILL)"
          return portRow.confirming ? "Press again to confirm" : "Stop this process (SIGTERM)"
        }
        foreground: portRow.confirming || portRow.forceOffered ? netbar.urgent : netbar.foreground
        hoverColor: netbar.urgent
        fontFamily: netbar.fontFamily
        Layout.alignment: Qt.AlignVCenter

        onClicked: netbar.requestKill(portRow.entry, portRow.forceOffered)
      }
    }
  }
}
