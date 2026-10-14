import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Commons as Commons

// YouTube Music in a bar panel. Lookups (search, radio, library) run through
// bin/ytm-helper on the plugin's private ytmusicapi; playback is a background
// mpv (bin/ytm-mpv) driven over its JSON IPC socket, so music keeps playing
// while the shell reloads. The queue is mpv's own playlist: this panel only
// remembers the metadata of each entry, keyed by video id.
Panel {
  id: root
  moduleName: "nicola.ytmusic"
  ipcTarget: "nicola.ytmusic"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/nicola.ytmusic"
  readonly property string python: home + "/.local/share/nicola-ytmusic/venv/bin/python"
  readonly property string helper: pluginDir + "/bin/ytm-helper"
  readonly property string stateDir: home + "/.local/state/nicola-ytmusic"
  readonly property string socketPath: Quickshell.env("XDG_RUNTIME_DIR") + "/nicola-ytmusic.sock"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ player state
  property bool paused: true
  property bool idle: true
  property real position: 0
  property real duration: 0
  property int playlistPos: -1
  property var playlistIds: []      // video id of each mpv playlist entry
  property var meta: ({})           // video id -> track
  property bool radio: true
  property bool radioLoading: false
  property var pendingLines: []

  readonly property var queue: playlistIds.map(function(id) {
    return meta[id] || { id: id, title: id, artist: "", album: "", duration: 0, thumb: "" }
  })
  readonly property var current: playlistPos >= 0 && playlistPos < queue.length ? queue[playlistPos] : null
  readonly property bool playing: !!current && !idle && !paused

  // ------------------------------------------------------------ browse state
  property string view: "results"   // results | queue | library | lyrics
  property var results: []
  property string resultsTitle: ""
  property var resultsPlaylist: null  // set when results came from a playlist
  property var playlists: []
  property bool authed: false
  property bool busy: false
  property string error: ""

  // ------------------------------------------------------------ lyrics state
  property var lyrics: null         // helper output for lyrics.id, see ytm-helper lyrics
  readonly property bool lyricsWanted: root.opened && root.view === "lyrics"
  readonly property int lyricsLine: {
    if (!root.lyrics || !root.lyrics.timed || !root.current || root.lyrics.id !== root.current.id) return -1
    var lines = root.lyrics.lines, at = -1
    for (var i = 0; i < lines.length && lines[i].time <= root.position; i++) at = i
    return at
  }

  // ------------------------------------------------------------ helpers
  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    return (h > 0 ? h + ":" : "") + mm + ":" + (s < 10 ? "0" : "") + s
  }

  function bigThumb(url) {
    return String(url || "").replace(/=w\d+-h\d+/, "=w300-h300")
  }

  function utf8Length(text) {
    var n = 0
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i)
      if (c < 0x80) n += 1
      else if (c < 0x800) n += 2
      else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++ }
      else n += 3
    }
    return n
  }

  function trackUrl(id) { return "https://music.youtube.com/watch?v=" + id }

  function idFromUrl(url) {
    var m = String(url || "").match(/[?&]v=([A-Za-z0-9_-]{11})/)
    return m ? m[1] : String(url || "")
  }

  function displayTitle(t) {
    return t.artist ? t.title + " — " + t.artist : t.title
  }

  // ------------------------------------------------------------ mpv IPC
  function send(command) {
    var line = JSON.stringify({ command: command }) + "\n"
    if (socket.connected) {
      socket.write(line)
      socket.flush()
    } else {
      root.pendingLines = root.pendingLines.concat([line])
      ensurePlayer()
    }
  }

  function ensurePlayer() {
    if (!socket.connected && !starter.running) starter.running = true
  }

  function onPlayerConnected() {
    var observed = ["pause", "idle-active", "duration", "playlist-pos", "playlist"]
    for (var i = 0; i < observed.length; i++)
      socket.write(JSON.stringify({ command: ["observe_property", i + 1, observed[i]] }) + "\n")
    for (var j = 0; j < root.pendingLines.length; j++) socket.write(root.pendingLines[j])
    root.pendingLines = []
    socket.flush()
    pollPosition()
  }

  function onPlayerMessage(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.request_id === 100) {
      if (msg.error === "success") root.position = Number(msg.data) || 0
      return
    }
    if (msg.event !== "property-change") return
    switch (msg.name) {
      case "pause": root.paused = msg.data === true; break
      case "idle-active": root.idle = msg.data === true; break
      case "duration": root.duration = Number(msg.data) || 0; break
      case "playlist-pos":
        root.playlistPos = msg.data === undefined || msg.data === null ? -1 : Number(msg.data)
        maybeExtendRadio()
        break
      case "playlist":
        root.playlistIds = (msg.data || []).map(function(e) { return root.idFromUrl(e.filename) })
        saveState()
        maybeExtendRadio()
        break
    }
  }

  function pollPosition() {
    if (socket.connected)
      socket.write(JSON.stringify({ command: ["get_property", "time-pos"], request_id: 100 }) + "\n")
    socket.flush()
  }

  function remember(tracks) {
    var next = ({})
    for (var id in root.meta) next[id] = root.meta[id]
    for (var i = 0; i < tracks.length; i++) next[tracks[i].id] = tracks[i]
    root.meta = next
  }

  function loadfile(track, flag) {
    var title = displayTitle(track)
    send(["loadfile", trackUrl(track.id), flag, -1, "force-media-title=%" + utf8Length(title) + "%" + title])
  }

  // Replace the queue with `tracks`, starting playback at `start`.
  function playList(tracks, start) {
    if (!tracks || tracks.length === 0) return
    remember(tracks)
    send(["playlist-clear"])
    loadfile(tracks[0], "replace")
    for (var i = 1; i < tracks.length; i++) loadfile(tracks[i], "append")
    if (start > 0) send(["set_property", "playlist-pos", start])
    send(["set_property", "pause", false])
  }

  function enqueue(track) {
    remember([track])
    loadfile(track, root.idle ? "append-play" : "append")
  }

  function playNext(track) {
    remember([track])
    loadfile(track, root.idle ? "append-play" : "insert-next")
  }

  function togglePause() { if (root.current) send(["cycle", "pause"]) }
  function next() { send(["playlist-next", "force"]) }
  function previous() {
    if (root.position > 5) send(["seek", 0, "absolute"])
    else send(["playlist-prev", "force"])
  }
  function jump(index) { send(["set_property", "playlist-pos", index]) }
  function removeAt(index) { send(["playlist-remove", index]) }
  function seek(sec) { send(["seek", sec, "absolute"]); root.position = sec }
  function stop() { send(["stop"]) }

  // Keep a radio going: when the last queued song starts, append its radio.
  function maybeExtendRadio() {
    if (!root.radio || root.radioLoading || !root.current) return
    if (root.playlistPos < root.queue.length - 1) return
    root.radioLoading = true
    radioProc.command = [root.python, root.helper, "radio", root.current.id]
    radioProc.running = true
  }

  // ------------------------------------------------------------ lookups
  function runHelper(args, kind) {
    browseProc.kind = kind
    browseProc.command = [root.python, root.helper].concat(args)
    root.busy = true
    root.error = ""
    browseProc.running = true
  }

  function search(query) {
    query = String(query || "").trim()
    if (query === "") return
    root.view = "results"
    runHelper(["search", query], "search")
  }

  function openPlaylist(id) { runHelper(["playlist", id], "playlist") }
  function openLiked() { runHelper(["liked"], "playlist") }
  function loadLibrary() { if (root.authed) runHelper(["playlists"], "playlists") }

  function handleBrowse(kind, text) {
    root.busy = false
    var data
    try { data = JSON.parse(text) } catch (e) { root.error = "Unexpected helper output"; return }
    if (data.error) { root.error = data.error; return }
    if (kind === "search") {
      root.results = data.tracks || []
      root.resultsTitle = ""
      root.resultsPlaylist = null
      if (root.results.length === 0) root.error = "No songs found"
    } else if (kind === "playlist") {
      root.results = data.tracks || []
      root.resultsTitle = data.title || "Playlist"
      root.resultsPlaylist = data.tracks || []
      root.view = "results"
    } else if (kind === "playlists") {
      root.playlists = data.playlists || []
    } else if (kind === "auth-status" || kind === "auth") {
      root.authed = data.auth === true
      if (root.authed) loadLibrary()
    }
  }

  function handleRadio(text) {
    root.radioLoading = false
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    if (data.error || !data.tracks) return
    var have = ({})
    for (var i = 0; i < root.playlistIds.length; i++) have[root.playlistIds[i]] = true
    var fresh = data.tracks.filter(function(t) { return !have[t.id] })
    remember(fresh)
    for (var j = 0; j < fresh.length; j++) loadfile(fresh[j], "append")
  }

  // Fetch lyrics for the current song while the Lyrics tab is open; a song
  // change during a fetch is picked up when that fetch finishes.
  function maybeLoadLyrics() {
    if (!root.lyricsWanted || !root.current || lyricsProc.running) return
    if (root.lyrics && root.lyrics.id === root.current.id) return
    lyricsProc.command = [root.python, root.helper, "lyrics", root.current.id]
    lyricsProc.running = true
  }

  function handleLyrics(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { data = { error: "Unexpected helper output" } }
    if (data.error) data = { id: lyricsProc.command[3], timed: false, source: "", lines: [], error: data.error }
    root.lyrics = data
    maybeLoadLyrics()
  }

  onLyricsWantedChanged: maybeLoadLyrics()
  onCurrentChanged: maybeLoadLyrics()

  function importAuth() {
    authProc.running = true
  }

  // ------------------------------------------------------------ state file
  function saveState() {
    var keep = ({})
    for (var i = 0; i < root.playlistIds.length; i++) {
      var id = root.playlistIds[i]
      if (root.meta[id]) keep[id] = root.meta[id]
    }
    stateFile.setText(JSON.stringify({ radio: root.radio, meta: keep }))
  }

  function loadState(text) {
    try {
      var data = JSON.parse(text)
      if (data.meta) remember(Object.keys(data.meta).map(function(k) { return data.meta[k] }))
      if (data.radio === false) root.radio = false
    } catch (e) { }
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.stateDir])
    socket.connected = true   // reattach to an mpv that is already playing
    runHelper(["auth-status"], "auth-status")
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    printErrors: false
    onLoaded: root.loadState(text())
  }

  Socket {
    id: socket
    path: root.socketPath
    onConnectedChanged: if (connected) root.onPlayerConnected()
    parser: SplitParser { onRead: function(data) { root.onPlayerMessage(data) } }
  }

  Process {
    id: starter
    command: [root.pluginDir + "/bin/ytm-mpv"]
    onExited: function(code) {
      if (code === 0) socket.connected = true
      else root.error = "Could not start the player (mpv)"
    }
  }

  Process {
    id: browseProc
    property string kind: ""
    stdout: StdioCollector { onStreamFinished: root.handleBrowse(browseProc.kind, text) }
  }

  Process {
    id: radioProc
    stdout: StdioCollector { onStreamFinished: root.handleRadio(text) }
  }

  Process {
    id: lyricsProc
    stdout: StdioCollector { onStreamFinished: root.handleLyrics(text) }
  }

  Process {
    id: authProc
    command: ["sh", "-c", "f=$(mktemp) && wl-paste > \"$f\" && \"$0\" \"$1\" auth \"$f\"; rm -f \"$f\"", root.python, root.helper]
    stdout: StdioCollector { onStreamFinished: root.handleBrowse("auth", text) }
  }

  // omarchy-shell nicola.ytmusic <method> [arg], e.g. for keybindings.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function playPause(): void { root.togglePause() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function stop(): void { root.stop() }
    function lyrics(): void { root.view = "lyrics"; root.open() }
    function search(query: string): void { root.open(); searchField.text = query; root.search(query) }
    function playResult(index: string): void {
      var i = Number(index) || 0
      if (i >= 0 && i < root.results.length) root.playList([root.results[i]], 0)
    }
    function nowPlaying(): string { return root.current ? root.displayTitle(root.current) : "" }
  }

  Timer {
    interval: root.lyricsWanted && root.lyrics && root.lyrics.timed ? 200 : 1000
    repeat: true
    running: socket.connected && !root.idle && !root.paused
    onTriggered: root.pollPosition()
  }

  // ------------------------------------------------------------ bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.playing ? "󰝚" : "󰝛"
    tooltipText: root.current ? root.displayTitle(root.current) : "YouTube Music"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePause()
      else if (b === Qt.MiddleButton) root.next()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- now playing ----------
      Item {
        width: parent.width
        implicitHeight: Style.space(84)

        Rectangle {
          id: art
          width: Style.space(84)
          height: width
          radius: Style.cornerRadius
          color: root.hoverFill
          clip: true

          Image {
            anchors.fill: parent
            source: root.current ? root.bigThumb(root.current.thumb) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
          }
          Text {
            anchors.centerIn: parent
            visible: !root.current
            textFormat: Text.PlainText
            text: "󰝚"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }

        Column {
          anchors.left: art.right
          anchors.leftMargin: Style.space(12)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.current ? root.current.title : "Nothing playing"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.current
              ? [root.current.artist, root.current.album].filter(function(s) { return s }).join(" · ")
              : "Search for a song below"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Row {
            spacing: Style.space(4)
            topPadding: Style.space(4)

            Button {
              text: "󰒮"; foreground: root.foreground; fontSize: Style.font.title
              enabled: !!root.current
              onClicked: root.previous()
            }
            Button {
              text: root.playing ? "󰏤" : "󰐊"; foreground: root.foreground; fontSize: Style.font.title
              enabled: !!root.current
              onClicked: root.togglePause()
            }
            Button {
              text: "󰒭"; foreground: root.foreground; fontSize: Style.font.title
              enabled: !!root.current
              onClicked: root.next()
            }
            Button {
              text: root.radioLoading ? "Radio…" : "Radio"
              foreground: root.foreground
              selected: root.radio
              tooltipText: "Keep playing similar songs when the queue ends"
              onClicked: { root.radio = !root.radio; root.saveState(); root.maybeExtendRadio() }
            }
          }
        }
      }

      // ---------- progress ----------
      Item {
        width: parent.width
        implicitHeight: seekSlider.implicitHeight
        visible: !!root.current

        Text {
          id: elapsed
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.fmt(seekSlider.dragging ? seekSlider.liveValue : root.position)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        PanelSlider {
          id: seekSlider
          anchors.left: elapsed.right
          anchors.right: total.left
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          bar: root.bar
          minimum: 0
          maximum: Math.max(1, root.duration || (root.current ? root.current.duration : 1))
          step: 1
          value: root.position
          onReleased: function(v) { root.seek(v) }
        }
        Text {
          id: total
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.fmt(root.duration || (root.current ? root.current.duration : 0))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---------- search ----------
      TextField {
        id: searchField
        width: parent.width
        placeholderText: "Search songs, artists, albums…"
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        foreground: root.foreground
        onAccepted: root.search(text)
        Keys.onEscapePressed: root.close()
      }

      // ---------- tabs ----------
      Row {
        spacing: Style.space(4)

        Button {
          text: root.resultsTitle !== "" ? root.resultsTitle : "Results"
          foreground: root.foreground
          selected: root.view === "results"
          onClicked: root.view = "results"
        }
        Button {
          text: "Queue" + (root.queue.length > 0 ? " (" + root.queue.length + ")" : "")
          foreground: root.foreground
          selected: root.view === "queue"
          onClicked: root.view = "queue"
        }
        Button {
          text: "Lyrics"
          foreground: root.foreground
          selected: root.view === "lyrics"
          onClicked: root.view = "lyrics"
        }
        Button {
          text: "Library"
          foreground: root.foreground
          selected: root.view === "library"
          onClicked: { root.view = "library"; if (root.playlists.length === 0) root.loadLibrary() }
        }
      }

      // ---------- list ----------
      Item {
        width: parent.width
        implicitHeight: Style.space(320)

        ListView {
          id: list
          anchors.fill: parent
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          visible: root.view !== "lyrics" && (root.view !== "library" || root.authed)
          model: root.view === "lyrics" ? []
            : root.view === "queue" ? root.queue
            : root.view === "library" ? [{ liked: true, title: "Liked songs", count: "" }].concat(root.playlists)
            : root.results

          header: Item {
            width: list.width
            height: root.view === "results" && root.resultsPlaylist ? Style.space(36) : 0
            visible: height > 0

            Button {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "󰐊  Play all"
              foreground: root.foreground
              onClicked: root.playList(root.resultsPlaylist, 0)
            }
            Button {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "󰒝  Shuffle"
              foreground: root.foreground
              onClicked: {
                var copy = root.resultsPlaylist.slice()
                for (var i = copy.length - 1; i > 0; i--) {
                  var j = Math.floor(Math.random() * (i + 1)), t = copy[i]
                  copy[i] = copy[j]; copy[j] = t
                }
                root.playList(copy, 0)
              }
            }
          }

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool isLibrary: root.view === "library"
            readonly property bool isCurrent: root.view === "queue" && index === root.playlistPos

            width: list.width
            height: Style.space(48)
            radius: Style.cornerRadius
            color: isCurrent ? root.selectedFill : (rowMouse.containsMouse ? root.hoverFill : "transparent")

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) {
                if (row.isLibrary) {
                  if (row.modelData.liked) root.openLiked()
                  else root.openPlaylist(row.modelData.id)
                } else if (root.view === "queue") {
                  if (mouse.button === Qt.RightButton) root.removeAt(row.index)
                  else root.jump(row.index)
                } else if (mouse.button === Qt.RightButton) {
                  root.playNext(row.modelData)
                } else if (root.resultsPlaylist) {
                  root.playList(root.resultsPlaylist, row.index)
                } else {
                  root.playList([row.modelData], 0)
                }
              }
            }

            Rectangle {
              id: thumb
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              height: width
              radius: Style.cornerRadius
              color: root.hoverFill
              clip: true

              Image {
                anchors.fill: parent
                source: row.modelData.thumb || ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: status === Image.Ready
              }
              Text {
                anchors.centerIn: parent
                visible: row.isLibrary && !row.modelData.thumb
                textFormat: Text.PlainText
                text: row.modelData.liked ? "󰋑" : "󰲸"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
              }
            }

            Column {
              anchors.left: thumb.right
              anchors.leftMargin: Style.space(10)
              anchors.right: trailing.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: row.modelData.title || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.isCurrent
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: row.isLibrary
                  ? (row.modelData.count ? row.modelData.count + " songs" : "")
                  : [row.modelData.artist, row.modelData.album].filter(function(s) { return s }).join(" · ")
                visible: text !== ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: trailing
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !row.isLibrary && row.modelData.duration > 0
                textFormat: Text.PlainText
                text: root.fmt(row.modelData.duration)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Button {
                visible: root.view === "results"
                text: "󰐕"
                foreground: root.foreground
                tooltipText: "Add to queue"
                onClicked: root.enqueue(row.modelData)
              }
              Button {
                visible: root.view === "queue"
                text: "󰅖"
                foreground: root.foreground
                tooltipText: "Remove from queue"
                onClicked: root.removeAt(row.index)
              }
            }
          }
        }

        // Lyrics: timed ones follow the song and seek on click.
        ListView {
          id: lyricsList
          anchors.fill: parent
          clip: true
          spacing: Style.space(6)
          boundsBehavior: Flickable.StopAtBounds
          visible: root.view === "lyrics"
          model: root.view === "lyrics" && root.lyrics && root.current && root.lyrics.id === root.current.id
            ? root.lyrics.lines : []
          currentIndex: root.lyricsLine
          highlightFollowsCurrentItem: true
          highlightRangeMode: ListView.ApplyRange
          preferredHighlightBegin: height / 2 - Style.space(20)
          preferredHighlightEnd: height / 2 + Style.space(20)
          highlightMoveDuration: 300

          footer: Text {
            width: lyricsList.width
            topPadding: Style.space(12)
            visible: !!(root.lyrics && root.lyrics.source)
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.lyrics && root.lyrics.source ? "Lyrics: " + root.lyrics.source : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          delegate: Text {
            id: lyric
            required property var modelData
            required property int index
            readonly property bool timed: modelData.time >= 0
            readonly property bool isCurrent: index === root.lyricsLine

            width: lyricsList.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: modelData.text
            color: isCurrent ? root.accent
              : timed && index > root.lyricsLine ? root.dim
              : timed ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
              : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: isCurrent

            MouseArea {
              anchors.fill: parent
              enabled: lyric.timed
              cursorShape: Qt.PointingHandCursor
              onClicked: root.seek(lyric.modelData.time)
            }
          }
        }

        // Empty states and library setup
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(24)
          spacing: Style.space(10)
          visible: root.view === "lyrics" ? lyricsList.count === 0
            : list.count === 0 || (root.view === "library" && !root.authed)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: root.view === "library" && !root.authed
              ? "To see your playlists and liked songs, open music.youtube.com in Chrome while signed in, "
                + "open DevTools (F12) → Network, click any request named \"browse\", "
                + "right-click it → Copy → Copy request headers, then press Import."
              : root.view === "lyrics"
                ? (!root.current ? "Nothing playing"
                  : lyricsProc.running || !root.lyrics || root.lyrics.id !== root.current.id ? "Loading lyrics…"
                  : root.lyrics.error ? root.lyrics.error
                  : "No lyrics for this song")
              : root.view === "queue" ? "The queue is empty"
              : root.busy ? "Searching…"
              : "Type a search and press Enter.\nClick a song to play it, right-click to play it next."
          }
          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.view === "library" && !root.authed
            text: authProc.running ? "Importing…" : "Import headers from clipboard"
            foreground: root.foreground
            bordered: true
            onClicked: root.importAuth()
          }
        }
      }

      // ---------- status ----------
      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.error !== "" ? root.error : (root.busy ? "Loading…" : "")
        color: root.error !== "" ? Commons.Color.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
