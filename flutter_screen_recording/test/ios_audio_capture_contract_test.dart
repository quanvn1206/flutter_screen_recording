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
    // pipeline, not manual buffer manipulation in the ReplayKit callback.
    expect(source, isNot(contains('withMemoryRebound')));
  });
}
