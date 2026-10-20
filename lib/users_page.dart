import 'package:flutter/material.dart';
import 'cloud_sync.dart';

class UsersPage extends StatefulWidget {
  final CloudSyncClient client;
  final String branchId;
  const UsersPage({super.key, required this.client, required this.branchId});
  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<Map<String, dynamic>> users = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await widget.client.listUsers();
      final raw = data['users'] as List? ?? [];
      if (mounted) {
        setState(() => users = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تحميل المستخدمين: $error')));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> addUser() async {
    final email = TextEditingController();
    final name = TextEditingController();
    final password = TextEditingController();
    var role = 'seller';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('إضافة مستخدم'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
              TextField(controller: email, decoration: const InputDecoration(labelText: 'البريد الإلكتروني')),
              TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور (8 أحرف على الأقل)')),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'الدور'),
                items: const [
                  DropdownMenuItem(value: 'manager', child: Text('مدير')),
                  DropdownMenuItem(value: 'supervisor', child: Text('مشرف')),
                  DropdownMenuItem(value: 'seller', child: Text('بائع')),
                  DropdownMenuItem(value: 'collector', child: Text('محصل')),
                  DropdownMenuItem(value: 'viewer', child: Text('مراقب')),
                ],
                onChanged: (value) => setLocal(() => role = value ?? 'seller'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                try {
                  await widget.client.createUser(email: email.text.trim(), password: password.text, displayName: name.text.trim(), role: role, branchId: widget.branchId);
                  if (context.mounted) Navigator.pop(context, true);
                } catch (error) {
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر إنشاء المستخدم: $error')));
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    email.dispose();
    name.dispose();
    password.dispose();
    if (ok == true) load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('المستخدمون والأدوار'), actions: [IconButton(onPressed: addUser, icon: const Icon(Icons.person_add_alt_1))]),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : users.isEmpty
                ? const Center(child: Text('لا يوجد مستخدمون'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: users.length,
                    itemBuilder: (_, index) {
                      final user = users[index];
                      final disabled = user['disabled_at'] != null;
                      final displayName = '${user['display_name'] ?? '?'}';
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(child: Text(displayName.characters.first)),
                          title: Text(displayName),
                          subtitle: Text('${user['email']} • ${user['role']}'),
                          trailing: disabled
                              ? const Chip(label: Text('متوقف'))
                              : IconButton(
                                  icon: const Icon(Icons.block_outlined),
                                  tooltip: 'تعطيل المستخدم',
                                  onPressed: () async {
                                    await widget.client.disableUser('${user['id']}');
                                    load();
                                  },
                                ),
                        ),
                      );
                    },
                  ),
      );
}
