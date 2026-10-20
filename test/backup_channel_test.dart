import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/native_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.qadinet.cardbot/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'exportBackup') return 'backup-content';
      if (call.method == 'restoreBackup') {
        return <String, dynamic>{
          'hasAppPreferences': true,
          'appPreferences': <String, dynamic>{'dark': true},
        };
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('export and restore carry current and backed-up app preferences',
      () async {
    final api = NativeApi.instance;
    final exported = await api.exportBackup(
      password: 'test-password',
      appPreferences: const {'dark': true, 'density': 'compact'},
    );

    expect(exported, 'backup-content');
    expect(calls.first.method, 'exportBackup');
    final exportArguments = Map<String, dynamic>.from(calls.first.arguments);
    expect(exportArguments['password'], 'test-password');
    expect(
      jsonDecode(exportArguments['appPreferences'] as String),
      {'dark': true, 'density': 'compact'},
    );

    final restored = await api.restoreBackup(
      'encrypted-backup',
      mode: 'replace_all',
      password: 'test-password',
      currentAppPreferences: const {'dark': false},
    );

    expect(calls.last.method, 'restoreBackup');
    final restoreArguments = Map<String, dynamic>.from(calls.last.arguments);
    expect(restoreArguments['mode'], 'replace_all');
    expect(
      jsonDecode(restoreArguments['currentAppPreferences'] as String),
      {'dark': false},
    );
    expect(restored['hasAppPreferences'], isTrue);
    expect(restored['appPreferences'], {'dark': true});
  });
}
