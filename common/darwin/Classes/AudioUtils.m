#if TARGET_OS_IPHONE
#import "AudioUtils.h"
#import <AVFoundation/AVFoundation.h>

@implementation AudioUtils

+ (void)ensureAudioSessionWithRecording:(BOOL)recording {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  // we also need to set default WebRTC audio configuration, since it may be activated after
  // this method is called
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  // 2026-08-15 FIX: this used to run ONLY when the category was not already
  // PlayAndRecord/MultiRoute. Recording a WhatsApp voice note leaves the session
  // in PlayAndRecord, so when a call was answered mid-recording the whole block
  // was skipped: the session kept the other app's options and mode, was never
  // activated, and the audio unit never started. The teacher was inaudible for
  // the entire call and nothing recovered it — not rejoining, not killing the
  // other app, not a network switch. Reproduced 3/3; the good calls showed 16
  // audio-session transitions at setup, the bad ones 4.
  //
  // Another app's PlayAndRecord is not ours. When we need to record, always
  // apply OUR configuration and, crucially, ACTIVATE the session.
  if (recording) {
    // Only impose the category when it is actually wrong. Re-applying it
    // unconditionally ALSO re-applies these options, which omit
    // DefaultToSpeaker — so it silently dragged a call the user had put on
    // speaker back to the earpiece, and the speaker button then only changed
    // the earpiece volume. Reported 2026-08-15, caused by this function
    // losing its category guard earlier the same day.
    const BOOL categoryIsWrong =
        session.category != AVAudioSessionCategoryPlayAndRecord &&
        session.category != AVAudioSessionCategoryMultiRoute;

    [session lockForConfiguration];
    NSError* error = nil;
    bool success = YES;
    if (categoryIsWrong) {
      config.category = AVAudioSessionCategoryPlayAndRecord;
      // Preserve whatever routing the session already had — notably
      // DefaultToSpeaker, which the app sets at launch.
      config.categoryOptions = session.categoryOptions |
          AVAudioSessionCategoryOptionAllowBluetooth |
          AVAudioSessionCategoryOptionAllowBluetoothA2DP |
          AVAudioSessionCategoryOptionAllowAirPlay;
      success = [session setCategory:config.category withOptions:config.categoryOptions error:&error];
      if (!success)
        NSLog(@"ensureAudioSessionWithRecording[true]: setCategory failed due to: %@", error);
    }
    // 2026-04-20 FIX: guard setMode to avoid -50 paramErr when CallKit already
    // set the mode on incoming calls (Android→iOS callee path).
    if (session.mode != config.mode) {
      success = [session setMode:config.mode error:&error];
      if (!success)
        NSLog(@"ensureAudioSessionWithRecording[true]: setMode failed due to: %@", error);
    }
    // Activation is the half that was missing entirely. A correctly-categorised
    // but inactive session is exactly what the silent calls had. A failure here
    // is logged rather than fatal — the CallKit incoming path can legitimately
    // return -50 and the call must still proceed.
    //
    // ONLY when not already active. RTCAudioSession refcounts activation
    // (incrementActivationCount) and only truly deactivates when the count
    // returns to zero. Calling this unconditionally — as this did when the
    // capture watchdog retried — drove "Number of current activations" to 9-10
    // on a single call, so the session could never be released. Observed on
    // device 2026-08-15; the leak was introduced by this very fix earlier the
    // same day.
    if (!session.isActive) {
      success = [session setActive:YES error:&error];
    } else {
      success = YES;
      NSLog(@"ensureAudioSessionWithRecording[true]: already active, not re-activating");
    }
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[true]: setActive failed due to: %@", error);
    else
      NSLog(@"ensureAudioSessionWithRecording[true]: session active, category=%@ mode=%@",
            session.category, session.mode);
    [session unlockForConfiguration];
  } else if (!recording && (session.category == AVAudioSessionCategoryAmbient ||
                            session.category == AVAudioSessionCategorySoloAmbient)) {
    config.mode = AVAudioSessionModeDefault;
    [session lockForConfiguration];
    NSError* error = nil;
    // 2026-04-20 FIX: guard setMode (see Android→iOS -50 note above).
    if (session.mode != config.mode) {
      bool success = [session setMode:config.mode error:&error];
      if (!success)
        NSLog(@"ensureAudioSessionWithRecording[false]: setMode failed due to: %@", error);
    }
    [session unlockForConfiguration];
  }
}

