import AVKit
import CoreMedia
import CoreVideo
import Flutter
import UIKit

// Picture-in-Picture for a VideoOutput, built on the iOS 15+ sample-buffer
// PiP API. libmpv renders into CVPixelBuffers (not an AVPlayer), so frames are
// re-wrapped as CMSampleBuffers and enqueued on an AVSampleBufferDisplayLayer
// driven by AVPictureInPictureController.
//
// The layer backs a full-screen, fully transparent view inserted behind the
// Flutter view: PiP requires the source layer to be attached to an onscreen
// window, but an alpha-0 view satisfies that without being user-visible.
@available(iOS 15.0, *)
public class PictureInPictureController: NSObject, VideoOutputFrameConsumer,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate
{
  // Sends an event to Dart. Invoked on the main thread; `handle` is included
  // in the arguments.
  public typealias EventCallback = (_ method: String, _ arguments: [String: Any]) -> Void

  // UIView whose backing layer is the AVSampleBufferDisplayLayer.
  private final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
      layer as! AVSampleBufferDisplayLayer
    }
  }

  private let handle: Int64
  private let emitEvent: EventCallback
  private let queue = DispatchQueue(label: "com.alexmercerind.media_kit_video.pip")

  private let hostView = SampleBufferView()
  private var displayLayer: AVSampleBufferDisplayLayer { hostView.sampleBufferDisplayLayer }
  private var pipController: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var timebase: CMTimebase?

  private var formatDescription: CMVideoFormatDescription?
  private var formatDescriptionWidth: Int = 0
  private var formatDescriptionHeight: Int = 0
  private var enqueuedFrameCount: Int = 0

  // Playback state mirrored from Dart, read by the sample-buffer playback
  // delegate (main thread) and updated via setPlaybackState.
  private var isPlaying: Bool = true
  private var rate: Double = 1.0
  private var duration: Double = 0

  private var pendingStart: Bool = false
  private var disposed: Bool = false

  // Must be called on the main thread. Returns nil when no window is
  // available to host the display layer.
  init?(handle: Int64, autoEnter: Bool, emitEvent: @escaping EventCallback) {
    self.handle = handle
    self.emitEvent = emitEvent

    super.init()

    guard let rootView = PictureInPictureController.rootView() else {
      NSLog("[MKPiP] init failed: no window to host the display layer")
      return nil
    }

    hostView.frame = rootView.bounds
    hostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostView.alpha = 0
    hostView.isUserInteractionEnabled = false
    displayLayer.videoGravity = .resizeAspect
    rootView.insertSubview(hostView, at: 0)

    // Frames are stamped with this timebase's current time, so it must run at
    // rate 1 from the start (matching proven sample-buffer PiP implementations).
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    if let timebase = timebase {
      CMTimebaseSetTime(timebase, time: .zero)
      CMTimebaseSetRate(timebase, rate: 1.0)
      displayLayer.controlTimebase = timebase
    }
    self.timebase = timebase

    let audioSession = AVAudioSession.sharedInstance()
    NSLog(
      "[MKPiP] init: handle=%lld autoEnter=%d audioSession category=%@ mode=%@",
      handle, autoEnter, audioSession.category.rawValue, audioSession.mode.rawValue
    )

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let pipController = AVPictureInPictureController(contentSource: contentSource)
    pipController.delegate = self
    pipController.canStartPictureInPictureAutomaticallyFromInline = autoEnter
    self.pipController = pipController

    // isPictureInPicturePossible becomes true asynchronously; honor a start()
    // that raced ahead of it.
    possibleObservation = pipController.observe(
      \.isPictureInPicturePossible, options: [.initial, .new]
    ) { [weak self] pipController, _ in
      guard let that = self else { return }
      let possible = pipController.isPictureInPicturePossible
      NSLog("[MKPiP] isPictureInPicturePossible=%d (pendingStart=%d)", possible, that.pendingStart)
      that.emit("PictureInPicture.OnPossibleChanged", ["possible": possible])
      if that.pendingStart, possible {
        that.pendingStart = false
        NSLog("[MKPiP] starting PiP (deferred)")
        pipController.startPictureInPicture()
      }
    }
  }

  // MARK: - VideoOutputFrameConsumer (worker thread)

  public func enqueue(_ pixelBuffer: CVPixelBuffer, size: CGSize) {
    queue.async { [weak self] in
      self?.enqueueOnQueue(pixelBuffer)
    }
  }

  private func enqueueOnQueue(_ pixelBuffer: CVPixelBuffer) {
    if disposed {
      return
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if formatDescription == nil
      || width != formatDescriptionWidth
      || height != formatDescriptionHeight
    {
      var formatDescription: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
      self.formatDescription = formatDescription
      formatDescriptionWidth = width
      formatDescriptionHeight = height
      NSLog("[MKPiP] format description %dx%d", width, height)
    }
    guard let formatDescription = formatDescription else {
      return
    }

    // Stamp with the layer's timebase "now" so the sample is due immediately;
    // a host-clock timestamp here would schedule it far in the future and
    // stall the layer (keeping isPictureInPicturePossible false).
    let presentationTime = timebase.map { CMTimebaseGetTime($0) }
      ?? CMClockGetTime(CMClockGetHostTimeClock())
    var timing = CMSampleTimingInfo(
      duration: CMTimeMake(value: 1, timescale: 60),
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer = sampleBuffer else {
      return
    }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }

    if displayLayer.status == .failed {
      NSLog(
        "[MKPiP] display layer failed, flushing: %@",
        displayLayer.error?.localizedDescription ?? "unknown"
      )
      displayLayer.flush()
    }
    if displayLayer.isReadyForMoreMediaData {
      displayLayer.enqueue(sampleBuffer)
      enqueuedFrameCount += 1
      if enqueuedFrameCount == 1 || enqueuedFrameCount % 600 == 0 {
        NSLog("[MKPiP] enqueued frame #%d", enqueuedFrameCount)
      }
    }
  }

  // MARK: - Control (main thread)

  public func setAutoEnter(_ autoEnter: Bool) {
    NSLog("[MKPiP] setAutoEnter=%d", autoEnter)
    pipController?.canStartPictureInPictureAutomaticallyFromInline = autoEnter
  }

  public func start() -> Bool {
    guard let pipController = pipController else {
      return false
    }
    if pipController.isPictureInPictureActive {
      return true
    }
    if pipController.isPictureInPicturePossible {
      NSLog("[MKPiP] starting PiP")
      pipController.startPictureInPicture()
    } else {
      NSLog("[MKPiP] start requested but not possible yet; deferring")
      pendingStart = true
      // Surface the failure if PiP never becomes possible.
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
        guard let that = self, that.pendingStart, !that.disposed else { return }
        that.pendingStart = false
        NSLog("[MKPiP] PiP still not possible 3s after start request")
        that.emit(
          "PictureInPicture.OnError",
          ["message": "Picture in Picture did not become possible within 3s"]
        )
      }
    }
    return true
  }

  public func stop() {
    NSLog("[MKPiP] stop")
    pendingStart = false
    pipController?.stopPictureInPicture()
  }

  public func setPlaybackState(position: Double, duration: Double, playing: Bool, rate: Double) {
    isPlaying = playing
    self.rate = rate
    self.duration = duration
    // The timebase models the video timeline: its current time is the playback
    // position and it advances at the playback rate. The PiP OSD reads
    // progress from it (against timeRangeForPlayback) and extrapolates
    // in-between these state pushes.
    if let timebase = timebase {
      CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 1000))
      CMTimebaseSetRate(timebase, rate: playing ? rate : 0.0)
    }
    pipController?.invalidatePlaybackState()
  }

  public func dispose() {
    NSLog("[MKPiP] dispose")
    queue.sync {
      disposed = true
    }
    pendingStart = false
    possibleObservation?.invalidate()
    possibleObservation = nil
    // Dropping the content source ends PiP immediately (no animation).
    pipController?.contentSource = nil
    pipController = nil
    displayLayer.flushAndRemoveImage()
    hostView.removeFromSuperview()
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    NSLog("[MKPiP] delegate setPlaying=%d", playing)
    // Optimistically mirror so the PiP button flips immediately; Dart confirms
    // through the next setPlaybackState.
    isPlaying = playing
    if let timebase = timebase {
      CMTimebaseSetRate(timebase, rate: playing ? rate : 0.0)
    }
    pictureInPictureController.invalidatePlaybackState()
    emit("PictureInPicture.OnSetPlaying", ["playing": playing])
  }

  public func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    if duration <= 0 {
      // Unknown duration (live/still loading): [0, +inf) renders as "Live"
      // and avoids the stuck loading indicator kCMTimeIndefinite causes.
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    return CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 1000)
    )
  }

  public func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    return !isPlaying
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    emit("PictureInPicture.OnSkip", ["interval": CMTimeGetSeconds(skipInterval)])
    completionHandler()
  }

  // MARK: - AVPictureInPictureControllerDelegate

  public func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("[MKPiP] did start")
    emit("PictureInPicture.OnStateChanged", ["active": true])
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("[MKPiP] did stop")
    emit("PictureInPicture.OnStateChanged", ["active": false])
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[MKPiP] failed to start: %@", error.localizedDescription)
    emit("PictureInPicture.OnError", ["message": error.localizedDescription])
  }

  public func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    emit("PictureInPicture.OnRestore", [:])
    completionHandler(true)
  }

  // MARK: - Helpers

  private func emit(_ method: String, _ arguments: [String: Any]) {
    var argumentsWithHandle = arguments
    argumentsWithHandle["handle"] = handle
    let emitEvent = self.emitEvent
    DispatchQueue.main.async {
      emitEvent(method, argumentsWithHandle)
    }
  }

  private static func rootView() -> UIView? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    let window = windows.first { $0.isKeyWindow } ?? windows.first
    return window?.rootViewController?.view ?? window
  }
}
