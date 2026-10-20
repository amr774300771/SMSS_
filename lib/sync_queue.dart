import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';
import 'cloud_sync.dart';

class LocalSyncQueue {
  static const boxName = 'sync_queue';
  final Box box;
  LocalSyncQueue(this.box);

  static Future<LocalSyncQueue> open() async => LocalSyncQueue(await Hive.openBox(boxName));

  Future<void> enqueue(SyncChange change) async {
    await box.put(change.id, {'change': change.toJson(), 'status': 'pending', 'attempts': 0, 'nextAttemptAt': DateTime.now().toIso8601String()});
  }

  List<Map<String, dynamic>> due({DateTime? now, int limit = 100}) {
    final current = now ?? DateTime.now();
    return box.values.map((value) => Map<String, dynamic>.from(value as Map)).where((item) {
      if (item['status'] == 'done') return false;
      final next = DateTime.tryParse('${item['nextAttemptAt']}');
      return next == null || !next.isAfter(current);
    }).take(limit).toList();
  }

  Future<Map<String, dynamic>> flush(CloudSyncClient client) async {
    final items = due();
    if (items.isEmpty) return {'accepted': <String>[], 'rejected': <String>[]};
    final changes = items.map((item) => SyncChange(entity: '${item['change']['entity']}', entityId: '${item['change']['entityId']}', operation: '${item['change']['operation']}', branchId: '${item['change']['branchId']}', deviceId: '${item['change']['deviceId']}', payload: Map<String, dynamic>.from(item['change']['payload'] as Map), id: '${item['change']['id']}')).toList();
    try {
      final result = await client.push(changes);
      final accepted = (result['accepted'] as List? ?? []).map((e) => '$e').toSet();
      for (final item in items) {
        final id = '${item['change']['id']}';
        if (accepted.contains(id)) await box.delete(id);
      }
      return result;
    } catch (_) {
      for (final item in items) {
        final attempts = (item['attempts'] as num? ?? 0).toInt() + 1;
        final seconds = min(300, 5 * pow(2, min(attempts, 6)).toInt());
        item['attempts'] = attempts;
        item['status'] = 'retrying';
        item['nextAttemptAt'] = DateTime.now().add(Duration(seconds: seconds)).toIso8601String();
        await box.put('${item['change']['id']}', item);
      }
      rethrow;
    }
  }

  int get pendingCount => box.values.where((value) => (value as Map)['status'] != 'done').length;
}
