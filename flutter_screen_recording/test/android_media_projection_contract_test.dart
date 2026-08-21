import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final packageRoot = Directory.current.path;
  final manifest = File(
    '$packageRoot/android/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  final service = File(
    '$packageRoot/android/src/main/kotlin/com/isvisoft/flutter_screen_recording/ForegroundService.kt',
  ).readAsStringSync();
  final plugin = File(
    '$packageRoot/android/src/main/kotlin/com/isvisoft/flutter_screen_recording/FlutterScreenRecordingPlugin.kt',
  ).readAsStringSync();

  test('declares only the permissions required for recording', () {
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE'));
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'),
    );
    expect(manifest, contains('android:foregroundServiceType="mediaProjection"'));
    expect(manifest, contains('android:exported="false"'));
    expect(manifest, isNot(contains('android.permission.SYSTEM_ALERT_WINDOW')));
    expect(manifest, isNot(contains('android.permission.WAKE_LOCK')));
    expect(manifest, isNot(contains('android.permission.RECEIVE_BOOT_COMPLETED')));
  });

  test('does not package an unused second screen recorder', () {
    final gradle = File('$packageRoot/android/build.gradle').readAsStringSync();
    expect(gradle, isNot(contains('HBRecorder')));
  });

  test('does not request foreground-service permission from the service', () {
    expect(service, isNot(contains('requestPermissions')));
    expect(service, isNot(contains('this as Activity')));
  });

  test('starts recording only after MediaProjection consent', () {
    final consentIndex = plugin.indexOf('resultCode == Activity.RESULT_OK');
    final serviceStartIndex = plugin.indexOf(
      'ForegroundService.startService(context',
      consentIndex,
    );

    expect(consentIndex, isNonNegative);
    expect(serviceStartIndex, greaterThan(consentIndex));
  });

  test('starts the foreground service with the mediaProjection type', () {
    expect(
      service,
      contains('ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION'),
    );
  });
}
