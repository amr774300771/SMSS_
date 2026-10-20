import 'dart:io';

import 'package:cardbot_qaidi/app_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  late Directory directory;
  late AppLock lock;

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('qadinet-lock-');
    Hive.init(directory.path);
  });

  setUp(() async {
    final box = await Hive.openBox('lock_test_${DateTime.now().microsecondsSinceEpoch}');
    lock = AppLock(box);
  });

  tearDownAll(() async {
    await Hive.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('validates PIN format', () {
    expect(AppLock.isValidPin('1234'), isTrue);
    expect(AppLock.isValidPin('123456'), isTrue);
    expect(AppLock.isValidPin('123'), isFalse);
    expect(AppLock.isValidPin('1234567'), isFalse);
    expect(AppLock.isValidPin('12a4'), isFalse);
  });

  test('stores only salted hashes and verifies the PIN', () async {
    expect(lock.enabled, isFalse);
    final recovery = await lock.setPin('4821');
    expect(lock.enabled, isTrue);
    expect(lock.pinLength, 4);
    expect(recovery, matches(RegExp(r'^\d{8}$')));
    expect(lock.box.get(AppLock.hashKey), isNot('4821'));
    expect((lock.box.get(AppLock.hashKey) as String).length, 64);
    expect(await lock.verify('4821'), isTrue);
    expect(await lock.verify('0000'), isFalse);
  });

  test('locks out after repeated failures and blocks even the right PIN', () async {
    await lock.setPin('4821');
    final now = DateTime(2026, 10, 19, 12);
    for (var i = 0; i < AppLock.freeAttempts; i++) {
      expect(await lock.verify('0000', now: now), isFalse);
    }
    expect(lock.remainingLockSeconds(now: now), 30);
    expect(await lock.verify('4821', now: now), isFalse);
    final later = now.add(const Duration(seconds: 31));
    expect(lock.remainingLockSeconds(now: later), 0);
    expect(await lock.verify('4821', now: later), isTrue);
    expect(lock.remainingLockSeconds(now: later), 0);
  });

  test('recovery code removes the lock; wrong code does not', () async {
    final recovery = await lock.setPin('4821');
    expect(await lock.resetWithRecoveryCode('00000000'), isFalse);
    expect(lock.enabled, isTrue);
    expect(await lock.resetWithRecoveryCode(recovery), isTrue);
    expect(lock.enabled, isFalse);
  });
}
