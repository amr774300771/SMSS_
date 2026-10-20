import 'governance.dart';
import 'operator_permissions.dart';

/// Hive-backed persistence and operation-boundary enforcement for local roles.
///
/// `actorIsManager` MUST come from a trusted, authenticated session/host check;
/// never derive it from a text field or from the permission override map.
/// Remote API actions must also be authorized by the server.
class OperatorPermissionService {
  OperatorPermissionService({Governance? governance})
      : _governance = governance ?? Governance.instance;

  final Governance _governance;

  Future<Map<String, dynamic>> load() async {
    await _governance.ensureReady();
    return _governance.operatorPermissionOverrides;
  }

  Future<void> save({
    required Map<String, dynamic> overrides,
    required String actorId,
    required bool actorIsManager,
  }) async {
    if (!actorIsManager) {
      await _governance.record(
        'رفض تعديل صلاحيات المشغّلين',
        details: 'actorId=${_safe(actorId)}',
        actor: _safe(actorId),
      );
      throw const _PermissionDenied('users.manage');
    }
    await _governance.ensureReady();
    // Keep only known capability names and stable, non-empty operator IDs.
    final sanitized = <String, dynamic>{};
    for (final entry in overrides.entries) {
      final id = entry.key.trim();
      if (id.isEmpty || entry.value is! Map) continue;
      final value = Map<String, dynamic>.from(entry.value as Map);
      final allow = _known(value['allow']);
      final deny = _known(value['deny'])..removeAll(allow);
      sanitized[id] = {
        'allow': allow.toList()..sort(),
        'deny': deny.toList()..sort(),
      };
    }
    await _governance.saveOperatorPermissionOverrides(
      sanitized,
      actor: _safe(actorId),
    );
  }

  Future<bool> allows({
    required String operatorId,
    required String capability,
    required bool actorIsManager,
  }) async {
    final overrides = await load();
    return OperatorPermissionPolicy.allows(
      operatorId: operatorId,
      capability: capability,
      overrides: overrides,
      isManager: actorIsManager,
    );
  }

  /// Call at the operation boundary, immediately before the actual mutation.
  /// Logs both denial and result. It cannot replace authorization in a server
  /// or Android native service that independently owns the operation.
  Future<T> run<T>({
    required String operatorId,
    required String capability,
    required bool actorIsManager,
    required Future<T> Function() operation,
    String details = '',
  }) async {
    final actor = _safe(operatorId);
    final allowed = await allows(
      operatorId: operatorId,
      capability: capability,
      actorIsManager: actorIsManager,
    );
    if (!allowed) {
      await _governance.record(
        'رفض عملية غير مصرح بها',
        details: 'capability=$capability; $details',
        actor: actor,
      );
      throw _PermissionDenied(capability);
    }

    await _governance.record(
      'بدء عملية مصرح بها',
      details: 'capability=$capability; $details',
      actor: actor,
    );
    try {
      final result = await operation();
      await _governance.record(
        'نجاح عملية مصرح بها',
        details: 'capability=$capability; $details',
        actor: actor,
      );
      return result;
    } catch (error) {
      await _governance.record(
        'فشل عملية مصرح بها',
        details: 'capability=$capability; error=${error.runtimeType}; $details',
        actor: actor,
      );
      rethrow;
    }
  }

  Set<String> _known(dynamic value) => value is List
      ? value
          .whereType<String>()
          .where(OperatorPermissionPolicy.capabilities.contains)
          .toSet()
      : <String>{};

  String _safe(String value) => value.trim().isEmpty ? 'unknown' : value.trim();
}

class _PermissionDenied implements Exception {
  const _PermissionDenied(this.capability);
  final String capability;
  @override
  String toString() => 'غير مصرح بتنفيذ العملية: $capability';
}
