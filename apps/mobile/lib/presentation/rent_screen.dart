import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/account_resolver.dart';
import '../data/rent_due_repository.dart';
import '../data/rent_payment_repository.dart';
import '../data/tenant_repository.dart';
import '../data/property_repository.dart';
import 'collect_rent_sheet.dart';
import 'design_system.dart';
import 'receipt_screen.dart';

class RentScreen extends StatefulWidget {
  const RentScreen({super.key, required this.account});
  final AccountContext account;
  @override State<RentScreen> createState() => _RentScreenState();
}

class _RentScreenState extends State<RentScreen> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 4, vsync: this);
  late final RentDueRepository repository = RentDueRepository(FirebaseFirestore.instance);
  late final Stream<List<RentDueRecord>> dueStream = repository.watchDues(widget.account.workspaceId);
  late final Stream<List<AgreementRecord>> agreementStream = TenantRepository(FirebaseFirestore.instance).watchAgreements(widget.account.workspaceId);
  late final Stream<List<TenantRecord>> tenantStream = TenantRepository(FirebaseFirestore.instance).watchTenants(widget.account.workspaceId);
  late final Stream<List<PropertyRecord>> propertyStream = PropertyRepository(FirebaseFirestore.instance).watchProperties(widget.account.workspaceId);
  late final Stream<List<UnitRecord>> unitStream = PropertyRepository(FirebaseFirestore.instance).watchAllUnits(widget.account.workspaceId);
  String generatedSignature = '';
  final refreshed = <String>{};
  bool get canCollect => const ['owner', 'manager', 'accountant'].contains(widget.account.role);
  @override void dispose() { tabs.dispose(); super.dispose(); }

  void _openCollect(RentDueRecord due, String tenant, String property, String unit) {
    if (!canCollect || (due.data['balancePaise'] as num? ?? 0) <= 0) return;
    showModalBottomSheet<void>(context: context, isScrollControlled: true, isDismissible: false, enableDrag: false, backgroundColor: CreovyColors.surface,
      builder: (_) => CollectRentSheet(due: due, tenantName: tenant, propertyName: property, unitName: unit));
  }

  @override Widget build(BuildContext context) => StreamBuilder<List<AgreementRecord>>(
    stream: agreementStream,
    builder: (context, agreements) {
      if (agreements.hasData) {
        final parts = agreements.data!.map((item) => '${item.id}:${item.data['status']}:${item.data['startDate']}:${item.data['endDate']}').toList()..sort();
        final signature = parts.join('|');
        if (signature != generatedSignature) {
          generatedSignature = signature;
          unawaited(repository.ensureDues(widget.account.workspaceId, agreements.data!).catchError((Object error) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Some rent dues could not be prepared.')));
          }));
        }
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Rent Collection'), bottom: TabBar(controller: tabs, tabs: const [Tab(text: 'Current'), Tab(text: 'Pending'), Tab(text: 'Overdue'), Tab(text: 'History')])),
        body: StreamBuilder<List<RentDueRecord>>(stream: dueStream, builder: (context, dues) {
          if (dues.hasError) return const Center(child: EmptyState(title: 'Rent dues unavailable', body: 'Please check your connection and try again.'));
          if (!dues.hasData) return const Padding(padding: EdgeInsets.all(20), child: Skeleton(height: 80));
          final list = dues.data!;
          final stale = list.where((due) => due.data['status'] == 'pending' && repository.isOverdue(due) && !refreshed.contains(due.id)).toList();
          if (stale.isNotEmpty) {
            refreshed.addAll(stale.map((due) => due.id));
            unawaited(repository.refreshOverdue(stale).catchError((Object error) {
              refreshed.removeAll(stale.map((due) => due.id));
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Overdue status could not be refreshed.')));
            }));
          }
          return StreamBuilder<List<TenantRecord>>(stream: tenantStream, builder: (context, tenants) =>
            StreamBuilder<List<PropertyRecord>>(stream: propertyStream, builder: (context, properties) =>
              StreamBuilder<List<UnitRecord>>(stream: unitStream, builder: (context, units) {
                if (tenants.hasError || properties.hasError || units.hasError) return const Center(child: EmptyState(title: 'Rent context unavailable', body: 'Tenant and property details could not be loaded. Please check your connection.'));
                if (!tenants.hasData || !properties.hasData || !units.hasData) return const Padding(padding: EdgeInsets.all(20), child: Skeleton(height: 80));
                final tenantNames = {for (final item in tenants.data!) item.id: item.data['fullName'] as String? ?? 'Tenant'};
                final propertyNames = {for (final item in properties.data!) item.id: item.data['name'] as String? ?? 'Property'};
                final unitNames = {for (final item in units.data!) item.id: item.data['name'] as String? ?? 'Unit'};
                final today = repository.businessToday();
                final month = repository.periodKey(today.year, today.month);
                Widget items(Iterable<RentDueRecord> selected) => _list(selected.toList(), tenantNames, propertyNames, unitNames);
                return TabBarView(controller: tabs, children: [
                  items(list.where((due) => due.data['periodKey'] == month)),
                  items(list.where((due) => (due.data['balancePaise'] as num? ?? 0) > 0 && !repository.isOverdue(due))),
                  items(list.where(repository.isOverdue)),
                  items(list.where((due) => due.data['status'] == 'paid')),
                ]);
              })));
        }),
      );
    },
  );

  Widget _list(List<RentDueRecord> dues, Map<String, String> tenants, Map<String, String> properties, Map<String, String> units) {
    if (dues.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: EmptyState(title: 'No rent dues for this view', body: 'Eligible agreement dues will appear here automatically.')));
    dues.sort((a, b) => (a.data['periodKey'] as String).compareTo(b.data['periodKey'] as String));
    return ListView(padding: const EdgeInsets.all(20), children: dues.map((due) {
      final tenant = tenants[due.data['tenantId']] ?? 'Tenant';
      final property = properties[due.data['propertyId']] ?? 'Property';
      final unit = units[due.data['unitId']] ?? 'Unit';
      final balance = (due.data['balancePaise'] as num? ?? 0).toInt();
      return Padding(padding: const EdgeInsets.only(bottom: 12), child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RentDueDetail(due: due, tenantName: tenant, propertyName: property, unitName: unit, canCollect: canCollect))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(tenant, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))), StatusChip(label: _status(due.data['status'] as String? ?? 'pending'))]),
            const SizedBox(height: 6), Text('$property · $unit', style: const TextStyle(color: CreovyColors.secondary)),
            const SizedBox(height: 8), Text('${due.data['periodKey']} · Balance ${formatInr(balance)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (repository.isOverdue(due) && due.data['status'] == 'partial') const Padding(padding: EdgeInsets.only(top: 5), child: Text('Past due', style: TextStyle(color: CreovyColors.danger, fontSize: 12))),
          ])),
        if (canCollect && balance > 0) ...[const SizedBox(height: 14), SizedBox(width: double.infinity, child: CreovyButton(label: 'Collect Rent', icon: Icons.payments_outlined, onPressed: () => _openCollect(due, tenant, property, unit)))],
      ])));
    }).toList());
  }
}

