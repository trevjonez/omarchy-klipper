import QtQuick
import QtMultimedia
import qs.Commons
import "Model.js" as Model

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
  // False while whatever holds this feed is closed. The popup, the camera
  // wall and the fullscreen view all keep their CameraViews alive rather than
  // destroying them, so without this a closed view goes on polling a snapshot
  // every second and re-opening an MJPEG stream every 30 -- from several
  // instances at once, which is enough load to make a Pi's camera service
  // start answering 502 to the view that *is* on screen.
  property bool active: true
  // Set from the camera's own configured service. An adaptive camera is meant
  // to be pulled one snapshot at a time; the stream path is not just slower
  // for it, it drifts further behind the longer it runs (see
  // Model.prefersSnapshots).
  property bool preferSnapshots: false
  // Floor between snapshot requests, not a period -- the next one is asked
  // for when the last has arrived, so the achieved rate is this plus the
  // ~15ms a frame costs to fetch and decode.
  //
  // 25ms lands around 30/s, which is roughly what the camera captures.
  // Higher is measurably possible -- no floor at all reaches 90/s -- and
  // pointless: past the capture rate the same frame comes back twice, at full
  // price. Latency does not move with any of this, because a request is only
  // ever issued once the last frame is in hand and each one returns whatever
  // is current; the rate buys smoothness, not freshness.
  //
  // A second, when this is the degraded path after video failed, is about
  // staying readable without loading a camera that is already unwell.
  property int snapshotMinIntervalMs: preferSnapshots ? 25 : 1000

  property bool usingSnapshotFallback: preferSnapshots || streamUrl === ""
  property bool videoReady: false
  property int snapshotCounter: 0
  // True once any snapshot has rendered. The placeholder is gated on this
  // rather than on the current load, so it appears once while connecting
  // instead of flashing back over the picture on every refresh.
  property bool hasSnapshot: false
  // A retry attempt is in flight. Video keeps playing underneath while the
  // snapshot stays on screen, so a failed retry costs nothing visible and a
  // successful one swaps in a live frame rather than a blank wait.
  property bool retryingVideo: false
  // Which of the two snapshot images is currently on screen.
  property bool frontIsA: true
  // Draws a frame-rate readout over the picture. Off for the popup, whose
  // feed is small and incidental; on where someone is actually watching.
  property bool showFps: false
  // Frames put on screen in the last second -- what is being drawn, which is
  // not the camera's configured rate: a snapshot feed runs as fast as the
  // link and the decoder allow, by design.
  readonly property alias renderedFps: root._fps
  property int _fps: 0
  property int _framesThisSecond: 0

  function noteFrame() { _framesThisSecond++ }

  // Loads into whichever image is hidden, and shows it only once it has
  // decoded. A single Image whose source changes goes blank while the
  // replacement loads, which is the flicker this avoids.
  function refreshSnapshot() {
    if (snapshotUrl === "") return
    snapshotCounter++
    var url = Model.snapshotUrlWithCacheBust(snapshotUrl, snapshotCounter)
    if (frontIsA) snapshotB.source = url
    else snapshotA.source = url
  }

  // Requests the next frame, immediately or after the floor has elapsed. The
  // loop is driven by frames arriving rather than by a fixed cadence, so
  // requests never overlap and a slow link costs frame rate instead of
  // queueing up work whose answer is already stale by the time it lands.
  function scheduleSnapshot(immediate) {
    if (!active || !usingSnapshotFallback || snapshotUrl === "") return
    if (immediate) refreshSnapshot()
    else if (!snapshotGap.running) snapshotGap.restart()
  }

  function presentSnapshot(isA) {
    frontIsA = isA
    hasSnapshot = true
    noteFrame()
  }

  height: width * aspectRatio
  clip: true

  onActiveChanged: {
    if (!active) {
      retryingVideo = false
      videoReady = false
      _fps = 0
      _framesThisSecond = 0
      player.stop()
      return
    }
    // Coming back on screen is the natural moment to try video again, rather
    // than waiting out a retry interval that started while nobody was
    // looking. hasSnapshot deliberately survives: the last frame is a better
    // thing to show for the second it takes than the placeholder is.
    retryingVideo = false
    videoReady = false
    usingSnapshotFallback = preferSnapshots || streamUrl === ""
    scheduleSnapshot(true)
  }

  function fallBackToSnapshot() {
    retryingVideo = false
    if (usingSnapshotFallback) return
    usingSnapshotFallback = true
    player.stop()
  }

  // Falling back used to be permanent, to avoid flapping between video and
  // stills. But a stalled stream is usually transient -- a Klipper error
  // loading the Pi, a brief network drop -- so staying on 1fps stills until
  // the panel happens to be rebuilt is the wrong trade. Retry periodically
  // instead, without disturbing what is on screen.
  function retryVideo() {
    if (preferSnapshots) return
    if (!usingSnapshotFallback || streamUrl === "" || retryingVideo) return
    retryingVideo = true
    videoReady = false
    player.stop()
    player.play()
  }

  function adoptVideo() {
    videoReady = true
    retryingVideo = false
    usingSnapshotFallback = false
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

    Connections {
      target: videoOutput.videoSink
      enabled: root.showFps && !root.usingSnapshotFallback
      function onVideoFrameChanged(frame) { root.noteFrame() }
    }

    Image {
      id: snapshotA
      anchors.fill: parent
      visible: root.usingSnapshotFallback && root.frontIsA
      fillMode: Image.PreserveAspectFit
      cache: false
      asynchronous: true
      onStatusChanged: {
        if (status === Image.Ready) root.presentSnapshot(true)
        if (status === Image.Ready || status === Image.Error) root.scheduleSnapshot(false)
      }
    }

    Image {
      id: snapshotB
      anchors.fill: parent
      visible: root.usingSnapshotFallback && !root.frontIsA
      fillMode: Image.PreserveAspectFit
      cache: false
      asynchronous: true
      onStatusChanged: {
        if (status === Image.Ready) root.presentSnapshot(false)
        if (status === Image.Ready || status === Image.Error) root.scheduleSnapshot(false)
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: root.usingSnapshotFallback && !root.hasSnapshot
    text: root.snapshotUrl === "" ? "No camera feed" : "Loading camera…"
    color: root.foreground
    font.family: root.fontFamily
    opacity: 0.7
  }

  Rectangle {
    visible: root.showFps && root.renderedFps > 0
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(6)
    radius: Style.cornerRadius
    color: Color.background
    opacity: 0.6
    width: fpsLabel.implicitWidth + Style.space(10)
    height: fpsLabel.implicitHeight + Style.space(4)

    Text {
      id: fpsLabel
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.renderedFps + " fps"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
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
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.cameraName
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MediaPlayer {
    id: player
    // Kept loaded during a retry so the attempt can run underneath the
    // snapshot that is still being displayed.
    source: root.active && (!root.usingSnapshotFallback || root.retryingVideo) ? root.streamUrl : ""
    videoOutput: videoOutput
    autoPlay: true
    onPlaybackStateChanged: if (playbackState === MediaPlayer.PlayingState) root.adoptVideo()
    onErrorOccurred: {
      if (root.retryingVideo) root.retryingVideo = false
      else root.fallBackToSnapshot()
    }
  }

  Timer {
    // Live streams hover in Buffering/Stalled between frames even while
    // playing fine, so "reached PlayingState at all" is the right bar —
    // waiting for a settled MediaStatus would never fire for a live source.
    id: videoWatchdog
    interval: 5000
    running: root.active && (!root.usingSnapshotFallback || root.retryingVideo)
    onTriggered: {
      if (root.videoReady) return
      // A retry that did not take just ends; the snapshot was never replaced,
      // so there is nothing to tear down and nothing flickers.
      if (root.retryingVideo) { root.retryingVideo = false; player.stop() }
      else root.fallBackToSnapshot()
    }
  }

  Timer {
    // Slow enough that a camera which is genuinely gone is not hammered, quick
    // enough that a transient stall self-heals well inside a print.
    id: videoRetryTimer
    interval: 30000
    repeat: true
    running: root.active && !root.preferSnapshots && root.usingSnapshotFallback && root.streamUrl !== ""
    onTriggered: root.retryVideo()
  }

  Timer {
    // One-second buckets: coarse enough to read, fine enough to notice a feed
    // degrading. Stops with the view, so a closed feed does not report a rate.
    interval: 1000
    repeat: true
    running: root.active
    onTriggered: {
      root._fps = root._framesThisSecond
      root._framesThisSecond = 0
    }
  }

  Timer {
    id: snapshotGap
    interval: root.snapshotMinIntervalMs
    repeat: false
    onTriggered: root.refreshSnapshot()
  }

  // Entering snapshot mode -- at startup, on an adaptive camera, or after
  // video gave up -- starts the loop; every later frame reschedules it.
  onUsingSnapshotFallbackChanged: if (usingSnapshotFallback) scheduleSnapshot(true)
  onSnapshotUrlChanged: scheduleSnapshot(true)
  Component.onCompleted: scheduleSnapshot(true)
}