+ (BOOL)selectAudioInput:(AVAudioSessionPort)type {
  RTCAudioSession* rtcSession = [RTCAudioSession sharedInstance];
  AVAudioSessionPortDescription* inputPort = nil;
  for (AVAudioSessionPortDescription* port in rtcSession.session.availableInputs) {
    if ([port.portType isEqualToString:type]) {
      inputPort = port;
      break;
    }
  }
  if (inputPort != nil) {
    NSError* errOut = nil;
    [rtcSession lockForConfiguration];
    [rtcSession setPreferredInput:inputPort error:&errOut];
    [rtcSession unlockForConfiguration];
    if (errOut != nil) {
      return NO;
    }
    return YES;
  }
  return NO;
}

/// The last speaker preference the app actually asked for, so it can be
/// re-asserted after the system moves the route out from under us.
///
/// `overrideOutputAudioPort` is transient: it is dropped by a route change, by
/// an interruption, and by the session going inactive. Nothing here used to
/// remember what had been requested, so once iOS moved the call to the
/// receiver the override was simply gone and the app had no way to know the
/// route no longer matched the speaker button on screen.
static BOOL kSpeakerPreferenceRecorded = NO;
static BOOL kSpeakerPreferenceOn = NO;

+ (void)setSpeakerphoneOn:(BOOL)enable {
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  if(enable && config.category != AVAudioSessionCategoryPlayAndRecord) {
    NSLog(@"setSpeakerphoneOn: Category option 'defaultToSpeaker' is only applicable with category 'playAndRecord', ignore.");
    return;
  }

  kSpeakerPreferenceRecorded = YES;
  kSpeakerPreferenceOn = enable;
  [self applySpeakerphoneOn:enable];
}

/// Re-assert whatever was last requested through [setSpeakerphoneOn:].
///
/// A no-op until the app has expressed a preference — before that the session
/// should keep whatever route the system chose.
+ (void)reapplySpeakerPreference {
  if (!kSpeakerPreferenceRecorded) {
    return;
  }
  NSLog(@"reapplySpeakerPreference: re-asserting speaker=%@", kSpeakerPreferenceOn ? @"YES" : @"NO");
  [self applySpeakerphoneOn:kSpeakerPreferenceOn];
}

