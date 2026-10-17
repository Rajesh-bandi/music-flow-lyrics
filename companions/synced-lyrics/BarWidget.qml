import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import "../io.github.rajesh-bandi.music-flow/MediaModel.js" as MediaModel

BarWidget {
  id: root
  moduleName: "io.github.rajesh-bandi.music-flow-lyrics"

  property int playerRevision: 0
  readonly property var activePlayer: {
    var revision = playerRevision
    var players = Mpris.players ? Mpris.players.values : []
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!player || MediaModel.isProxyPlayer(player)) continue
      if (!fallback && MediaModel.hasMetadata(player)) fallback = player
      if (player.isPlaying && MediaModel.hasMetadata(player)) return player
    }
    return fallback
  }
  property bool lyricsOpen: false
  readonly property bool isPlaying: Boolean(activePlayer && activePlayer.isPlaying)
  readonly property string title: activePlayer
    ? MediaModel.sanitizeText(activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || "")
    : ""
  readonly property string artist: activePlayer
    ? MediaModel.sanitizeText(activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || "")
    : ""
  readonly property real trackLength: {
    var value = Number(activePlayer && activePlayer.length)
    if (!isFinite(value) || value <= 0) return 0
    return value > 1000000 ? value / 1000000 : value
  }
  property real trackPosition: 0
  readonly property color lyricColor: bar ? bar.barForeground : Color.foreground

  property string lyricsRequestKey: ""
  property string lyricsStatus: ""
  property var lyricLines: []
  property var lyricTimes: []
  property var currentLyricWords: []
  property int currentLyricIndex: -1
  property real lyricWordProgress: 0

  visible: lyricsOpen
  implicitWidth: lyricsOpen ? Style.space(300) : 0
  implicitHeight: barSize
  Behavior on implicitWidth { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

  function toggleLyrics() {
    lyricsOpen = !lyricsOpen
  }

  IpcHandler {
    target: "io.github.rajesh-bandi.music-flow-lyrics"
    function toggle(): string {
      root.broadcast("toggleLyrics")
      return "ok"
    }
  }

  Instantiator {
    model: Mpris.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { root.playerRevision++ }
      function onMetadataChanged() { root.playerRevision++ }
      function onTrackTitleChanged() { root.playerRevision++ }
      function onTrackArtistChanged() { root.playerRevision++ }
    }
  }

  Process {
    id: lyricsProcess
    stdout: StdioCollector {
      id: lyricsOutput
      waitForEnd: true
    }
  }

  function loadLyrics() {
    if (!root.title || !root.activePlayer) return
    var requestKey = root.artist + "\n" + root.title
    root.lyricsRequestKey = requestKey
    root.lyricsStatus = "Loading lyrics..."
    root.lyricLines = []
    root.lyricTimes = []
    root.currentLyricWords = []
    root.currentLyricIndex = -1
    root.lyricWordProgress = 0
    lyricsProcess.running = false
    lyricsProcess.command = [
      "curl", "-fsSL", "--max-time", "8", "--proto", "=https",
      "https://lrclib.net/api/get?artist_name=" + encodeURIComponent(root.artist)
        + "&track_name=" + encodeURIComponent(root.title)
    ]
    lyricsProcess.running = true
  }

  onLyricsOpenChanged: if (lyricsOpen) loadLyrics()
  onTitleChanged: if (lyricsOpen) loadLyrics()
  onArtistChanged: if (lyricsOpen) loadLyrics()

  function updateLyricIndex() {
    if (lyricLines.length === 0 || trackLength <= 0) return
    var nextIndex = -1
    var progress = 0
    if (lyricTimes.length === lyricLines.length) {
      for (var i = 0; i < lyricTimes.length; i++) {
        if (trackPosition >= lyricTimes[i]) nextIndex = i
        else break
      }
      nextIndex = Math.max(0, nextIndex)
      var start = lyricTimes[nextIndex]
      var end = nextIndex + 1 < lyricTimes.length ? lyricTimes[nextIndex + 1] : trackLength
      progress = end > start ? Math.max(0, Math.min(1, (trackPosition - start) / (end - start))) : 0
    } else {
      nextIndex = Math.min(lyricLines.length - 1, Math.floor((trackPosition / trackLength) * lyricLines.length))
      var lineDuration = trackLength / lyricLines.length
      progress = lineDuration > 0 ? (trackPosition % lineDuration) / lineDuration : 0
    }
    if (nextIndex !== currentLyricIndex) {
      currentLyricIndex = nextIndex
      currentLyricWords = String(lyricLines[nextIndex] || "").trim().split(/\s+/).filter(function(word) { return word !== "" })
    }
    lyricWordProgress = progress
  }

  Timer {
    interval: 250
    running: root.lyricsOpen
    repeat: true
    onTriggered: {
      var value = Number(root.activePlayer && root.activePlayer.position)
      if (isFinite(value) && value >= 0)
        root.trackPosition = value > 1000000 ? value / 1000000 : value
      root.updateLyricIndex()
    }
  }

  onCurrentLyricIndexChanged: {
    lyricText.x = 0
    if (lyricScroll.running) lyricScroll.restart()
  }

  Connections {
    target: lyricsProcess
    function onExited(exitCode) {
      if (root.lyricsRequestKey !== root.artist + "\n" + root.title) return
      if (exitCode !== 0) {
        root.lyricsStatus = "Lyrics are unavailable for this track."
        return
      }
      try {
        var result = JSON.parse(lyricsOutput.text || "")
        var synced = String(result.syncedLyrics || "").trim()
        root.lyricLines = []
        root.lyricTimes = []
        root.currentLyricWords = []
        root.lyricWordProgress = 0
        if (synced) {
          var timestampPattern = /^\[(\d+):(\d{2}(?:\.\d{1,3})?)\]\s*(.*)$/
          synced.split(/\r?\n/).forEach(function(line) {
            var match = line.match(timestampPattern)
            if (!match || !match[3].trim()) return
            root.lyricTimes.push(Number(match[1]) * 60 + Number(match[2]))
            root.lyricLines.push(match[3].trim())
          })
        }
        if (root.lyricLines.length === 0) {
          var plain = String(result.plainLyrics || "").trim()
          root.lyricLines = plain ? plain.split(/\r?\n/).filter(function(line) { return line.trim() !== "" }) : []
        }
        root.lyricsStatus = root.lyricLines.length > 0 ? "" : "Lyrics are unavailable for this track."
        root.updateLyricIndex()
      } catch (error) {
        root.lyricsStatus = "Lyrics could not be loaded."
      }
    }
  }

  function lyricMarkup() {
    var words = currentLyricWords || []
    var completed = lyricWordProgress * words.length
    return words.map(function(word, index) {
      var safeWord = String(word).replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/\"/g, "&quot;")
      var color = index < completed ? Util.alpha(Color.accent, 0.3) : Color.accent
      return "<font color=\"" + color + "\">" + safeWord + "</font>"
    }).join(" ")
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    clip: true

    Item {
      id: lyricViewport
      anchors.fill: parent
      visible: root.lyricsStatus === "" && root.currentLyricIndex >= 0
      opacity: visible ? 1 : 0
      scale: visible ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutQuad } }
      Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.InOutQuad } }

      Text {
        id: lyricText
        x: 0
        height: parent.height
        width: Math.max(parent.width, implicitWidth)
        anchors.verticalCenter: parent.verticalCenter
        text: root.lyricMarkup()
        textFormat: Text.RichText
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.NoWrap
        color: root.lyricColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      SequentialAnimation {
        id: lyricScroll
        running: root.lyricsOpen && lyricText.width > lyricViewport.width
        loops: Animation.Infinite

        PauseAnimation { duration: 1100 }
        NumberAnimation {
          target: lyricText
          property: "x"
          to: -(lyricText.width - lyricViewport.width)
          duration: Math.max(1800, (lyricText.width - lyricViewport.width) * 28)
          easing.type: Easing.Linear
        }
        PauseAnimation { duration: 800 }
        NumberAnimation {
          target: lyricText
          property: "x"
          to: 0
          duration: 450
          easing.type: Easing.OutQuad
        }
      }
    }

    Text {
      anchors.fill: parent
      visible: root.lyricsStatus !== ""
      text: root.lyricsStatus || "Loading lyrics..."
      color: Qt.darker(root.lyricColor, 1.2)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
    }
  }
}