class RentDueDetail extends StatefulWidget {
  const RentDueDetail({super.key, required this.due, required this.tenantName, required this.propertyName, required this.unitName, required this.canCollect});
  final RentDueRecord due;
  final String tenantName, propertyName, unitName;
  final bool canCollect;
  @override State<RentDueDetail> createState() => _RentDueDetailState();
}
class _RentDueDetailState extends State<RentDueDetail> {
  late final RentDueRepository repository = RentDueRepository(FirebaseFirestore.instance);
  late final Stream<RentDueRecord?> dueStream = repository.watchDue(widget.due.data['workspaceId'] as String, widget.due.id);
  @override Widget build(BuildContext context) => StreamBuilder<RentDueRecord?>(
    stream: dueStream,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const Scaffold(body: Center(child: EmptyState(title: 'Rent due unavailable', body: 'Please check your connection and reopen this due.')));
      final due = snapshot.data ?? widget.due;
      final balance = (due.data['balancePaise'] as num? ?? 0).toInt();
      return Scaffold(appBar: AppBar(title: const Text('Rent Due')), body: ListView(padding: const EdgeInsets.all(20), children: [
        Row(children: [StatusChip(label: _status(due.data['status'] as String? ?? 'pending')), if (repository.isOverdue(due) && due.data['status'] == 'partial') const Padding(padding: EdgeInsets.only(left: 10), child: Text('Past due', style: TextStyle(color: CreovyColors.danger)))]),
        const SizedBox(height: 18),
        SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.tenantName, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          Text('${widget.propertyName} · ${widget.unitName}', style: const TextStyle(color: CreovyColors.secondary)),
          const Divider(height: 28),
          _detailLine('Rent period', due.data['periodKey'] as String? ?? '—'),
          _detailLine('Rent amount', formatInr((due.data['rentAmountPaise'] as num?)?.toInt())),
          _detailLine('Due date', _date(due.data['dueDate'])),
          _detailLine('Already paid', formatInr((due.data['totalPaidPaise'] as num?)?.toInt())),
          _detailLine('Current balance', formatInr(balance)),
        ])),
        if (widget.canCollect && balance > 0) ...[const SizedBox(height: 18), CreovyButton(label: 'Collect Rent', icon: Icons.payments_outlined, onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, isDismissible: false, enableDrag: false, backgroundColor: CreovyColors.surface, builder: (_) => CollectRentSheet(due: due, tenantName: widget.tenantName, propertyName: widget.propertyName, unitName: widget.unitName)))],
        const SizedBox(height: 24), Text('Payment History', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 10),
        _PaymentHistory(workspaceId: due.data['workspaceId'] as String, dueId: due.id, totalPaidPaise: (due.data['totalPaidPaise'] as num? ?? 0).toInt()),
      ]));
    },
  );
}

