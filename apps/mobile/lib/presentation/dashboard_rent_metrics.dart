import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../data/rent_due_repository.dart';
import '../data/tenant_repository.dart';
import 'design_system.dart';

class DashboardRentMetrics extends StatefulWidget {
  const DashboardRentMetrics({super.key, required this.workspaceId});
  final String workspaceId;
  @override State<DashboardRentMetrics> createState() => _DashboardRentMetricsState();
}

class _DashboardRentMetricsState extends State<DashboardRentMetrics> {
  final attempted = <String>{};
  bool prepared = false;
  StreamSubscription<List<AgreementRecord>>? _agreements;
  @override void initState() {
    super.initState();
    String? lastSignature;
    _agreements = TenantRepository(FirebaseFirestore.instance).watchAgreements(widget.workspaceId).listen((agreements) {
      final parts = agreements.map((item) => '${item.id}:${item.data['status']}:${item.data['startDate']}:${item.data['endDate']}').toList()..sort();
      final signature = parts.join('|');
      if (signature == lastSignature) return;
      lastSignature = signature;
      if (mounted) setState(() => prepared = false);
      unawaited(RentDueRepository(FirebaseFirestore.instance).ensureDues(widget.workspaceId, agreements).then((_) { if (mounted) setState(() => prepared = true); }));
    });
  }
  @override void dispose() { _agreements?.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final repository = RentDueRepository(FirebaseFirestore.instance);
    return StreamBuilder<List<RentDueRecord>>(
      stream: repository.watchDues(widget.workspaceId),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final stale = snapshot.data!.where((due) => due.data['status'] == 'pending' && repository.isOverdue(due) && !attempted.contains(due.id)).toList();
          if (stale.isNotEmpty) {
            attempted.addAll(stale.map((due) => due.id));
            unawaited(repository.refreshOverdue(stale));
          }
        }
        final dues = prepared ? snapshot.data : null;
        final today = repository.businessToday();
        final month = repository.periodKey(today.year, today.month);
        final current = dues?.where((due) => due.data['periodKey'] == month).toList();
        int total(Iterable<RentDueRecord>? items, String field) => items?.fold<int>(0, (sum, due) => sum + ((due.data[field] as num?)?.toInt() ?? 0)) ?? 0;
        final expected = dues == null ? null : total(current, 'rentAmountPaise');
        final collected = dues == null ? null : total(current, 'totalPaidPaise');
        final outstanding = dues == null ? null : total(current, 'balancePaise');
        final overdue = dues == null ? null : total(dues.where(repository.isOverdue), 'balancePaise');
        return GridView.count(
          crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.32,
          children: [
            _RentMetric('Expected Rent', expected, const Color(0xFF8B73F0)),
            _RentMetric('Collected Rent', collected, CreovyColors.success),
            _RentMetric('Current Outstanding', outstanding, CreovyColors.warning),
            _RentMetric('Overdue · all periods', overdue, CreovyColors.danger),
          ],
        );
      },
    );
  }
}

class _RentMetric extends StatelessWidget {
  const _RentMetric(this.label, this.amount, this.color, {this.unavailable = false});
  final String label; final int? amount; final Color color; final bool unavailable;
  @override Widget build(BuildContext context) => SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 12, color: CreovyColors.secondary)), const SizedBox(height: 10), unavailable ? const Text('Coming next', style: TextStyle(fontSize: 13, color: CreovyColors.secondary)) : amount == null ? const Skeleton(width: 72, height: 21) : Text(formatInr(amount), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: CreovyColors.ink)), const Spacer(), Container(width: 28, height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)))]));
}
