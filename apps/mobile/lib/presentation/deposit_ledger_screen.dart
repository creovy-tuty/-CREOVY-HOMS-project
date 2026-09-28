import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/account_resolver.dart';
import '../data/security_deposit_financial_repository.dart';
import '../data/tenant_repository.dart';
import 'deposit_receipt_screen.dart';
import 'design_system.dart';

String _ledgerDate(Timestamp value) { final local = value.toDate().toUtc().add(const Duration(hours: 5, minutes: 30)); return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}'; }
String _ledgerMode(String value) => switch (value) { 'upi' => 'UPI', 'bank_transfer' => 'Bank transfer', 'cash' => 'Cash', 'cheque' => 'Cheque', _ => 'Other' };

class DepositLedgerScreen extends StatefulWidget {
  const DepositLedgerScreen({super.key, required this.account, required this.agreement});
  final AccountContext account;
  final AgreementRecord agreement;
  @override State<DepositLedgerScreen> createState() => _DepositLedgerScreenState();
}
class _DepositLedgerScreenState extends State<DepositLedgerScreen> {
  late final repository = SecurityDepositFinancialRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late Stream<List<DepositLedgerRecord>> ledger = repository.watchDepositLedger(widget.account.workspaceId, widget.agreement.id);
  void _retry() => setState(() => ledger = repository.watchDepositLedger(widget.account.workspaceId, widget.agreement.id));
  late final Future<List<String>> names = _loadNames();
  Future<List<String>> _loadNames() async {
    final source = widget.agreement.data;
    final firestore = FirebaseFirestore.instance;
    final docs = await Future.wait([
      firestore.collection('tenants').doc(source['tenantId'] as String).get(),
      firestore.collection('properties').doc(source['propertyId'] as String).get(),
      firestore.collection('units').doc(source['unitId'] as String).get(),
    ]);
    return [docs[0].data()?['fullName'] as String? ?? 'Tenant', docs[1].data()?['name'] as String? ?? 'Property', docs[2].data()?['name'] as String? ?? 'Unit'];
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Deposit Ledger')), body: FutureBuilder<List<String>>(future: names, builder: (context, nameResult) => StreamBuilder<List<DepositLedgerRecord>>(stream: ledger, builder: (context, snapshot) {
    if (snapshot.hasError) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const EmptyState(title: 'Deposit ledger unavailable', body: 'Check your connection and retry.'), TextButton(onPressed: _retry, child: const Text('Retry'))]));
    if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(20), child: Column(children: [Skeleton(height: 90), SizedBox(height: 12), Skeleton(height: 90)]));
    if (snapshot.data!.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(20), child: EmptyState(title: 'No deposit ledger entries', body: 'New deposit movements create immutable ledger entries. Earlier development transactions are not automatically backfilled.')));
    return ListView(padding: const EdgeInsets.all(20), children: [const Text('Immutable financial history', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 6), const Text('Deposit movements are separate from rent income.', style: TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 18), ...snapshot.data!.map((entry) { final data = entry.data; final received = data['entryType'] == 'deposit_received'; return Padding(padding: const EdgeInsets.only(bottom: 10), child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [StatusChip(label: received ? 'Received' : 'Refunded'), const Spacer(), Text(formatInr(data['amountPaise'] as int), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))]), const SizedBox(height: 9), Text('${_ledgerDate(data['transactionDate'] as Timestamp)} · ${_ledgerMode(data['paymentMode'] as String)}', style: const TextStyle(color: CreovyColors.secondary)), Text(nameResult.data?[0] ?? 'Tenant', style: const TextStyle(fontWeight: FontWeight.w600)), Text('${nameResult.data?[1] ?? 'Property'} · ${nameResult.data?[2] ?? 'Unit'}', style: const TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 8), TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DepositReceiptScreen(workspaceId: widget.account.workspaceId, transactionId: data['depositReceiptId'] as String))), icon: const Icon(Icons.receipt_long_outlined), label: const Text('View Receipt'))]))); })]);
  })));
}
