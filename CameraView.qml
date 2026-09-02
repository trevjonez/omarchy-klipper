import QtQuick
import QtMultimedia
import qs.Commons

// Renders one enabled webcam from Moonraker's /server/webcams/list. Tries
// real video first (QtMultimedia's MediaPlayer/VideoOutput against the
// MJPEG stream_url — verified live: Qt6's FFmpeg backend auto-detects the
// `mpjpeg` demuxer and decodes it like any other video source). If that
// doesn't reach a playing state within a few seconds, or errors outright,
// falls back permanently to polling the snapshot_url as a still image —
// no flapping back and forth once the fallback is used.
Item {
  id: root

  property string cameraName: ""
  property string streamUrl: ""
  property string snapshotUrl: ""
  property bool flipHorizontal: false
  property bool flipVertical: false
  property int rotationDeg: 0
  property real aspectRatio: 0.75 // height / width
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  property bool usingSnapshotFallback: streamUrl === ""
  property bool videoReady: false
  property int snapshotCounter: 0

  height: width * aspectRatio
  clip: true

  function fallBackToSnapshot() {
    if (usingSnapshotFallback) return
    usingSnapshotFallback = true
    player.stop()
  }

  Item {
    id: mediaFrame
    anchors.fill: parent
    transform: [
      Rotation { origin.x: mediaFrame.width / 2; origin.y: mediaFrame.height / 2; angle: root.rotationDeg },
      Scale { origin.x: mediaFrame.width / 2; origin.y: mediaFrame.height / 2; xScale: root.flipHorizontal ? -1 : 1; yScale: root.flipVertical ? -1 : 1 }
    ]

    VideoOutput {
      id: videoOutput
      anchors.fill: parent
      visible: !root.usingSnapshotFallback
      fillMode: VideoOutput.PreserveAspectFit
    }

    Image {
      id: snapshotImage
      anchors.fill: parent
      visible: root.usingSnapshotFallback
      fillMode: Image.PreserveAspectFit
      cache: false
      asynchronous: true
      source: root.usingSnapshotFallback && root.snapshotUrl !== ""
        ? root.snapshotUrl + (root.snapshotUrl.indexOf("?") === -1 ? "?" : "&") + "_=" + root.snapshotCounter
        : ""
    }
  }

  Text {
    anchors.centerIn: parent
    visible: root.usingSnapshotFallback && snapshotImage.status !== Image.Ready
    text: root.snapshotUrl === "" ? "No camera feed" : "Loading camera…"
    color: root.foreground
    font.family: root.fontFamily
    opacity: 0.7
  }

  Rectangle {
    visible: root.cameraName !== ""
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.space(6)
    radius: Style.cornerRadius
    color: Color.background
    opacity: 0.6
    width: nameLabel.implicitWidth + Style.space(10)
    height: nameLabel.implicitHeight + Style.space(4)

    Text {
      id: nameLabel
      anchors.centerIn: parent
      text: root.cameraName
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MediaPlayer {
    id: player
    source: root.usingSnapshotFallback ? "" : root.streamUrl
    videoOutput: videoOutput
    autoPlay: true
    onPlaybackStateChanged: if (playbackState === MediaPlayer.PlayingState) root.videoReady = true
    onErrorOccurred: root.fallBackToSnapshot()
  }

  Timer {
    // Live streams hover in Buffering/Stalled between frames even while
    // playing fine, so "reached PlayingState at all" is the right bar —
    // waiting for a settled MediaStatus would never fire for a live source.
    id: videoWatchdog
    interval: 5000
    running: !root.usingSnapshotFallback
    onTriggered: if (!root.videoReady) root.fallBackToSnapshot()
  }

  Timer {
    id: snapshotTimer
    interval: 1000
    repeat: true
    running: root.usingSnapshotFallback && root.snapshotUrl !== ""
    triggeredOnStart: true
    onTriggered: root.snapshotCounter++
  }
}
