import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('captures app and microphone ReplayKit audio buffers', () {
    final source = File(
      'ios/Classes/SwiftFlutterScreenRecordingPlugin.swift',
    ).readAsStringSync();

    expect(source, contains('case .audioApp'));
    expect(source, contains('case .audioMic'));
    expect(source, contains('appAudioWriterInput'));
    expect(source, contains('micAudioWriterInput'));
  });

  test('mixes the captured tracks into one audio track on stop', () {
    final source = File(
      'ios/Classes/SwiftFlutterScreenRecordingPlugin.swift',
    ).readAsStringSync();

    expect(source, contains('exportMixedRecording'));
    expect(source, contains('AVMutableAudioMix'));
    // Guards against reintroducing the raw-PCM gain scaling that caused
    // audible static — mixing must go through AVFoundation's export
    // pipeline, not by mutating sample buffers in the ReplayKit callback.
    // (Read-only inspection, like the peak-amplitude diagnostic, is fine —
    // this only bans the specific mutating helper that was reverted.)
    expect(source, isNot(contains('func adjustGain')));
    expect(source, isNot(contains('input.append(adjustGain')));
  });
}
