import 'dart:convert';
import 'dart:io';

import 'package:cardbot_qaidi/package_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default seed is valid JSON and all shipped package IDs equal prices',
      () {
    final defaults = jsonDecode(File('assets/defaults.json').readAsStringSync())
        as Map<String, dynamic>;
    final packageConfig =
        jsonDecode(defaults['packages.json'] as String) as Map<String, dynamic>;
    final packages =
        (packageConfig['packages'] as List).cast<Map<String, dynamic>>();

    expect(
      packages.map((item) => item['id']).toSet(),
      {'200', '300', '500', '3000'},
    );
    for (final package in packages) {
      expect(package['id'], '${package['price']}');
    }
    expect(PackageRules.validatePackages(packages), isNull);

    final permissions = jsonDecode(defaults['permissions.json'] as String)
        as Map<String, dynamic>;
    expect(
      (permissions['global'] as Map<String, dynamic>)['allowedPackages'],
      containsAll({'200', '300', '500', '3000'}),
    );
  });
}
