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

+ (void)setSpeakerphoneOn:(BOOL)enable {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
    
  if(enable && config.category != AVAudioSessionCategoryPlayAndRecord) {
    NSLog(@"setSpeakerphoneOn: Category option 'defaultToSpeaker' is only applicable with category 'playAndRecord', ignore.");
    return;
  }

  [session lockForConfiguration];
  NSError* error = nil;
  if (!enable) {
    // 2026-04-20 FIX: guard setMode — skip if already correct mode.
    if (session.mode != config.mode) {
      [session setMode:config.mode error:&error];
    }
    BOOL success = [session setCategory:config.category
                            withOptions:AVAudioSessionCategoryOptionAllowAirPlay |
                                        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                        AVAudioSessionCategoryOptionAllowBluetooth
                                  error:&error];

    success = [session.session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_None
                                                 error:&error];
    if (!success)
      NSLog(@"setSpeakerphoneOn: Port override failed due to: %@", error);
  } else {
    // 2026-04-20 FIX: guard setMode — skip if already correct mode.
    if (session.mode != config.mode) {
      [session setMode:config.mode error:&error];
    }
    BOOL success = [session setCategory:config.category
                            withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                        AVAudioSessionCategoryOptionAllowAirPlay |
                                        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                        AVAudioSessionCategoryOptionAllowBluetooth
                                  error:&error];

    success = [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                         error:&error];
    if (!success)
      NSLog(@"setSpeakerphoneOn: Port override failed due to: %@", error);
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

  if(appleAudioCategory != nil) {
    config.category = [AudioUtils audioSessionCategoryFromString:appleAudioCategory];
    [session setCategory:config.category withOptions:config.categoryOptions error:nil];
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
