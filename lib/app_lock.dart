import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// قفل واجهة التطبيق برمز PIN من 4 إلى 6 أرقام.
///
/// يحمي الشاشة فقط من الاطلاع العرضي؛ لا يشفّر ملفات المخزون. محرك استقبال
/// الرسائل يستمر في العمل والتطبيق مقفل.
class AppLock {
  static const hashKey = 'appLockHash';
  static const saltKey = 'appLockSalt';
  static const lengthKey = 'appLockLength';
  static const recoveryHashKey = 'appLockRecoveryHash';
  static const recoverySaltKey = 'appLockRecoverySalt';
  static const failuresKey = 'appLockFailures';
  static const lockedUntilKey = 'appLockLockedUntil';

  static const minLength = 4;
  static const maxLength = 6;
  static const freeAttempts = 5;
  static const rounds = 10000;

  final Box box;
  AppLock(this.box);

  bool get enabled => box.get(hashKey) is String;
  int get pinLength => (box.get(lengthKey) as int?) ?? minLength;

  static bool isValidPin(String pin) =>
      pin.length >= minLength &&
      pin.length <= maxLength &&
      RegExp(r'^\d+$').hasMatch(pin);

  static String hash(String secret, String salt) {
    final saltBytes = utf8.encode(salt);
    var digest = sha256.convert([...saltBytes, 0x3A, ...utf8.encode(secret)]);
    for (var i = 0; i < rounds; i++) {
      digest = sha256.convert([...digest.bytes, ...saltBytes]);
    }
    return digest.toString();
  }

  static String _randomSalt() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  static String _randomRecoveryCode() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(10)).join();
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// يحفظ الرمز الجديد ويعيد رمز الاسترداد الذي يُعرض للمستخدم مرة واحدة فقط.
  Future<String> setPin(String pin) async {
    if (!isValidPin(pin)) {
      throw ArgumentError('يجب أن يتكون الرمز من 4 إلى 6 أرقام');
    }
    final salt = _randomSalt();
    final recoverySalt = _randomSalt();
    final recoveryCode = _randomRecoveryCode();
    await box.putAll({
      saltKey: salt,
      hashKey: hash(pin, salt),
      lengthKey: pin.length,
      recoverySaltKey: recoverySalt,
      recoveryHashKey: hash(recoveryCode, recoverySalt),
      failuresKey: 0,
      lockedUntilKey: 0,
    });
    return recoveryCode;
  }

  Future<void> clear() => box.deleteAll([
        hashKey,
        saltKey,
        lengthKey,
        recoveryHashKey,
        recoverySaltKey,
        failuresKey,
        lockedUntilKey,
      ]);

  /// الثواني المتبقية قبل السماح بمحاولة جديدة (0 إذا لا يوجد حظر).
  int remainingLockSeconds({DateTime? now}) {
    final until = (box.get(lockedUntilKey) as int?) ?? 0;
    final current = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return until > current ? ((until - current) / 1000).ceil() : 0;
  }

  Future<bool> verify(String pin, {DateTime? now}) async {
    if (!enabled || remainingLockSeconds(now: now) > 0) return false;
    final salt = box.get(saltKey) as String? ?? '';
    final ok = _constantTimeEquals(
        hash(pin, salt), box.get(hashKey) as String? ?? '');
    if (ok) {
      await box.putAll({failuresKey: 0, lockedUntilKey: 0});
      return true;
    }
    final failures = ((box.get(failuresKey) as int?) ?? 0) + 1;
    var lockedUntil = 0;
    if (failures >= freeAttempts) {
      final steps = min(failures - freeAttempts, 5);
      final seconds = min(30 * pow(2, steps).toInt(), 900);
      lockedUntil = (now ?? DateTime.now())
          .add(Duration(seconds: seconds))
          .millisecondsSinceEpoch;
    }
    await box.putAll({failuresKey: failures, lockedUntilKey: lockedUntil});
    return false;
  }

  /// يتحقق من رمز الاسترداد؛ عند النجاح يزيل القفل بالكامل.
  Future<bool> resetWithRecoveryCode(String code) async {
    final salt = box.get(recoverySaltKey) as String? ?? '';
    final stored = box.get(recoveryHashKey) as String? ?? '';
    if (stored.isEmpty || !_constantTimeEquals(hash(code.trim(), salt), stored)) {
      return false;
    }
    await clear();
    return true;
  }
}

/// يغلّف الواجهة ويعرض شاشة القفل عند الفتح وعند العودة بعد فترة في الخلفية.
class AppLockGate extends StatefulWidget {
  final Widget child;
  final Duration grace;

  const AppLockGate({
    super.key,
    required this.child,
    this.grace = const Duration(seconds: 30),
  });

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late final AppLock lock = AppLock(Hive.box('preferences'));
  late bool locked = lock.enabled;
  DateTime? pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = pausedAt;
      pausedAt = null;
      if (since != null &&
          lock.enabled &&
          DateTime.now().difference(since) >= widget.grace &&
          !locked) {
        setState(() => locked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (locked)
            Positioned.fill(
              child: PinLockScreen(
                lock: lock,
                onUnlocked: () => setState(() => locked = false),
              ),
            ),
        ],
      );
}

class PinLockScreen extends StatefulWidget {
  final AppLock lock;
  final VoidCallback onUnlocked;

