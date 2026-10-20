import 'package:flutter/material.dart';

/// هياكل تحميل محلية بسيطة بدل شاشة فارغة أو مؤشر دوّار عند جلب البيانات.
class AppSkeleton extends StatelessWidget {
  final bool dashboard;
  final int rows;

  const AppSkeleton({super.key, this.dashboard = false, this.rows = 5});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget block(double height, {double? width, double radius = 12}) =>
        Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .62),
            borderRadius: BorderRadius.circular(radius),
          ),
        );

    return Semantics(
      label: 'جار تحميل البيانات',
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
        children: [
          Align(
              alignment: AlignmentDirectional.centerStart,
              child: block(28, width: 190, radius: 9)),
          const SizedBox(height: 18),
          if (dashboard) ...[
            block(132, radius: 24),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: block(112)),
              const SizedBox(width: 10),
              Expanded(child: block(112)),
            ]),
            const SizedBox(height: 18),
          ],
          for (var index = 0; index < rows; index++) ...[
            block(index == 0 && !dashboard ? 74 : 58),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
