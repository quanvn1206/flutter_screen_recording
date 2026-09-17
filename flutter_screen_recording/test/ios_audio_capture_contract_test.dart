import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('captures microphone ReplayKit audio buffers, mic-only', () {
    final source = File(
      'ios/Classes/SwiftFlutterScreenRecordingPlugin.swift',
    ).readAsStringSync();

    expect(source, contains('case .audioMic'));
    expect(source, contains('micAudioWriterInput'));

    // Two-track (app + mic) capture, raw-PCM gain scaling, and an
    // AVFoundation mixdown export were all tried and reverted — none made
    // the mic audible in the resulting file, despite on-device diagnostics
    // proving ReplayKit delivered real, loud mic audio at every step (see
    // git history). Back to the simple, previously-working mic-only shape;
    // these guard against silently reintroducing that complexity.
    expect(source, isNot(contains('appAudioWriterInput')));
    expect(source, isNot(contains('exportMixedRecording')));
    expect(source, isNot(contains('AVMutableAudioMix')));
    expect(source, isNot(contains('func adjustGain')));
  });
}