  const PinLockScreen({super.key, required this.lock, required this.onUnlocked});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  String entered = '';
  String? error;
  Timer? ticker;
  bool busy = false;
  bool waiting = false;

  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final remaining = widget.lock.remainingLockSeconds();
      if (remaining > 0 || waiting) {
        waiting = remaining > 0;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> _press(String digit) async {
    if (busy || widget.lock.remainingLockSeconds() > 0) return;
    if (entered.length >= widget.lock.pinLength) return;
    setState(() {
      entered += digit;
      error = null;
    });
    if (entered.length == widget.lock.pinLength) {
      busy = true;
      final ok = await widget.lock.verify(entered);
      busy = false;
      if (!mounted) return;
      if (ok) {
        widget.onUnlocked();
      } else {
        HapticFeedback.heavyImpact();
        setState(() {
          entered = '';
          error = widget.lock.remainingLockSeconds() > 0
              ? 'محاولات كثيرة خاطئة'
              : 'الرمز غير صحيح';
        });
      }
    }
  }

  void _backspace() {
    if (entered.isEmpty) return;
    setState(() => entered = entered.substring(0, entered.length - 1));
  }

  Future<void> _forgot() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('استرداد الوصول'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('أدخل رمز الاسترداد المكوّن من 8 أرقام الذي ظهر عند تفعيل القفل.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: const InputDecoration(labelText: 'رمز الاسترداد'),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء')),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(90, 44)),
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('تأكيد')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (code == null || !mounted) return;
    final ok = await widget.lock.resetWithRecoveryCode(code);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() => error = 'رمز الاسترداد غير صحيح');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final length = widget.lock.pinLength;
    final wait = widget.lock.remainingLockSeconds();
    Widget pad(String label, {VoidCallback? onTap, IconData? icon}) =>
        SizedBox(
          width: 74,
          height: 64,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              minimumSize: const Size(74, 64),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            child: icon != null
                ? Icon(icon, size: 24)
                : Text(label,
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w700)),
          ),
        );
    return Material(
      color: scheme.surface,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.lock_rounded, size: 48, color: scheme.primary),
                const SizedBox(height: 12),
                const Text('القاضي نت مقفل',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text('أدخل رمز PIN للمتابعة',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < length; i++)
                      Container(
                        width: 15,
                        height: 15,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < entered.length
                              ? scheme.primary
                              : Colors.transparent,
                          border: Border.all(color: scheme.primary, width: 1.6),
                        ),
                      ),
                  ],
                ),
                SizedBox(
                  height: 38,
                  child: Center(
                    child: Text(
                      wait > 0 ? 'انتظر $wait ثانية قبل المحاولة' : (error ?? ''),
                      style: TextStyle(color: scheme.error, fontSize: 13),
                    ),
                  ),
                ),
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final digit in row)
                        pad(digit, onTap: () => _press(digit)),
                    ],
                  ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  pad('', onTap: _forgot, icon: Icons.help_outline),
                  pad('0', onTap: () => _press('0')),
                  pad('', onTap: _backspace, icon: Icons.backspace_outlined),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// حوار إنشاء الرمز؛ يعرض رمز الاسترداد مرة واحدة. يعيد true عند التفعيل.
Future<bool> showPinSetupDialog(BuildContext context, AppLock lock) async {
  final pin = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  final recoveryCode = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('تفعيل قفل التطبيق'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: AppLock.maxLength,
              decoration:
                  const InputDecoration(labelText: 'الرمز (4 إلى 6 أرقام)'),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: AppLock.maxLength,
              decoration: InputDecoration(
                  labelText: 'تأكيد الرمز', errorText: error),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(90, 44)),
              onPressed: () async {
                if (!AppLock.isValidPin(pin.text)) {
                  setState(() => error = 'الرمز يجب أن يكون من 4 إلى 6 أرقام');
                } else if (pin.text != confirm.text) {
                  setState(() => error = 'الرمزان غير متطابقين');
                } else {
                  final code = await lock.setPin(pin.text);
                  if (dialogContext.mounted) Navigator.pop(dialogContext, code);
                }
              },
              child: const Text('تفعيل'),
            ),
          ],
        ),
      ),
    ),
  );
  pin.dispose();
  confirm.dispose();
  if (recoveryCode == null) return false;
  if (!context.mounted) return true;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('احفظ رمز الاسترداد'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'إذا نسيت الرمز فهذا الرمز هو الطريقة الوحيدة لفتح التطبيق دون حذف بياناته. اكتبه في مكان آمن؛ لن يظهر مرة أخرى.'),
          const SizedBox(height: 14),
          SelectableText(recoveryCode,
              style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4)),
        ]),
        actions: [
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('حفظته')),
        ],
      ),
    ),
  );
  return true;
}

/// يطلب الرمز الحالي قبل إيقاف القفل. يعيد true عند الإيقاف.
Future<bool> showPinDisableDialog(BuildContext context, AppLock lock) async {
  final controller = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('إيقاف قفل التطبيق'),
          content: TextField(
            controller: controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: AppLock.maxLength,
            decoration:
                InputDecoration(labelText: 'الرمز الحالي', errorText: error),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(90, 44)),
              onPressed: () async {
                final valid = await lock.verify(controller.text);
                if (valid) {
                  await lock.clear();
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } else {
                  final wait = lock.remainingLockSeconds();
                  setState(() => error =
                      wait > 0 ? 'انتظر $wait ثانية' : 'الرمز غير صحيح');
                }
              },
              child: const Text('إيقاف'),
            ),
          ],
        ),
      ),
    ),
  );
  controller.dispose();
  return ok ?? false;
}