/// YES when the current output route matches [enable].
+ (BOOL)routeMatchesSpeakerphoneOn:(BOOL)enable session:(RTCAudioSession*)session {
  BOOL onBuiltInSpeaker = NO;
  for (AVAudioSessionPortDescription* output in session.session.currentRoute.outputs) {
    if ([output.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
      onBuiltInSpeaker = YES;
      break;
    }
  }
  return onBuiltInSpeaker == enable;
}

/// Apply the route and verify it landed, retrying up to three times.
///
/// The old implementation set the category, called `overrideOutputAudioPort:`
/// and returned — it never activated the session and never checked the
/// resulting route. An override applied while the session is inactive is
/// silently dropped, which is why the speaker button could report success and
/// change nothing but the volume. Verifying against `currentRoute` is the only
/// way to know; the error out-parameter reports the call, not the outcome.
+ (void)applySpeakerphoneOn:(BOOL)enable {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionAllowAirPlay |
                                          AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                          AVAudioSessionCategoryOptionAllowBluetooth;
  if (enable) {
    options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
  }

  // Nothing to do when the session already IS what this call would make it.
  //
  // The category write below was already guarded, but the port-override retry
  // loop underneath it was not, and that loop is where the time goes: measured
  // on device 2026-09-05, this method ran 103 times across two calls at a
  // median of 228ms and a worst case of 539ms, every one of them synchronous
  // on the main thread. Most did not change the route at all.
  //
  // Deliberately compares LIVE session state rather than caching a belief:
  // this session is process-wide and CallKit, WebRTC's audio device module and
  // the system all write to it behind our back, so a cache would go stale and
  // silently stop re-asserting the route — the 2026-08-17 bug.
  //
  // `isActive` is part of the condition, not an optimisation. On an inactive
  // session `currentRoute.outputs` can be empty, which reads as "not on the
  // speaker" and would match a request for the earpiece — skipping the
  // activation that the retry loop below exists to perform.
  if (session.isActive &&
      [session.category isEqualToString:config.category] &&
      session.categoryOptions == options &&
      [session.mode isEqualToString:config.mode] &&
      [self routeMatchesSpeakerphoneOn:enable session:session]) {
    return;
  }

  [session lockForConfiguration];
  NSError* error = nil;

  // 2026-04-20 FIX: guard setMode — skip if already correct mode.
  if (session.mode != config.mode) {
    [session setMode:config.mode error:&error];
  }
  // Only when it differs. Every setCategory raises an
  // AVAudioSessionRouteChangeReasonCategoryChange, and this function is itself
  // called from a route-change handler — re-applying an already-correct
  // category is how this became a self-sustaining loop on 2026-08-17. The
  // essential half of the re-assert is the port override below; the category is
  // only here for DefaultToSpeaker.
  if (session.category != config.category || session.categoryOptions != options) {
    if (![session setCategory:config.category withOptions:options error:&error]) {
      NSLog(@"applySpeakerphoneOn: setCategory failed due to: %@", error);
    }
  }

  AVAudioSessionPortOverride override =
      enable ? AVAudioSessionPortOverrideSpeaker : AVAudioSessionPortOverrideNone;

  for (int attempt = 1; attempt <= 3; attempt++) {
    error = nil;
    if (![session overrideOutputAudioPort:override error:&error]) {
      NSLog(@"applySpeakerphoneOn: port override attempt %d failed due to: %@", attempt, error);
    }

    if ([self routeMatchesSpeakerphoneOn:enable session:session]) {
      if (attempt > 1) {
        NSLog(@"applySpeakerphoneOn: route settled on attempt %d (speaker=%@)", attempt,
              enable ? @"YES" : @"NO");
      }
      break;
    }

    // The override did not take. The usual reason is an inactive session — an
    // override only applies to a running route. Activate and try again.
    //
    // Guarded on isActive deliberately: RTCAudioSession refcounts activation,
    // and an unconditional setActive:YES here leaks a count on every call. One
    // call on 2026-08-15 was observed at an activation count of 9.
    if (!session.isActive) {
      error = nil;
      if (![session setActive:YES error:&error]) {
        NSLog(@"applySpeakerphoneOn: setActive failed due to: %@", error);
        break;
      }
      continue;
    }

    if (attempt == 3) {
      NSLog(@"applySpeakerphoneOn: route still does not match after 3 attempts "
            @"(wanted speaker=%@, current route=%@)",
            enable ? @"YES" : @"NO", session.session.currentRoute.outputs);
    }
  }

  [session unlockForConfiguration];
}

+ (void)setSpeakerphoneOnButPreferBluetooth {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  [session lockForConfiguration];
  NSError* error = nil;
  // 2026-04-20 FIX: guard setMode — skip if already correct mode.
  if (session.mode != config.mode) {
    [session setMode:config.mode error:&error];
  }
  BOOL success = [session setCategory:config.category
                          withOptions:AVAudioSessionCategoryOptionAllowAirPlay |
                                      AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                      AVAudioSessionCategoryOptionAllowBluetooth |
                                      AVAudioSessionCategoryOptionDefaultToSpeaker
                                error:&error];

  success = [session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_None
                                        error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOnButPreferBluetooth: Port override failed due to: %@", error);

  success = [session setActive:YES error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOnButPreferBluetooth: Audio session override failed: %@", error);
  else
    NSLog(@"AudioSession override with bluetooth preference via setSpeakerphoneOnButPreferBluetooth successfull ");
  [session unlockForConfiguration];
}

+ (void)deactiveRtcAudioSession {
  NSError* error = nil;
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  [session lockForConfiguration];
  if ([session isActive]) {
    BOOL success = [session setActive:NO error:&error];
    if (!success)
      NSLog(@"RTC Audio session deactive failed: %@", error);
    else
      NSLog(@"RTC AudioSession deactive is successful ");
  }
  [session unlockForConfiguration];
}


+ (AVAudioSessionMode)audioSessionModeFromString:(NSString*)mode {
  if([@"default_" isEqualToString:mode]) {
    return AVAudioSessionModeDefault;
  } else if([@"voicePrompt" isEqualToString:mode]) {
    return AVAudioSessionModeVoicePrompt;
  } else if([@"videoRecording" isEqualToString:mode]) {
    return AVAudioSessionModeVideoRecording;
  } else if([@"videoChat" isEqualToString:mode]) {
    return AVAudioSessionModeVideoChat;
  } else if([@"voiceChat" isEqualToString:mode]) {
    return AVAudioSessionModeVoiceChat;
  } else if([@"gameChat" isEqualToString:mode]) {
    return AVAudioSessionModeGameChat;
  } else if([@"measurement" isEqualToString:mode]) {
    return AVAudioSessionModeMeasurement;
  } else if([@"moviePlayback" isEqualToString:mode]) {
    return AVAudioSessionModeMoviePlayback;
  } else if([@"spokenAudio" isEqualToString:mode]) {
    return AVAudioSessionModeSpokenAudio;
  } 
  return AVAudioSessionModeDefault;
}

+ (AVAudioSessionCategory)audioSessionCategoryFromString:(NSString *)category {
  if([@"ambient" isEqualToString:category]) {
    return AVAudioSessionCategoryAmbient;
  } else if([@"soloAmbient" isEqualToString:category]) {
    return AVAudioSessionCategorySoloAmbient;
  } else if([@"playback" isEqualToString:category]) {
    return AVAudioSessionCategoryPlayback;
  } else if([@"record" isEqualToString:category]) {
    return AVAudioSessionCategoryRecord;
  } else if([@"playAndRecord" isEqualToString:category]) {
    return AVAudioSessionCategoryPlayAndRecord;
  } else if([@"multiRoute" isEqualToString:category]) {
    return AVAudioSessionCategoryMultiRoute;
  }
  return AVAudioSessionCategoryAmbient;
}

+ (void) setAppleAudioConfiguration:(NSDictionary*)configuration {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  NSString* appleAudioCategory = configuration[@"appleAudioCategory"];
  NSArray* appleAudioCategoryOptions = configuration[@"appleAudioCategoryOptions"];
  NSString* appleAudioMode = configuration[@"appleAudioMode"];
  
  [session lockForConfiguration];

  if(appleAudioCategoryOptions != nil) {
    config.categoryOptions = 0;
    // Transport options are OR'd in below, after the caller's set is parsed.
    for(NSString* option in appleAudioCategoryOptions) {
      if([@"mixWithOthers" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionMixWithOthers;
      } else if([@"duckOthers" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionDuckOthers;
      } else if([@"allowBluetooth" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetooth;
      } else if([@"allowBluetoothA2DP" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
      } else if([@"allowAirPlay" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowAirPlay;
      } else if([@"defaultToSpeaker" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
      }
    }
  }

  // Every writer of this session must request the SAME transport options, or
  // each one's "is it already correct?" guard sees the other's set, decides it
  // differs, and writes — a permanent ping-pong.
  //
  // Measured on device 2026-09-05: on the loudspeaker the session alternated
  // between `allowBluetooth|A2DP|allowAirPlay|defaultToSpeaker` (written by
  // `applySpeakerphoneOn`) and `allowBluetooth|A2DP|defaultToSpeaker` (written
  // here) — the two differ only in AllowAirPlay. Result: on the earpiece 18 of
  // 22 writes were skipped by the guard, on the speaker only 1 of 13, and the
  // speaker kept the 1.8s main-thread stalls the earpiece no longer had.
  //
  // These three are transport permissions — which output devices MAY be used.
  // No call path here wants them off, and `ensureAudioSessionWithRecording`
  // already ORs the same three in for the same reason. DefaultToSpeaker is
  // deliberately NOT in this set: that one is the route decision itself, and
  // forcing it would put every call on the loudspeaker.
  config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetooth |
                            AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                            AVAudioSessionCategoryOptionAllowAirPlay;

  if(appleAudioCategory != nil) {
    config.category = [AudioUtils audioSessionCategoryFromString:appleAudioCategory];
    // Only when it would actually change something. `config` is still updated
    // above regardless — it is the process-wide webRTCConfiguration that the
    // iOS bridge replays on the next CallKit activation, and that replay is
    // load-bearing. What is skipped is the live `setCategory`, which cost a
    // median of 354ms on the main thread across 73 measured invocations, most
    // of which set the session to what it already was.
    if (![session.category isEqualToString:config.category] ||
        session.categoryOptions != config.categoryOptions) {
      [session setCategory:config.category withOptions:config.categoryOptions error:nil];
    }
  }

  if(appleAudioMode != nil) {
    config.mode = [AudioUtils audioSessionModeFromString:appleAudioMode];
    // 2026-04-20 FIX: guard setMode — skip if already correct mode.
    if (session.mode != config.mode) {
      [session setMode:config.mode error:nil];
    }
  }

  [session unlockForConfiguration];

}

@end
#endif
