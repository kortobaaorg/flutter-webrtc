import 'package:flutter/foundation.dart';

import '../utils.dart';

enum AppleAudioMode {
  default_,
  gameChat,
  measurement,
  moviePlayback,
  spokenAudio,
  videoChat,
  videoRecording,
  voiceChat,
  voicePrompt,
}

extension AppleAudioModeEnumEx on String {
  AppleAudioMode toAppleAudioMode() =>
      AppleAudioMode.values.firstWhere((d) => d.name == toLowerCase());
}

enum AppleAudioCategory {
  soloAmbient,
  playback,
  record,
  playAndRecord,
  multiRoute,
}

extension AppleAudioCategoryEnumEx on String {
  AppleAudioCategory toAppleAudioCategory() =>
      AppleAudioCategory.values.firstWhere((d) => d.name == toLowerCase());
}

enum AppleAudioCategoryOption {
  mixWithOthers,
  duckOthers,
  interruptSpokenAudioAndMixWithOthers,
  allowBluetooth,
  allowBluetoothA2DP,
  allowAirPlay,
  defaultToSpeaker,
}

extension AppleAudioCategoryOptionEnumEx on String {
  AppleAudioCategoryOption toAppleAudioCategoryOption() =>
      AppleAudioCategoryOption.values
          .firstWhere((d) => d.name == toLowerCase());
}

class AppleAudioConfiguration {
  AppleAudioConfiguration({
    this.appleAudioCategory,
    this.appleAudioCategoryOptions,
    this.appleAudioMode,
  });
  final AppleAudioCategory? appleAudioCategory;
  final Set<AppleAudioCategoryOption>? appleAudioCategoryOptions;
  final AppleAudioMode? appleAudioMode;

  Map<String, dynamic> toMap() => <String, dynamic>{
        if (appleAudioCategory != null)
          'appleAudioCategory': appleAudioCategory!.name,
        if (appleAudioCategoryOptions != null)
          'appleAudioCategoryOptions':
              appleAudioCategoryOptions!.map((e) => e.name).toList(),
        if (appleAudioMode != null) 'appleAudioMode': appleAudioMode!.name,
      };
}

enum AppleAudioIOMode {
  none,
  remoteOnly,
  localOnly,
  localAndRemote,
}

class AppleNativeAudioManagement {
  static AppleAudioIOMode currentMode = AppleAudioIOMode.none;

  static AppleAudioConfiguration getAppleAudioConfigurationForMode(
      AppleAudioIOMode mode,
      {bool preferSpeakerOutput = false}) {
    currentMode = mode;
    if (mode == AppleAudioIOMode.remoteOnly) {
      return AppleAudioConfiguration(
        appleAudioCategory: AppleAudioCategory.playback,
        appleAudioCategoryOptions: {
          AppleAudioCategoryOption.mixWithOthers,
        },
        appleAudioMode: AppleAudioMode.spokenAudio,
      );
    } else if ([
      AppleAudioIOMode.localOnly,
      AppleAudioIOMode.localAndRemote,
    ].contains(mode)) {
      return AppleAudioConfiguration(
        appleAudioCategory: AppleAudioCategory.playAndRecord,
        appleAudioCategoryOptions: {
          AppleAudioCategoryOption.allowBluetooth,
          AppleAudioCategoryOption.mixWithOthers,
        },
        appleAudioMode: preferSpeakerOutput
            ? AppleAudioMode.videoChat
            : AppleAudioMode.voiceChat,
      );
    }

    return AppleAudioConfiguration(
      appleAudioCategory: AppleAudioCategory.soloAmbient,
      appleAudioCategoryOptions: {},
      appleAudioMode: AppleAudioMode.default_,
    );
  }

  static Future<void> setAppleAudioConfiguration(
      AppleAudioConfiguration config) async {
    if (WebRTC.platformIsIOS) {
      // MAQ-AUDIO DIAGNOSTIC PROBE — TEMPORARY, DO NOT SHIP.
      // O4: every Dart-side AVAudioSession category write funnels through here.
      // The stack names the exact Dart caller, so no writer has to be inferred
      // from a matching option set. Uses dart:developer, not debugPrint, because
      // Sentry swallows debugPrint in non-debug builds.
      // debugPrint, NOT dart:developer.log — log() goes to the VM service
      // Logging stream and never reaches `flutter run` stdout, so it produced
      // zero lines on the first attempt. Sentry's DebugPrintIntegration is
      // disabled in main.dart (`enablePrintBreadcrumbs = false`), so
      // debugPrint really does print here.
      debugPrint(
        '[MAQ-AUDIO-DART] setAppleAudioConfiguration '
        'cat=${config.appleAudioCategory?.name} '
        'opts=${config.appleAudioCategoryOptions?.map((o) => o.name).join('|')} '
        'mode=${config.appleAudioMode?.name}\n'
        '${StackTrace.current}',
      );
      final sw = Stopwatch()..start();
      await WebRTC.invokeMethod(
        'setAppleAudioConfiguration',
        <String, dynamic>{'configuration': config.toMap()},
      );
      debugPrint('[MAQ-AUDIO-DART] setAppleAudioConfiguration returned in '
          '${sw.elapsedMilliseconds}ms');
    }
  }
}
