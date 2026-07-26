/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:media_kit_video/src/video_controller/video_controller.dart';

/// {@template picture_in_picture}
///
/// PictureInPicture
/// ----------------
///
/// Picture-in-Picture for the video output of a [VideoController].
///
/// Only implemented on iOS (15.0+), where the video output feeds an
/// `AVSampleBufferDisplayLayer` driven by `AVPictureInPictureController`.
/// On Android, PiP is a window-level concern (`enterPictureInPictureMode`)
/// and does not involve the video output; use a dedicated plugin instead.
///
/// All methods are safe no-ops on unsupported platforms.
///
/// {@endtemplate}
class PictureInPicture {
  /// The [VideoController] whose video output is mirrored into the PiP window.
  final VideoController controller;

  /// Invoked when the user toggles play/pause from the PiP window.
  void Function(bool playing)? onSetPlaying;

  /// Invoked when the user skips forward/backward from the PiP window.
  /// The interval is negative for backward skips.
  void Function(Duration interval)? onSkip;

  /// Invoked when PiP becomes active/inactive.
  void Function(bool active)? onActiveChanged;

  /// Invoked when the system's readiness to start PiP changes
  /// (`isPictureInPicturePossible`). Useful for diagnostics.
  void Function(bool possible)? onPossibleChanged;

  /// Invoked when the PiP window's "return to app" button is tapped.
  VoidCallback? onRestoreUserInterface;

  /// Invoked when PiP fails to start.
  void Function(String message)? onError;

  /// {@macro picture_in_picture}
  PictureInPicture(this.controller);

  int? _handle;

  static bool get _available => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Whether the current device supports Picture-in-Picture.
  static Future<bool> isSupported() async {
    if (!_available) {
      return false;
    }
    final supported = await _channel.invokeMethod('PictureInPicture.IsSupported');
    return supported == true;
  }

  /// Creates the native PiP resources & starts mirroring rendered frames.
  ///
  /// When [autoEnterOnBackground] is true, the system enters PiP automatically
  /// as the app moves to the background while this video is on screen.
  ///
  /// Returns true when PiP is ready for use. Safe to call again to update
  /// [autoEnterOnBackground].
  Future<bool> enable({bool autoEnterOnBackground = false}) async {
    if (!_available) {
      return false;
    }
    final handle = await controller.player.handle;
    _handle = handle;
    _instances[handle] = this;
    // The native video output is created asynchronously alongside the
    // controller; enabling before VideoOutputManager.Create lands fails.
    await controller.platform.future;
    final enabled = await _channel.invokeMethod('PictureInPicture.Enable', {
      'handle': handle.toString(),
      'autoEnter': autoEnterOnBackground,
    });
    if (enabled != true) {
      _instances.remove(handle);
      return false;
    }
    return true;
  }

  /// Releases the native PiP resources; exits PiP if currently active.
  Future<void> disable() async {
    if (!_available) {
      return;
    }
    final handle = _handle;
    if (handle == null) {
      return;
    }
    _handle = null;
    _instances.remove(handle);
    await _channel.invokeMethod('PictureInPicture.Disable', {
      'handle': handle.toString(),
    });
  }

  /// Enters PiP now (e.g. from an in-app button). Requires [enable] first.
  Future<bool> start() async {
    if (!_available || _handle == null) {
      return false;
    }
    final started = await _channel.invokeMethod('PictureInPicture.Start', {
      'handle': _handle.toString(),
    });
    return started == true;
  }

  /// Exits PiP, returning playback to the app.
  Future<void> stop() async {
    if (!_available || _handle == null) {
      return;
    }
    await _channel.invokeMethod('PictureInPicture.Stop', {
      'handle': _handle.toString(),
    });
  }

  /// Mirrors the playback state into the PiP window's controls & progress bar.
  ///
  /// Call on play/pause/seek/duration changes and periodically (~1s) while
  /// playing; the native side extrapolates the position in-between.
  Future<void> setPlaybackState({
    required Duration position,
    required Duration duration,
    required bool playing,
    double rate = 1.0,
  }) async {
    if (!_available || _handle == null) {
      return;
    }
    await _channel.invokeMethod('PictureInPicture.SetPlaybackState', {
      'handle': _handle.toString(),
      'position': position.inMilliseconds / 1000.0,
      'duration': duration.inMilliseconds / 1000.0,
      'playing': playing,
      'rate': rate,
    });
  }

  /// Dispatches a `PictureInPicture.*` platform channel event to the
  /// [PictureInPicture] instance it belongs to. Invoked by the shared channel
  /// handler; not part of the public API.
  static void handleMethodCall(MethodCall call) {
    final arguments = call.arguments;
    if (arguments is! Map) {
      return;
    }
    final handle = arguments['handle'];
    final instance = _instances[handle];
    if (instance == null) {
      return;
    }
    switch (call.method) {
      case 'PictureInPicture.OnSetPlaying':
        instance.onSetPlaying?.call(arguments['playing'] == true);
        break;
      case 'PictureInPicture.OnSkip':
        final seconds = arguments['interval'];
        if (seconds is num && seconds.isFinite) {
          instance.onSkip?.call(
            Duration(milliseconds: (seconds * 1000).round()),
          );
        }
        break;
      case 'PictureInPicture.OnStateChanged':
        instance.onActiveChanged?.call(arguments['active'] == true);
        break;
      case 'PictureInPicture.OnPossibleChanged':
        instance.onPossibleChanged?.call(arguments['possible'] == true);
        break;
      case 'PictureInPicture.OnRestore':
        instance.onRestoreUserInterface?.call();
        break;
      case 'PictureInPicture.OnError':
        instance.onError?.call(arguments['message']?.toString() ?? 'unknown error');
        break;
      default:
        break;
    }
  }

  /// Currently enabled [PictureInPicture]s, keyed by player handle.
  static final _instances = HashMap<int, PictureInPicture>();

  /// [MethodChannel] shared with the video output implementation; incoming
  /// `PictureInPicture.*` events are forwarded here by its handler.
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
}
