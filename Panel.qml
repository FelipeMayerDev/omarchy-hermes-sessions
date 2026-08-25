import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hermes Sessions bar widget for Omarchy.
// Shows what the Hermes agent is doing now and lists past sessions;
// clicking a session reopens it in a hermes --tui terminal.
Panel {
  id: root
  moduleName: "kelso.hermes-sessions"
  ipcTarget: "kelso.hermes-sessions"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Log tag for console.warn lines — grep-able in the shell journal.
  readonly property string logTag: "hermes-sessions"

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ------------------------------------------------------------- data

  property var snapshot: null
  property bool loading: false

  readonly property var sessions: snapshot ? (snapshot.sessions || []) : []
  readonly property var active: snapshot ? snapshot.active : null

  // Keyboard-driven single highlight, per the CursorSurface contract:
  // one row lit at any time, shared by mouse hover and arrow keys.
  // newSessionFocused routes ↑/↵ to the primary action above the list.
  property bool cursorActive: false
  property bool newSessionFocused: false
  property int focusedIndex: 0

  property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 30)))

  // A sane snapshot is 8 rows × ~250B ≈ 2KB; 8× headroom covers wider
  // panels and longer titles. Anything bigger means the helper broke —
  // show the stale snapshot rather than parsing unbounded input into
  // the long-lived shell process.
  readonly property int maxSnapshotBytes: 16384

  // The helper caps the query at 8 rows; the panel renders exactly that.
  readonly property var visibleSessions: sessions.slice(0, 8)

  function refresh() {
    if (snapshotProcess.running) return
    loading = true
    snapshotProcess.command = [scriptPath("snapshot.sh")]
    snapshotProcess.running = true
  }

  // Companion scripts live beside this QML file; resolve relative to it so
  // the whole plugin works from any install location.
  function scriptPath(name) {
    return Qt.resolvedUrl("scripts/" + name).toString().replace(/^file:\/\//, "")
  }

  Process {
    id: snapshotProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        // Seatbelt against a misbehaving helper (see maxSnapshotBytes).
        if (String(text).length > root.maxSnapshotBytes) {
          console.warn(root.logTag, "snapshot too large, discarded:", String(text).length, "bytes")
          return
        }
        try {
          root.snapshot = JSON.parse(String(text))
        } catch (e) {
          console.warn(root.logTag, "bad snapshot", e)
        }
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn(root.logTag, String(text).trim())
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps relative timestamps ("12m ago") honest while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
  property double nowMs: Date.now()

  onOpenedChanged: if (opened) {
    root.cursorActive = false
    root.focusedIndex = 0
    root.refresh()
    if (listFlick) listFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openSession(sessionId) {
    if (!sessionId) return
    console.warn(root.logTag, "openSession requested:", sessionId)
    // Per-session app-id: omarchy-launch-or-focus matches windows by this id,
    // so each session gets (and later re-focuses) its own terminal instead of
    // all clicks landing on whichever session window was opened first.
    var appId = "hermes-tui-" + String(sessionId)
    var command = ["omarchy-launch-or-focus-tui", "--app-id=" + appId,
                   scriptPath("hermes-tui-session"), String(sessionId)]
    Quickshell.execDetached(command)
    root.close()
  }

  function launchNewSession() {
    console.warn(root.logTag, "launchNewSession requested")
    // Unique app-id per click so every new-session request opens a fresh
    // terminal instead of focusing an existing one.
    var appId = "hermes-tui-new-" + Date.now()
    var command = ["omarchy-launch-or-focus-tui", "--app-id=" + appId,
                   scriptPath("hermes-tui-session")]
    Quickshell.execDetached(command)
    root.close()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ------------------------------------------------------------ helpers

  function statusLine() {
    if (!root.snapshot) return "Checking…"
    if (!active) return "Idle — no recent activity"
    if (active.live) return "Working"
    return "Last seen " + relativeTime(active.lastActiveTs)
  }

  function relativeTime(ts) {
    // nowMs is ms since epoch; snapshot timestamps are seconds.
    var nowSec = nowMs / 1000
    var d = Math.max(0, nowSec - Number(ts || 0))
    if (d < 90) return "just now"
    if (d < 3600) return Math.floor(d / 60) + "m ago"
    if (d < 86400) return Math.floor(d / 3600) + "h ago"
    return Math.floor(d / 86400) + "d ago"
  }

  function workspaceShort(s) {
    var p = String(s.cwd || "").replace(/^\/home\/[^\/]+/, "~")
    // A workspace reads best as its folder name; the full path is the tooltip.
    var parts = p.split("/").filter(function(x) { return x !== "" })
    return parts.length > 0 ? parts[parts.length - 1] : p
  }

  function sessionSubtitle(s) {
    var parts = []
    parts.push(workspaceShort(s))
    if (String(s.model || "") !== "") parts.push(s.model)
    parts.push(s.messages + " msg" + (s.messages === 1 ? "" : "s"))
    return parts.join(" · ")
  }

  // Nothing to show → collapse out of the bar entirely.
  visible: sessions.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    active: !!root.active && root.active.live
    // Active state tints the glyph with the theme accent instead of the
    // default urgent/red.
    activeColor: root.accent
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy === 0 || root.visibleSessions.length === 0) return
        var count = root.visibleSessions.length
        if (dy < 0) {
          // Up: step into the list from the button, or walk up; at the top
          // the highlight lands back on the New-session button.
          if (!root.cursorActive) {
            root.cursorActive = true
            root.newSessionFocused = false
            root.focusedIndex = count - 1
          } else if (root.focusedIndex > 0) {
            root.focusedIndex--
          } else if (root.newSessionFocused) {
            root.cursorActive = false
          } else {
            root.newSessionFocused = true
          }
        } else {
          // Down: from the button into the first row, or walk down.
          if (root.newSessionFocused) {
            root.newSessionFocused = false
            root.cursorActive = true
            root.focusedIndex = 0
          } else if (!root.cursorActive) {
            root.cursorActive = true
            root.newSessionFocused = false
            root.focusedIndex = 0
          } else if (root.focusedIndex < count - 1) {
            root.focusedIndex++
          }
        }
        // Keep the focused row visible (contentY is px, rows ~52px tall).
        var rowTop = (root.focusedIndex + 1) * Style.space(52)
        var rowBottom = rowTop + Style.space(52)
        if (rowTop < listFlick.contentY)
          listFlick.contentY = Math.max(0, rowTop - Style.space(8))
        else if (rowBottom > listFlick.contentY + listFlick.height)
          listFlick.contentY = Math.min(listFlick.contentHeight - listFlick.height,
                                        rowBottom - listFlick.height + Style.space(8))
      }
      onCloseRequested: root.close()
      onActivateRequested: {
        if (root.newSessionFocused) launchNewSession()
        else if (cursorActive && focusedIndex < visibleSessions.length)
          openSession(visibleSessions[focusedIndex].id)
        else
          launchNewSession()
      }

      Flickable {
        id: listFlick
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
          // Inset from the Flickable's clip edge: CursorSurface borders are
          // drawn inside each row's own bounds, and a zero left margin puts
          // that edge exactly on the clip line where it gets shaved off.
          x: Style.space(6)
          width: listFlick.width - Style.space(12)
          spacing: Style.space(14)

          // ---------- Hero: identity + live status ----------
          PanelHero {
            width: parent.width
            title: "Hermes Agent"
            meta: root.statusLine()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                // Pulse only while Hermes is actively working — status you
                // can read from across the room, silent when idle.
                Rectangle {
                  id: pulseDot
                  anchors.centerIn: parent
                  width: 12; height: 12; radius: 6
                  color: root.active && root.active.live ? root.accent : root.dim
                  opacity: root.active && root.active.live ? 1.0 : 0.55

                  SequentialAnimation on scale {
                    running: !!root.active && root.active.live && root.opened
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.35; duration: 900; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
                  }
                  SequentialAnimation on opacity {
                    running: !!root.active && root.active.live && root.opened
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
                  }
                }
              }
            }
          }

          Text {
            visible: !!root.active
            width: parent.width
            text: root.active ? root.active.title : ""
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // ---------- Primary action ----------
          BorderSurface {
            width: parent.width
            implicitHeight: newSessionRow.implicitHeight + Style.space(18)
            color: newSessionMouse.containsMouse || root.newSessionFocused
              ? root.alpha(root.accent, 0.16)
              : root.alpha(root.accent, 0.08)
            borderSpec: Border.flat(root.alpha(root.accent, root.newSessionFocused ? 0.9 : 0.45), 1)
            radius: Style.cornerRadius

            Behavior on color { ColorAnimation { duration: 60 } }

            MouseArea {
              id: newSessionMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launchNewSession()
            }

            Row {
              id: newSessionRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                text: "󰐕"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                width: parent.width - 34
                text: "New session"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                width: 30
                text: "↵"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // ---------- Recent sessions ----------
          PanelSectionHeader {
            width: parent.width
            text: root.visibleSessions.length > 0
              ? "RECENT SESSIONS · ↵ OPEN · ↑↓ NAVIGATE"
              : "RECENT SESSIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.visibleSessions

            delegate: CursorSurface {
              id: row
              required property var modelData
              required property int index

              hasCursor: root.cursorActive && index === root.focusedIndex
              current: modelData.live
              bordered: false
              foreground: root.foreground
              accent: root.accent

              width: parent.width
              implicitHeight: sessionColumn.implicitHeight + Style.space(20)

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor

                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusedIndex = index
                }

                onClicked: root.openSession(modelData.id)
              }

              Column {
                id: sessionColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(3)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Rectangle {
                    visible: modelData.live
                    width: 7; height: 7; radius: 3.5
                    color: root.accent
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    width: parent.width - (modelData.live ? 13 : 0) - ageLabel.width - latestPill.width - Style.space(12)
                    text: modelData.title
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Marks the newest session in the list.
                  Rectangle {
                    id: latestPill
                    visible: index === 0
                    radius: height / 2
                    width: latestText.implicitWidth + Style.space(10)
                    height: latestText.implicitHeight + Style.space(4)
                    color: root.alpha(root.accent, 0.18)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: latestText
                      anchors.centerIn: parent
                      text: "LATEST"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption - 1 > 8 ? Style.font.caption - 1 : 8
                      font.letterSpacing: 0.5
                    }
                  }

                  Text {
                    id: ageLabel
                    text: root.relativeTime(modelData.lastActiveTs)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    width: parent.width
                    text: root.sessionSubtitle(modelData)
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              PanelToolTip {
                visible: rowMouse.containsMouse
                text: modelData.cwd
                fontFamily: root.fontFamily
              }
            }
          }

          Text {
            visible: root.visibleSessions.length === 0 && !root.loading
            width: parent.width
            topPadding: Style.space(24)
            text: root.snapshot
              ? "No sessions yet.\nStart one with the button above."
              : "Checking for sessions…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Item {
            // breathing room at the bottom of the scroll
            width: parent.width
            height: Style.space(2)
          }
        }
      }
    }
  }
}
