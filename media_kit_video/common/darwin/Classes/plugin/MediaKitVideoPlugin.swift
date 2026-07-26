#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

#if os(iOS)
  import AVKit
#endif

public class MediaKitVideoPlugin: NSObject, FlutterPlugin {
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if canImport(Flutter)
      let binaryMessenger = registrar.messenger()
      let registry = registrar.textures()
      let utils: UtilsProtocol? = nil
    #elseif canImport(FlutterMacOS)
      let binaryMessenger = registrar.messenger
      let registry = registrar.textures
      let utils: UtilsProtocol? = Utils(registrar)
    #endif

    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let utils: UtilsProtocol?

  #if os(iOS)
    // Values are PictureInPictureController (iOS 15+); typed as NSObject so the
    // stored property needs no availability annotation.
    private var pipControllers = [Int64: NSObject]()
  #endif

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    videoOutputManager = VideoOutputManager(
      registry: registry
    )
    self.utils = utils
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "VideoOutputManager.Create":
      handleCreateMethodCall(call.arguments, result)
    case "VideoOutputManager.SetSize":
      handleSetSizeMethodCall(call.arguments, result)
    case "VideoOutputManager.Dispose":
      handleDisposeMethodCall(call.arguments, result)
    case "Utils.EnterNativeFullscreen":
      handleEnterNativeFullscreenMethodCall(call.arguments, result)
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    #if os(iOS)
      case "PictureInPicture.IsSupported":
        handlePipIsSupportedMethodCall(call.arguments, result)
      case "PictureInPicture.Enable":
        handlePipEnableMethodCall(call.arguments, result)
      case "PictureInPicture.Disable":
        handlePipDisableMethodCall(call.arguments, result)
      case "PictureInPicture.Start":
        handlePipStartMethodCall(call.arguments, result)
      case "PictureInPicture.Stop":
        handlePipStopMethodCall(call.arguments, result)
      case "PictureInPicture.SetPlaybackState":
        handlePipSetPlaybackStateMethodCall(call.arguments, result)
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  #if os(iOS)
    private func pipHandle(_ arguments: Any?) -> Int64? {
      let args = arguments as? [String: Any]
      guard let handleStr = args?["handle"] as? String else {
        return nil
      }
      return Int64(handleStr)
    }

    @available(iOS 15.0, *)
    private func pipController(_ handle: Int64) -> PictureInPictureController? {
      return pipControllers[handle] as? PictureInPictureController
    }

    private func handlePipIsSupportedMethodCall(
      _: Any?,
      _ result: FlutterResult
    ) {
      if #available(iOS 15.0, *) {
        result(AVPictureInPictureController.isPictureInPictureSupported())
      } else {
        result(false)
      }
    }

    private func handlePipEnableMethodCall(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      let args = arguments as? [String: Any]
      let autoEnter = args?["autoEnter"] as? Bool ?? false

      guard let handle = pipHandle(arguments) else {
        return result(false)
      }
      guard #available(iOS 15.0, *),
        AVPictureInPictureController.isPictureInPictureSupported()
      else {
        return result(false)
      }
      guard let videoOutput = videoOutputManager.get(handle: handle) else {
        return result(false)
      }

      if let existing = pipController(handle) {
        existing.setAutoEnter(autoEnter)
        return result(true)
      }

      guard
        let pip = PictureInPictureController(
          handle: handle,
          autoEnter: autoEnter,
          emitEvent: { [weak self] method, arguments in
            self?.channel.invokeMethod(method, arguments: arguments)
          }
        )
      else {
        return result(false)
      }

      videoOutput.frameConsumer = pip
      pipControllers[handle] = pip
      // Prime the layer with the latest frame so PiP is possible while paused.
      if let pixelBuffer = videoOutput.currentPixelBuffer() {
        pip.enqueue(pixelBuffer, size: .zero)
      }
      result(true)
    }

    private func handlePipDisableMethodCall(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      if let handle = pipHandle(arguments) {
        disposePipController(handle)
      }
      result(nil)
    }

    private func handlePipStartMethodCall(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      guard let handle = pipHandle(arguments), #available(iOS 15.0, *),
        let pip = pipController(handle)
      else {
        return result(false)
      }
      let args = arguments as? [String: Any]
      let moveAppToBackground = args?["moveAppToBackground"] as? Bool ?? false
      result(pip.start(moveAppToBackground: moveAppToBackground))
    }

    private func handlePipStopMethodCall(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      if let handle = pipHandle(arguments), #available(iOS 15.0, *) {
        pipController(handle)?.stop()
      }
      result(nil)
    }

    private func handlePipSetPlaybackStateMethodCall(
      _ arguments: Any?,
      _ result: FlutterResult
    ) {
      let args = arguments as? [String: Any]
      if let handle = pipHandle(arguments), #available(iOS 15.0, *),
        let pip = pipController(handle)
      {
        pip.setPlaybackState(
          position: (args?["position"] as? NSNumber)?.doubleValue ?? 0,
          duration: (args?["duration"] as? NSNumber)?.doubleValue ?? 0,
          playing: args?["playing"] as? Bool ?? false,
          rate: (args?["rate"] as? NSNumber)?.doubleValue ?? 1.0
        )
      }
      result(nil)
    }

    private func disposePipController(_ handle: Int64) {
      if #available(iOS 15.0, *), let pip = pipController(handle) {
        videoOutputManager.get(handle: handle)?.frameConsumer = nil
        pip.dispose()
      }
      pipControllers[handle] = nil
    }
  #endif

  private func handleCreateMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)
    let configDict = args?["configuration"] as! [String: Any]
    let configuration = VideoOutputConfiguration.fromDict(configDict)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.create(
      handle: handle!,
      configuration: configuration,
      textureUpdateCallback: { (_ textureId: Int64, _ size: CGSize) in
        self.channel.invokeMethod(
          "VideoOutput.Resize",
          arguments: [
            "handle": handle!,
            "id": textureId,
            "rect": [
              "top": 0,
              "left": 0,
              "width": size.width,
              "height": size.height,
            ],
          ] as [String: Any]
        )
      }
    )

    result(nil)
  }

  private func handleSetSizeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let widthStr = args?["width"] as! String
    let heightStr = args?["height"] as! String

    let handle: Int64? = Int64(handleStr)
    let width: Int64? = Int64(widthStr)
    let height: Int64? = Int64(heightStr)

    assert(handle != nil, "handle must be an Int64")

    self.videoOutputManager.setSize(
      handle: handle!,
      width: width,
      height: height
    )

    result(nil)
  }

  private func handleDisposeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)

    assert(handle != nil, "handle must be an Int64")

    #if os(iOS)
      disposePipController(handle!)
    #endif

    videoOutputManager.destroy(
      handle: handle!
    )

    result(nil)
  }

  private func handleEnterNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.enterNativeFullscreen()
    result(nil)
  }

  private func handleExitNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.exitNativeFullscreen()
    result(nil)
  }
}
