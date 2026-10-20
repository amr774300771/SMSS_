import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

class Governance {
  Governance._();
  static final instance = Governance._();
  static const boxName = 'governance';

  Box get box => Hive.box(boxName);

  Future<void> ensureReady() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  List<Map<String, dynamic>> get auditLog {
    final raw = box.get('auditLog', defaultValue: const <dynamic>[]);
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> record(String action,
      {String details = '', String actor = 'المستخدم المحلي'}) async {
    await ensureReady();
    final entries = auditLog;
    entries.insert(0, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'time': DateTime.now().toIso8601String(),
      'action': action,
      'details': details,
      'actor': actor,
    });
    await box.put('auditLog', entries.take(500).toList());
  }

  Map<String, dynamic> get whatsappSafety => Map<String, dynamic>.from(
        (box.get('whatsappSafety', defaultValue: const <String, dynamic>{})
            as Map),
      );

  Future<void> saveWhatsAppSafety(Map<String, dynamic> value) async {
    await ensureReady();
    await box.put('whatsappSafety', value);
    await record('تعديل حماية WhatsApp');
  }

  Map<String, dynamic> get clientGroups => Map<String, dynamic>.from(
        (box.get('clientGroups', defaultValue: const <String, dynamic>{})
            as Map),
      );

  Future<void> saveClientGroups(Map<String, dynamic> value) async {
    await ensureReady();
    await box.put('clientGroups', value);
    await record('تعديل مجموعات العملاء');
  }

  List<Map<String, dynamic>> get scheduledBroadcasts {
    final raw = box.get('scheduledBroadcasts', defaultValue: const <dynamic>[]);
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> saveScheduledBroadcasts(List<Map<String, dynamic>> value) async {
    await ensureReady();
    await box.put('scheduledBroadcasts', value);
    await record('تعديل جدولة التنبيهات الجماعية');
  }

  Future<void> saveAutoBackup(bool enabled, int keepCount) async {
    await ensureReady();
    await box.put('autoBackup', {'enabled': enabled, 'keepCount': keepCount});
    await record('تعديل النسخ الاحتياطي التلقائي');
  }

  Map<String, dynamic> get autoBackup => Map<String, dynamic>.from(
        (box.get('autoBackup', defaultValue: const <String, dynamic>{}) as Map),
      );

  Future<void> saveRoles(Map<String, dynamic> value) async {
    await ensureReady();
    await box.put('roles', value);
    await record('تعديل صلاحيات الأدوار');
  }

  Map<String, dynamic> get roles => Map<String, dynamic>.from(
        (box.get('roles', defaultValue: const <String, dynamic>{}) as Map),
      );

  String exportLocalSettings() => jsonEncode({
        'whatsappSafety': whatsappSafety,
        'clientGroups': clientGroups,
        'scheduledBroadcasts': scheduledBroadcasts,
        'autoBackup': autoBackup,
        'roles': roles,
      });
}
