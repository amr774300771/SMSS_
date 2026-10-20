import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class SyncChange {
  final String id;
  final String entity;
  final String entityId;
  final String operation;
  final String branchId;
  final String deviceId;
  final Map<String, dynamic> payload;

  SyncChange({String? id, required this.entity, required this.entityId, required this.operation, required this.branchId, required this.deviceId, required this.payload}) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {'id': id, 'entity': entity, 'entityId': entityId, 'operation': operation, 'branchId': branchId, 'deviceId': deviceId, 'payload': payload};
}

class CloudSyncClient {
  final Uri baseUri;
  final http.Client client;
  String? token;
  String? cursor;
  CloudSyncClient(String url, {http.Client? client}) : baseUri = Uri.parse(url), client = client ?? http.Client();

  Map<String, String> get _headers => {'content-type': 'application/json', if (token != null) 'authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await client.post(baseUri.resolve('/v1/auth/login'), headers: _headers, body: jsonEncode({'email': email, 'password': password}));
    _check(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    token = '${data['token']}';
    return data;
  }

  Future<Map<String, dynamic>> register({required String organizationName, required String email, required String password, String branchName = 'الفرع الرئيسي', String displayName = 'المالك'}) async {
    final response = await client.post(baseUri.resolve('/v1/auth/register'), headers: _headers, body: jsonEncode({'organizationName': organizationName, 'branchName': branchName, 'email': email, 'password': password, 'displayName': displayName}));
    _check(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    token = '${data['token']}';
    return data;
  }

  Future<Map<String, dynamic>> push(List<SyncChange> changes) async {
    _requireToken();
    final response = await client.post(baseUri.resolve('/v1/sync/push'), headers: _headers, body: jsonEncode({'changes': changes.map((e) => e.toJson()).toList()}));
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> pull({String? after}) async {
    _requireToken();
    final query = <String, String>{if (after != null || cursor != null) 'after': after ?? cursor!};
    final response = await client.get(baseUri.resolve('/v1/sync/pull').replace(queryParameters: query), headers: _headers);
    _check(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    cursor = '${data['cursor']}';
    return data;
  }

  Future<Map<String, dynamic>> me() async {
    _requireToken();
    final response = await client.get(baseUri.resolve('/v1/me'), headers: _headers);
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sell({required String branchId, required String cardId, String? clientId, String paymentMethod = 'credit', String? idempotencyKey}) async {
    _requireToken();
    final response = await client.post(baseUri.resolve('/v1/sales'), headers: _headers, body: jsonEncode({'branchId': branchId, 'cardId': cardId, 'clientId': clientId, 'paymentMethod': paymentMethod, 'idempotencyKey': idempotencyKey ?? const Uuid().v4()}));
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> manualSale({required String branchId, String? clientId, required String description, required int quantity, required int unitPrice, int unitCost = 0, String paymentMethod = 'cash', String? idempotencyKey}) async {
    _requireToken();
    final response = await client.post(baseUri.resolve('/v1/manual-sales'), headers: _headers, body: jsonEncode({'branchId': branchId, 'clientId': clientId, 'description': description, 'quantity': quantity, 'unitPrice': unitPrice, 'unitCost': unitCost, 'paymentMethod': paymentMethod, 'idempotencyKey': idempotencyKey ?? const Uuid().v4()}));
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> listUsers() async {
    _requireToken();
    final response = await client.get(baseUri.resolve('/v1/users'), headers: _headers);
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createUser({required String email, required String password, required String displayName, required String role, required String branchId}) async {
    _requireToken();
    final response = await client.post(baseUri.resolve('/v1/users'), headers: _headers, body: jsonEncode({'email': email, 'password': password, 'displayName': displayName, 'role': role, 'branchId': branchId}));
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> disableUser(String userId) async {
    _requireToken();
    final response = await client.post(baseUri.resolve('/v1/users/$userId/disable'), headers: _headers);
    _check(response);
  }

  Future<Map<String, dynamic>> listDevices() async {
    _requireToken();
    final response = await client.get(baseUri.resolve('/v1/devices'), headers: _headers);
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> revokeDevice(String deviceId) async {
    _requireToken();
    final response = await client.post(baseUri.resolve('/v1/devices/$deviceId/revoke'), headers: _headers);
    _check(response);
  }

  Future<Map<String, dynamic>> reportSummary({String? branchId}) async {
    _requireToken();
    final uri = baseUri.resolve('/v1/reports/summary').replace(queryParameters: {if (branchId != null) 'branchId': branchId});
    final response = await client.get(uri, headers: _headers);
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> listConflicts() async {
    _requireToken();
    final response = await client.get(baseUri.resolve('/v1/conflicts'), headers: _headers);
    _check(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void _requireToken() { if (token == null) throw StateError('سجّل الدخول إلى الخادم أولاً'); }
  void _check(http.Response response) { if (response.statusCode < 200 || response.statusCode >= 300) throw StateError('Cloud API ${response.statusCode}: ${response.body}'); }
  void dispose() => client.close();
}
