import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/account_resolver.dart';
import '../data/financial_record_repository.dart';
import '../data/tenant_repository.dart';
import 'design_system.dart';
import 'receipt_screen.dart';

class TenantLedgerScreen extends StatefulWidget {
  const TenantLedgerScreen({super.key, required this.account, this.tenantId});
  final AccountContext account;
  final String? tenantId;
  @override State<TenantLedgerScreen> createState() => _TenantLedgerScreenState();
}
class _LedgerData {
  const _LedgerData(this.entries, this.receipts);
  final List<RentLedgerEntryRecord> entries;
  final List<RentReceiptRecord> receipts;
}
class _TenantLedgerScreenState extends State<TenantLedgerScreen> {
  String? selectedTenantId;
  Future<_LedgerData>? data;
  late final FinancialRecordRepository repository = FinancialRecordRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  @override void initState() { super.initState(); selectedTenantId = widget.tenantId; if (selectedTenantId != null) data = _load(selectedTenantId!); }
  Future<_LedgerData> _load(String id) async { final entries = await repository.listTenantLedger(widget.account.workspaceId, id); final receipts = await repository.listReceiptsForTenant(widget.account.workspaceId, id); return _LedgerData(entries, receipts); }
  void _select(String? id) => setState(() { selectedTenantId = id; data = id == null ? null : _load(id); });
  void _retry() { final id = selectedTenantId; if (id != null) setState(() => data = _load(id)); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Tenant Ledger')), body: StreamBuilder<List<TenantRecord>>(stream: TenantRepository(FirebaseFirestore.instance).watchTenants(widget.account.workspaceId), builder: (context, tenants) {
    if (tenants.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const EmptyState(title: 'Tenants unavailable', body: 'Please check your connection and try again.'), TextButton(onPressed: () => setState(() {}), child: const Text('Retry'))])));
    if (!tenants.hasData) return const Padding(padding: EdgeInsets.all(20), child: Skeleton(height: 100));
    final options = tenants.data!;
    final selected = options.where((item) => item.id == selectedTenantId).firstOrNull;
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Recorded transactions', style: TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 4), Text(selected?.data['fullName'] as String? ?? 'Select a tenant', style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
      const SizedBox(height: 7), const Text('Rent payments only · read-only history', style: TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 20),
      DropdownButtonFormField<String>(value: selected == null ? null : selectedTenantId, decoration: const InputDecoration(labelText: 'Tenant'), hint: const Text('Choose tenant'), items: options.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['fullName'] as String? ?? 'Tenant'))).toList(), onChanged: _select),
      const SizedBox(height: 22),
      if (selectedTenantId == null) const EmptyState(title: 'Choose a tenant', body: 'Select a tenant to see recorded rent transactions.')
      else FutureBuilder<_LedgerData>(future: data, builder: (context, snapshot) {
        if (snapshot.hasError) return Column(children: [const EmptyState(title: 'Ledger unavailable', body: 'Please check your connection and try again.'), TextButton(onPressed: _retry, child: const Text('Retry'))]);
        if (!snapshot.hasData) return const Column(children: [Skeleton(height: 92), SizedBox(height: 12), Skeleton(height: 92), SizedBox(height: 20), Skeleton(height: 110)]);
        final records = snapshot.data!;
        final receipts = {for (final item in records.receipts) item.paymentId: item};
        final total = records.entries.fold<int>(0, (sum, item) => sum + item.amountPaise);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Total Rent Payments Recorded', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)), const SizedBox(height: 10), Text(formatInr(total), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))]))), const SizedBox(width: 10), Expanded(child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Transactions', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)), const SizedBox(height: 10), Text(records.entries.length.toString(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))])))]),
          const SizedBox(height: 13), const Text('Totals include recorded ledger payments only. Outstanding rent is tracked in Rent Collection.', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)),
          const SizedBox(height: 25), const Text('Transaction History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 12),
          if (records.entries.isEmpty) const EmptyState(title: 'No rent transactions recorded yet.', body: 'Rent payments will appear here once recorded.')
          else ...records.entries.reversed.map((entry) { final receipt = receipts[entry.paymentId]; return Padding(padding: const EdgeInsets.only(bottom: 11), child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(receiptDate(entry.transactionDate), style: const TextStyle(color: CreovyColors.secondary)), Text(formatInr(entry.amountPaise), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: CreovyColors.ink))]),
            const SizedBox(height: 8), Text(receipt == null ? entry.description : '${receipt.propertyName} · ${receipt.unitName}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3), Text('Rent period ${receiptPeriod(entry.periodKey)} · ${receiptMode(entry.paymentMode)}', style: const TextStyle(color: CreovyColors.secondary)),
            const SizedBox(height: 3), Text(entry.description, style: const TextStyle(color: CreovyColors.secondary)),
            if (receipt != null) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiptScreen(workspaceId: widget.account.workspaceId, paymentId: entry.paymentId))), child: Text('View Receipt · ${receipt.receiptNumber}'))),
          ])));
          }),
        ]);
      }),
    ]);
  }));
}