class _PaymentHistory extends StatefulWidget {
  const _PaymentHistory({required this.workspaceId, required this.dueId, required this.totalPaidPaise});
  final String workspaceId, dueId;
  final int totalPaidPaise;
  @override State<_PaymentHistory> createState() => _PaymentHistoryState();
}
class _PaymentHistoryState extends State<_PaymentHistory> {
  late Future<List<RentPaymentRecord>> history = _load();
  Future<List<RentPaymentRecord>> _load() => RentPaymentRepository(FirebaseFirestore.instance, FirebaseAuth.instance).listPaymentsForDue(widget.workspaceId, widget.dueId);
  @override void didUpdateWidget(covariant _PaymentHistory oldWidget) { super.didUpdateWidget(oldWidget); if (oldWidget.totalPaidPaise != widget.totalPaidPaise || oldWidget.dueId != widget.dueId) history = _load(); }
  @override Widget build(BuildContext context) => FutureBuilder<List<RentPaymentRecord>>(future: history, builder: (context, snapshot) {
    if (snapshot.hasError) return const FeedbackAlert(message: 'Payment history could not be loaded. Reopen this due to retry.', tone: CreovyColors.danger);
    if (!snapshot.hasData) return const Skeleton(height: 80);
    if (snapshot.data!.isEmpty) return const EmptyState(title: 'No payments yet', body: 'Recorded payments will appear here in date order.');
    return Column(children: snapshot.data!.map((payment) {
      final data = payment.data;
      final reference = data['referenceNumber'] as String? ?? '';
      final notes = data['notes'] as String? ?? '';
      return Padding(padding: const EdgeInsets.only(bottom: 9), child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_date(data['paymentDate']), style: const TextStyle(color: CreovyColors.secondary)), Text(formatInr((data['amountPaise'] as num).toInt()), style: const TextStyle(fontWeight: FontWeight.w700))]),
        const SizedBox(height: 5), Text(_modeLabel(data['paymentMode'] as String? ?? 'other')),
        if (reference.isNotEmpty) Text('Reference $reference', style: const TextStyle(color: CreovyColors.secondary)),
        if (notes.isNotEmpty) Text(notes, style: const TextStyle(color: CreovyColors.secondary)),
        Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiptScreen(workspaceId: widget.workspaceId, paymentId: payment.id))), child: const Text('View Receipt'))),
      ])));
    }).toList());
  });
}
Widget _detailLine(String label, String value) => Padding(padding: const EdgeInsets.only(bottom: 11), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: const TextStyle(color: CreovyColors.secondary)), Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)))]));
String _modeLabel(String value) => switch (value) { 'cash' => 'Cash', 'upi' => 'UPI', 'bank_transfer' => 'Bank Transfer', 'cheque' => 'Cheque', _ => 'Other' };
String _status(String value) => value.isEmpty ? 'Pending' : value[0].toUpperCase() + value.substring(1);
String _date(dynamic value) { if (value is! Timestamp) return '—'; final india = value.toDate().toUtc().add(const Duration(hours: 5, minutes: 30)); return '${india.day.toString().padLeft(2, '0')}/${india.month.toString().padLeft(2, '0')}/${india.year}'; }
