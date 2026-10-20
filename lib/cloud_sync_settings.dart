import 'package:flutter/material.dart';
import 'cloud_sync.dart';
import 'users_page.dart';

class CloudSyncSettingsPage extends StatefulWidget {
  const CloudSyncSettingsPage({super.key});
  @override
  State<CloudSyncSettingsPage> createState() => _CloudSyncSettingsPageState();
}

class _CloudSyncSettingsPageState extends State<CloudSyncSettingsPage> {
  final endpoint = TextEditingController(text: 'http://10.0.2.2:8080');
  final email = TextEditingController();
  final password = TextEditingController();
  CloudSyncClient? client;
  String status = 'غير متصل';
  bool busy = false;
  Map<String, dynamic>? session;

  @override
  void dispose() { endpoint.dispose(); email.dispose(); password.dispose(); client?.dispose(); super.dispose(); }

  Future<void> connect() async {
    setState(() { busy = true; status = 'جارٍ الاتصال…'; });
    try {
      client?.dispose();
      client = CloudSyncClient(endpoint.text.trim());
      await client!.login(email.text.trim(), password.text);
      session = await client!.me();
      if (mounted) setState(() => status = 'متصل بالخادم');
    } catch (e) {
      if (mounted) setState(() => status = 'تعذر الاتصال: ${e.toString().replaceFirst('Bad state: ', '')}');
    } finally { if (mounted) setState(() => busy = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('المزامنة السحابية')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      Card(child: ListTile(leading: Icon(status == 'متصل بالخادم' ? Icons.cloud_done : Icons.cloud_off, color: status == 'متصل بالخادم' ? Colors.green : Colors.orange), title: Text(status), subtitle: const Text('المزامنة اختيارية والتطبيق يعمل محلياً عند انقطاع الإنترنت.'))),
      const SizedBox(height: 12),
      TextField(controller: endpoint, decoration: const InputDecoration(labelText: 'رابط API', hintText: 'https://api.example.com')),
      const SizedBox(height: 10),
      TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'البريد الإلكتروني')),
      const SizedBox(height: 10),
      TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور')),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: busy ? null : connect, icon: const Icon(Icons.login), label: Text(busy ? 'جارٍ الاتصال…' : 'تسجيل الدخول والمزامنة')),
      if (session != null && ((session!['permissions'] as List?)?.contains('users') ?? false)) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () {
            final branches = (session!['branches'] as List? ?? []);
            if (branches.isEmpty) return;
            Navigator.push(context, MaterialPageRoute(builder: (_) => UsersPage(client: client!, branchId: '${(branches.first as Map)['id']}')));
          },
          icon: const Icon(Icons.manage_accounts_outlined),
          label: const Text('إدارة المستخدمين والأدوار'),
        ),
      ],
      const SizedBox(height: 16),
      const Card(child: Padding(padding: EdgeInsets.all(14), child: Text('للتطوير المحلي: شغّل الخادم على جهاز الكمبيوتر، واستخدم 10.0.2.2 من محاكي Android أو عنوان الشبكة المحلي من هاتف حقيقي. لا تضع JWT_SECRET داخل التطبيق.'))),
    ]),
  );
}
