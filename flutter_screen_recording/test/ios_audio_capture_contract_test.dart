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
}
