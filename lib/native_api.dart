import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

class PickedContact {
  final String name;
  final String phone;
  const PickedContact({required this.name, required this.phone});
}

class NativeApi {
  NativeApi._();
  static final NativeApi instance = NativeApi._();
  static const _channel = MethodChannel('com.qadinet.cardbot/native');
  Map<String, dynamic> _snapshot = {};
  Map<String, dynamic> get snapshot => _snapshot;

  Future<Map<String, dynamic>> initialize() async {
    final defaults = jsonDecode(
      await rootBundle.loadString('assets/defaults.json'),
    ) as Map<String, dynamic>;
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('initialize', {
        'defaults': defaults.map((k, v) => MapEntry(k, v.toString())),
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> refresh() async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('snapshot'),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> saveConfig(
    String filename,
    Map<String, dynamic> json,
  ) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('saveConfig', {
        'filename': filename,
        'content': jsonEncode(json),
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> updatePackagePrice(
    String oldPackageId,
    Map<String, dynamic> completePackagesConfig,
  ) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('updatePackagePrice', {
        'oldPackageId': oldPackageId,
        'content': jsonEncode(completePackagesConfig),
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> saveClientAndTrusted(
    Map<String, dynamic> permissions,
    Map<String, dynamic> trusted,
  ) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('saveClientAndTrusted', {
        'permissions': jsonEncode(permissions),
        'trusted': jsonEncode(trusted),
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> addCards(String id, List<String> cards) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('addCards', {
        'packageId': id,
        'cards': cards,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> updateInventory(
    List<Map<String, dynamic>> changes,
  ) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('updateInventory', {
        'changes': jsonEncode(changes),
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> undoInventoryChange() async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('undoInventoryChange'),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> deletePackage(String id) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('deletePackage', {'packageId': id}),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> restoreDeletedPackage({
    required String id,
    required Map<String, dynamic> originalPackages,
    required Map<String, dynamic> originalPermissions,
    required List<String> cards,
  }) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('restoreDeletedPackage', {
        'packageId': id,
        'originalPackages': jsonEncode(originalPackages),
        'originalPermissions': jsonEncode(originalPermissions),
        'cards': cards,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> sell(
    String id,
    String phone, {
    String name = '',
    bool sendSms = false,
    String paymentMethod = 'cash',
  }) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMethod('sell', {
          'packageId': id,
          'phone': phone,
          'clientName': name,
          'sendSms': sendSms,
          'paymentMethod': paymentMethod,
        }),
      );

  Future<Map<String, dynamic>> manualSale({required String phone, String name = '', required String description, required int quantity, required int unitPrice, int unitCost = 0, String paymentMethod = 'cash'}) async {
    _snapshot = Map<String, dynamic>.from(await _channel.invokeMethod('manualSale', {
      'phone': phone,
      'clientName': name,
      'description': description,
      'quantity': quantity,
      'unitPrice': unitPrice,
      'unitCost': unitCost,
      'paymentMethod': paymentMethod,
    }));
    return _snapshot;
  }

  Future<Map<String, dynamic>> bulkSell({required Map<String, int> quantities, required String phone, String name = '', String paymentMethod = 'cash'}) async {
    final result = Map<String, dynamic>.from(await _channel.invokeMethod('bulkSell', {
      'quantities': quantities,
      'phone': phone,
      'clientName': name,
      'paymentMethod': paymentMethod,
    }));
    _snapshot = result;
    return result;
  }

  Future<Map<String, dynamic>> scheduleSale(
    String id,
    String phone, {
    String name = '',
    required int price,
    String paymentMethod = 'cash',
    required DateTime scheduledAt,
  }) async {
    final result = Map<String, dynamic>.from(
      await _channel.invokeMethod('scheduleSale', {
        'packageId': id,
        'phone': phone,
        'clientName': name,
        'price': price,
        'paymentMethod': paymentMethod,
        'scheduledAtMillis': scheduledAt.millisecondsSinceEpoch,
      }),
    );
    _snapshot = Map<String, dynamic>.from(result['snapshot'] as Map);
    return result;
  }

  Future<Map<String, dynamic>> cancelScheduledSale(String scheduleId) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel
          .invokeMethod('cancelScheduledSale', {'scheduleId': scheduleId}),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> returnSale(String transactionId,
      {String reason = ''}) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('returnSale', {
        'transactionId': transactionId,
        'reason': reason,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> recordReceipt({
    required String phone,
    required int amount,
    required String paymentMethod,
    String reference = '',
    String note = '',
    String clientName = '',
  }) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('recordReceipt', {
        'phone': phone,
        'amount': amount,
        'paymentMethod': paymentMethod,
        'reference': reference,
        'note': note,
        'clientName': clientName,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> recordAdjustment({
    required String phone,
    required int amount,
    required String direction,
    required String reason,
    String clientName = '',
  }) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('recordAdjustment', {
        'phone': phone,
        'amount': amount,
        'direction': direction,
        'reason': reason,
        'clientName': clientName,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> setManualDebtBalance({
    required String phone,
    required int targetBalance,
    required String reason,
    String clientName = '',
  }) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('setManualDebtBalance', {
        'phone': phone,
        'targetBalance': targetBalance,
        'reason': reason,
        'clientName': clientName,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> markSaleReceived(String transactionId) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('markSaleReceived', {
        'transactionId': transactionId,
      }),
    );
    return _snapshot;
  }

  Future<Map<String, dynamic>> serviceDiagnostics() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMethod('serviceDiagnostics') ?? const {},
      );

  Future<bool> hasWhatsAppNotificationAccess() async =>
      await _channel.invokeMethod<bool>('hasWhatsAppNotificationAccess') ??
      false;

  Future<void> openWhatsAppNotificationSettings() async =>
      _channel.invokeMethod<void>('openWhatsAppNotificationSettings');

  Future<String> exportBackup({
    String password = '',
    Map<String, dynamic> appPreferences = const {},
  }) async =>
      await _channel.invokeMethod<String>('exportBackup', {
        'password': password,
        'appPreferences': jsonEncode(appPreferences),
      }) ??
      '';

  Future<Map<String, dynamic>> restoreBackup(
    String content, {
    required String mode,
    String password = '',
    Map<String, dynamic> currentAppPreferences = const {},
  }) async {
    _snapshot = Map<String, dynamic>.from(
      await _channel.invokeMethod('restoreBackup', {
        'content': content,
        'mode': mode,
        'password': password,
        'currentAppPreferences': jsonEncode(currentAppPreferences),
      }),
    );
    return _snapshot;
  }

  Future<bool> sendSms(String phone, String message) async =>
      await _channel.invokeMethod<bool>('sendSms', {
        'phone': phone,
        'message': message,
      }) ??
      false;

  /// Opens the device SMS app with the recipient and message prefilled.
  /// The user remains responsible for pressing Send.
  Future<bool> openSmsComposer(String phone, String message) async =>
      await _channel.invokeMethod<bool>('openSmsComposer', {
        'phone': phone,
        'message': message,
      }) ??
      false;

  Future<void> startService() => _channel.invokeMethod<void>('startService');
  Future<void> stopService() => _channel.invokeMethod<void>('stopService');
  Future<void> toggleService() => _channel.invokeMethod<void>('toggleService');
  Future<void> openBatterySettings() =>
      _channel.invokeMethod<void>('openBatterySettings');
  Future<String> dataPath() async =>
      await _channel.invokeMethod<String>('dataPath') ?? '';

  Future<Map<Permission, PermissionStatus>> requestPermissions() async {
    return <Permission, PermissionStatus>{
      Permission.sms: await Permission.sms.request(),
      Permission.contacts: await Permission.contacts.request(),
      Permission.phone: await Permission.phone.request(),
      Permission.notification: await Permission.notification.request(),
    };
  }

  Future<PickedContact?> pickContact() async {
    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      throw Exception('يلزم السماح بالوصول إلى جهات الاتصال لاختيار رقم.');
    }
    final contact = await FlutterContacts.openExternalPick();
    if (contact == null) return null;
    if (contact.phones.isEmpty) {
      throw Exception('جهة الاتصال المختارة لا تحتوي على رقم هاتف.');
    }
    return PickedContact(
      name: contact.displayName.trim(),
      phone: contact.phones.first.number.trim(),
    );
  }
}
