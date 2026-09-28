import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/account_resolver.dart';
import '../data/security_deposit_repository.dart';
import '../data/tenant_repository.dart';
import 'design_system.dart';
import 'deposit_ledger_screen.dart';
import 'deposit_receipt_screen.dart';

String _depositAmountText(int paise) => '${paise ~/ 100}.${(paise % 100).toString().padLeft(2, '0')}';
int? _depositPaise(String text) {
  final clean = text.trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(clean)) return null;
  final parts = clean.split('.');
  final whole = int.tryParse(parts.first);
  if (whole == null || whole > 90071992547409) return null;
  final amount = whole * 100 + (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
  return amount <= 9007199254740991 ? amount : null;
}
DateTime _kolkataToday() { final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)); return DateTime.utc(now.year, now.month, now.day); }
DateTime _kolkataInstant(DateTime date) => DateTime.utc(date.year, date.month, date.day).subtract(const Duration(hours: 5, minutes: 30));
String _depositDate(DateTime date) { final local = date.toUtc().add(const Duration(hours: 5, minutes: 30)); return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}'; }
bool _sameDeposit(Map<String, dynamic> a, Map<String, dynamic> b) =>
    a['agreedAmountPaise'] == b['agreedAmountPaise'] && a['totalReceivedPaise'] == b['totalReceivedPaise'] &&
    a['pendingToReceivePaise'] == b['pendingToReceivePaise'] && a['totalRefundedPaise'] == b['totalRefundedPaise'] &&
    a['heldBalancePaise'] == b['heldBalancePaise'] && a['lastTransactionId'] == b['lastTransactionId'];

class DepositSummaryCard extends StatefulWidget {
  const DepositSummaryCard({super.key, required this.account, required this.agreement, this.onOpen});
  final AccountContext account;
  final AgreementRecord agreement;
  final VoidCallback? onOpen;
  @override State<DepositSummaryCard> createState() => _DepositSummaryCardState();
}
class _DepositSummaryCardState extends State<DepositSummaryCard> {
  late final SecurityDepositRepository repository = SecurityDepositRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late final Stream<DepositSummaryRecord> summaryStream = repository.watchDepositSummary(widget.account.workspaceId, widget.agreement.id);
  @override Widget build(BuildContext context) => StreamBuilder<DepositSummaryRecord>(stream: summaryStream, builder: (context, snapshot) {
    if (snapshot.hasError) return SurfaceCard(child: Column(children: [const FeedbackAlert(message: 'Deposit balance is unavailable. Reopen this agreement to retry.', tone: CreovyColors.danger), const SizedBox(height: 8), TextButton(onPressed: widget.onOpen, child: const Text('Open deposit details'))]));
    if (!snapshot.hasData) return const SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Skeleton(width: 150), SizedBox(height: 12), Skeleton(height: 42)]));
    final data = snapshot.data!.data;
    return SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Security Deposit', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: CreovyColors.ink)), const SizedBox(height: 5), const Text('Held separately from rent', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)), const SizedBox(height: 15), Wrap(spacing: 16, runSpacing: 12, children: [
      _DepositMetric('Agreed', data['agreedAmountPaise'] as int), _DepositMetric('Received', data['totalReceivedPaise'] as int), _DepositMetric('Pending', data['pendingToReceivePaise'] as int), _DepositMetric('Refunded', data['totalRefundedPaise'] as int), _DepositMetric('Currently Held', data['heldBalancePaise'] as int),
    ]), if (widget.agreement.data['status'] == 'ended' && (data['heldBalancePaise'] as int) > 0) Padding(padding: const EdgeInsets.only(top: 14), child: FeedbackAlert(message: 'Deposit still held: ${formatInr(data['heldBalancePaise'] as int)}')), if (widget.onOpen != null) Padding(padding: const EdgeInsets.only(top: 16), child: SizedBox(width: double.infinity, child: CreovyButton(label: 'Manage Deposit & View History', icon: Icons.account_balance_wallet_outlined, onPressed: widget.onOpen)))]));
  });
}
class _DepositMetric extends StatelessWidget { const _DepositMetric(this.label, this.value); final String label; final int value; @override Widget build(BuildContext context) => SizedBox(width: 114, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 12, color: CreovyColors.secondary)), const SizedBox(height: 3), Text(formatInr(value), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: CreovyColors.ink))])); }

class SecurityDepositScreen extends StatefulWidget {
  const SecurityDepositScreen({super.key, required this.account, required this.agreement});
  final AccountContext account;
  final AgreementRecord agreement;
  @override State<SecurityDepositScreen> createState() => _SecurityDepositScreenState();
}
class _SecurityDepositScreenState extends State<SecurityDepositScreen> {
  late final SecurityDepositRepository repository = SecurityDepositRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late Stream<DepositSummaryRecord> summaryStream;
  late Stream<List<DepositTransactionRecord>> historyStream;
  @override void initState() { super.initState(); _connect(); }
  void _connect() { summaryStream = repository.watchDepositSummary(widget.account.workspaceId, widget.agreement.id); historyStream = repository.watchDepositTransactions(widget.account.workspaceId, widget.agreement.id); }
  void _retry() => setState(_connect);
  bool get canWrite => const ['owner', 'manager', 'accountant'].contains(widget.account.role);
  void _open(DepositTransactionType type, DepositSummaryRecord summary) {
    if (!canWrite) return;
    showModalBottomSheet<void>(context: context, isScrollControlled: true, isDismissible: false, enableDrag: false,
      backgroundColor: CreovyColors.surface, builder: (_) => _DepositMovementSheet(account: widget.account, agreement: widget.agreement, initial: summary, type: type));
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Security Deposit'), actions: [TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DepositLedgerScreen(account: widget.account, agreement: widget.agreement))), child: const Text('Ledger'))]), body: StreamBuilder<DepositSummaryRecord>(stream: summaryStream, builder: (context, summary) {
    if (summary.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const EmptyState(title: 'Deposit unavailable', body: 'Check your connection and retry.'), const SizedBox(height: 12), CreovyButton(label: 'Retry', onPressed: _retry)])));
    if (!summary.hasData) return const Padding(padding: EdgeInsets.all(20), child: Column(children: [Skeleton(height: 170), SizedBox(height: 16), Skeleton(height: 120)]));
    final data = summary.data!.data;
    return ListView(padding: const EdgeInsets.all(20), children: [SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Security Deposit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 5), const Text('Held separately from rent', style: TextStyle(color: CreovyColors.secondary, fontSize: 12)), const SizedBox(height: 16), Wrap(spacing: 16, runSpacing: 12, children: [_DepositMetric('Agreed', data['agreedAmountPaise'] as int), _DepositMetric('Received', data['totalReceivedPaise'] as int), _DepositMetric('Pending', data['pendingToReceivePaise'] as int), _DepositMetric('Refunded', data['totalRefundedPaise'] as int), _DepositMetric('Currently Held', data['heldBalancePaise'] as int)])])), const SizedBox(height: 16), if (widget.agreement.data['status'] == 'ended' && (data['heldBalancePaise'] as int) > 0) FeedbackAlert(message: 'Deposit still held: ${formatInr(data['heldBalancePaise'] as int)}'), if (canWrite) ...[const SizedBox(height: 16), Row(children: [if ((data['pendingToReceivePaise'] as int) > 0) Expanded(child: CreovyButton(label: 'Receive Deposit', icon: Icons.south_west, onPressed: () => _open(DepositTransactionType.received, summary.data!))), if ((data['pendingToReceivePaise'] as int) > 0 && (data['heldBalancePaise'] as int) > 0) const SizedBox(width: 10), if ((data['heldBalancePaise'] as int) > 0) Expanded(child: CreovyButton(label: 'Refund Deposit', icon: Icons.north_east, variant: CreovyButtonVariant.outline, onPressed: () => _open(DepositTransactionType.refunded, summary.data!)))]), ], const SizedBox(height: 26), const Text('Transaction History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 10), StreamBuilder<List<DepositTransactionRecord>>(stream: historyStream, builder: (context, history) {
      if (history.hasError) return Column(children: [const EmptyState(title: 'History unavailable', body: 'Check your connection and retry.'), const SizedBox(height: 10), CreovyButton(label: 'Retry History', onPressed: _retry)]);
      if (!history.hasData) return const Skeleton(height: 110);
      if (history.data!.isEmpty) return const EmptyState(title: 'No deposit transactions yet', body: 'Every collection and refund will remain here, including after the agreement ends.');
      return Column(children: history.data!.map((item) { final movement = item.data; final received = movement['transactionType'] == 'received'; return Padding(padding: const EdgeInsets.only(bottom: 10), child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [StatusChip(label: received ? 'Received' : 'Refunded'), const Spacer(), Text(formatInr(movement['amountPaise'] as int), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))]), const SizedBox(height: 9), Text('${_depositDate((movement['transactionDate'] as Timestamp).toDate())} · ${_modeLabel(movement['paymentMode'] as String)}', style: const TextStyle(color: CreovyColors.secondary)), if ((movement['referenceNumber'] as String).isNotEmpty) Text('Reference: ${movement['referenceNumber']}'), if ((movement['notes'] as String).isNotEmpty) Text(movement['notes'] as String, style: const TextStyle(color: CreovyColors.secondary)), Text('Recorded by: ${movement['createdBy']}', style: const TextStyle(fontSize: 11, color: CreovyColors.muted)), const SizedBox(height: 5), TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DepositReceiptScreen(workspaceId: widget.account.workspaceId, transactionId: item.id))), icon: const Icon(Icons.receipt_long_outlined), label: const Text('View Receipt'))]))); }).toList());
    })]);
  }));
}
String _modeLabel(String mode) => switch (mode) { 'upi' => 'UPI', 'bank_transfer' => 'Bank transfer', 'cash' => 'Cash', 'cheque' => 'Cheque', _ => 'Other' };

class _DepositMovementSheet extends StatefulWidget {
  const _DepositMovementSheet({required this.account, required this.agreement, required this.initial, required this.type});
  final AccountContext account;
  final AgreementRecord agreement;
  final DepositSummaryRecord initial;
  final DepositTransactionType type;
  @override State<_DepositMovementSheet> createState() => _DepositMovementSheetState();
}
class _DepositMovementSheetState extends State<_DepositMovementSheet> {
  late final SecurityDepositRepository repository = SecurityDepositRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late final Stream<DepositSummaryRecord> summaryStream = repository.watchDepositSummary(widget.account.workspaceId, widget.agreement.id);
  late final Future<List<String>> contextNames = _loadContextNames();
  Future<List<String>> _loadContextNames() async {
    final firestore = FirebaseFirestore.instance;
    final agreement = widget.agreement.data;
    final sources = await Future.wait([
      firestore.collection('tenants').doc(agreement['tenantId'] as String).get(),
      firestore.collection('properties').doc(agreement['propertyId'] as String).get(),
      firestore.collection('units').doc(agreement['unitId'] as String).get(),
    ]);
    return [
      sources[0].data()?['workspaceId'] == widget.account.workspaceId ? (sources[0].data()?['fullName'] as String? ?? 'Tenant') : 'Tenant',
      sources[1].data()?['workspaceId'] == widget.account.workspaceId ? (sources[1].data()?['name'] as String? ?? 'Property') : 'Property',
      sources[2].data()?['workspaceId'] == widget.account.workspaceId ? (sources[2].data()?['name'] as String? ?? 'Unit') : 'Unit',
    ];
  }
  late final TextEditingController amount = TextEditingController(text: _depositAmountText(widget.type == DepositTransactionType.received ? widget.initial.data['pendingToReceivePaise'] as int : widget.initial.data['heldBalancePaise'] as int));
  final reference = TextEditingController();
  final notes = TextEditingController();
  late final String submissionId = SecurityDepositRepository.newSubmissionId();
  late DateTime date = _kolkataToday();
  DepositPaymentMode mode = DepositPaymentMode.upi;
  String stage = 'edit';
  String error = '';
  bool busy = false;
  DepositSubmission? attempted;
  late DepositSummaryRecord reviewed = widget.initial;
  DepositSummaryRecord? successSummary;
  int? successAmount;
  @override void initState() { super.initState(); amount.addListener(_changed); reference.addListener(_changed); notes.addListener(_changed); }
  void _changed() { if (mounted && attempted == null) setState(() { error = ''; if (stage == 'confirm') stage = 'edit'; }); }
  @override void dispose() { amount.dispose(); reference.dispose(); notes.dispose(); super.dispose(); }
  Future<void> _chooseDate() async { final picked = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (picked != null) setState(() { date = DateTime.utc(picked.year, picked.month, picked.day); stage = 'edit'; }); }
  Future<void> _submit() async {
    if (busy) return;
    final paise = _depositPaise(amount.text);
    final limit = widget.type == DepositTransactionType.received ? reviewed.data['pendingToReceivePaise'] as int : reviewed.data['heldBalancePaise'] as int;
    if (attempted == null && (paise == null || paise <= 0 || paise > limit)) { setState(() { stage = 'edit'; error = 'Enter an amount above ₹0 and within the available balance.'; }); return; }
    setState(() { busy = true; error = ''; });
    try {
      final input = attempted ?? DepositSubmission(workspaceId: widget.account.workspaceId, agreementId: widget.agreement.id, submissionId: submissionId, amountPaise: paise!, transactionDate: _kolkataInstant(date), paymentMode: mode, referenceNumber: reference.text, notes: notes.text);
      if (attempted == null) {
        final latest = await repository.getDepositSummary(widget.account.workspaceId, widget.agreement.id);
        if (!_sameDeposit(reviewed.data, latest.data)) { if (mounted) setState(() { reviewed = latest; stage = 'edit'; error = 'The deposit balance changed on another device. Review the new totals and amount, then confirm again.'; }); return; }
        attempted = input;
      }
      if (widget.type == DepositTransactionType.received) { await repository.recordDepositReceived(input); } else { await repository.recordDepositRefund(input); }
      final latest = await repository.getDepositSummary(widget.account.workspaceId, widget.agreement.id);
      if (mounted) {
        setState(() { successSummary = latest; successAmount = input.amountPaise; stage = 'success'; });
        Navigator.push(context, MaterialPageRoute(builder: (_) => _DepositSuccessScreen(account: widget.account, type: widget.type, amountPaise: input.amountPaise, summary: latest, transactionId: input.submissionId)));
      }
    } catch (cause) { if (mounted) setState(() => error = '${cause.toString()} Retry this same submission ID if the outcome is uncertain.'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => PopScope(canPop: !busy, child: StreamBuilder<DepositSummaryRecord>(stream: summaryStream, builder: (context, snapshot) {
    final live = snapshot.data ?? reviewed;
    final paise = _depositPaise(amount.text);
    final limit = widget.type == DepositTransactionType.received ? reviewed.data['pendingToReceivePaise'] as int : reviewed.data['heldBalancePaise'] as int;
    final valid = paise != null && paise > 0 && paise <= limit;
    final changed = attempted == null && !_sameDeposit(reviewed.data, live.data);
    if (changed && stage != 'success' && !busy && snapshot.hasData) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && attempted == null) setState(() { reviewed = live; stage = 'edit'; error = 'The deposit balance changed on another device. Review the new totals and amount, then confirm again.'; });
      });
    }
    final title = widget.type == DepositTransactionType.received ? 'Receive Deposit' : 'Refund Deposit';
    return SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92), child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Row(children: [Expanded(child: Text(stage == 'success' ? 'Deposit recorded' : title, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700))), IconButton(onPressed: busy ? null : () => Navigator.pop(context), icon: const Icon(Icons.close))]), const SizedBox(height: 14), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [FutureBuilder<List<String>>(future: contextNames, builder: (context, names) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(names.data?[0] ?? 'Tenant', style: const TextStyle(fontWeight: FontWeight.w700)), Text('${names.data?[1] ?? 'Property'} · ${names.data?[2] ?? 'Unit'}', style: const TextStyle(color: CreovyColors.secondary))])), const SizedBox(height: 9), Text('Agreed ${formatInr(reviewed.data['agreedAmountPaise'] as int)}'), Text('Received ${formatInr(reviewed.data['totalReceivedPaise'] as int)}'), Text('Pending ${formatInr(reviewed.data['pendingToReceivePaise'] as int)}'), Text('Refunded ${formatInr(reviewed.data['totalRefundedPaise'] as int)}'), Text('Currently held ${formatInr(reviewed.data['heldBalancePaise'] as int)}', style: const TextStyle(fontWeight: FontWeight.w700))])), if (snapshot.hasError && attempted == null) const Padding(padding: EdgeInsets.only(top: 12), child: FeedbackAlert(message: 'Live balance is unavailable. Reconnect before recording a deposit.', tone: CreovyColors.danger)), if (changed && stage != 'success') Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: 'The deposit balance changed. Review the new totals before confirming.', tone: CreovyColors.info)), if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: error, tone: CreovyColors.danger)), if (stage == 'edit' && attempted == null) ...[const SizedBox(height: 18), CreovyTextField(label: 'Amount (₹)', controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), errorText: amount.text.isNotEmpty && !valid ? 'Enter a positive amount no more than ${formatInr(limit)}.' : null), const SizedBox(height: 9), ListTile(contentPadding: EdgeInsets.zero, title: Text(widget.type == DepositTransactionType.received ? 'Transaction date' : 'Refund date'), subtitle: Text(_depositDate(_kolkataInstant(date))), trailing: const Icon(Icons.calendar_today_outlined), onTap: _chooseDate), DropdownButtonFormField<DepositPaymentMode>(value: mode, decoration: const InputDecoration(labelText: 'Payment mode'), items: DepositPaymentMode.values.map((item) => DropdownMenuItem(value: item, child: Text(_modeLabel(item.firestoreValue)))).toList(), onChanged: (value) { if (value != null) setState(() => mode = value); }), const SizedBox(height: 12), CreovyTextField(label: 'Reference number (optional)', controller: reference), const SizedBox(height: 12), CreovyTextField(label: 'Notes (optional)', controller: notes), const SizedBox(height: 18), SizedBox(width: double.infinity, child: CreovyButton(label: 'Review $title', onPressed: valid && !snapshot.hasError ? () => setState(() { stage = 'confirm'; error = ''; }) : null))], if (stage == 'confirm') ...[const SizedBox(height: 18), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${widget.type == DepositTransactionType.received ? 'Receive' : 'Refund'} ${formatInr(paise)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)), Text(widget.type == DepositTransactionType.received ? 'After this: Received ${formatInr((reviewed.data['totalReceivedPaise'] as int) + (paise ?? 0))} · Pending ${formatInr(limit - (paise ?? 0))} · Held ${formatInr((reviewed.data['heldBalancePaise'] as int) + (paise ?? 0))}' : 'After this: Refunded ${formatInr((reviewed.data['totalRefundedPaise'] as int) + (paise ?? 0))} · Held ${formatInr(limit - (paise ?? 0))}') ])), const SizedBox(height: 18), Row(children: [Expanded(child: CreovyButton(label: 'Back', variant: CreovyButtonVariant.outline, onPressed: attempted == null && !busy ? () => setState(() => stage = 'edit') : null)), const SizedBox(width: 10), Expanded(child: CreovyButton(label: attempted == null ? 'Confirm' : 'Retry same submission', loading: busy, onPressed: !busy && (attempted != null || (valid && !changed && !snapshot.hasError)) ? _submit : null))])], if (stage == 'success' && successSummary != null) ...[const SizedBox(height: 18), FeedbackAlert(message: '${widget.type == DepositTransactionType.received ? 'Received' : 'Refunded'} ${formatInr(successAmount)}', tone: CreovyColors.success), const SizedBox(height: 12), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Total received ${formatInr(successSummary!.data['totalReceivedPaise'] as int)}'), Text('Pending ${formatInr(successSummary!.data['pendingToReceivePaise'] as int)}'), Text('Total refunded ${formatInr(successSummary!.data['totalRefundedPaise'] as int)}'), Text('Currently held ${formatInr(successSummary!.data['heldBalancePaise'] as int)}')])), const SizedBox(height: 18), SizedBox(width: double.infinity, child: CreovyButton(label: 'Done', onPressed: () => Navigator.pop(context)))]]))))));
  }));
}

class _DepositSuccessScreen extends StatelessWidget {
  const _DepositSuccessScreen({required this.account, required this.type, required this.amountPaise, required this.summary, required this.transactionId});
  final AccountContext account;
  final DepositTransactionType type;
  final int amountPaise;
  final DepositSummaryRecord summary;
  final String transactionId;
  @override Widget build(BuildContext context) {
    final received = type == DepositTransactionType.received;
    final data = summary.data;
    return Scaffold(appBar: AppBar(title: const Text('Deposit recorded')), body: SafeArea(child: ListView(padding: const EdgeInsets.all(20), children: [
      const Icon(Icons.check_circle_rounded, size: 56, color: CreovyColors.success), const SizedBox(height: 14),
      Text(received ? 'Deposit received' : 'Deposit refunded', textAlign: TextAlign.center, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
      const SizedBox(height: 5), Text(formatInr(amountPaise), textAlign: TextAlign.center, style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w700, color: CreovyColors.brand)),
      const SizedBox(height: 20), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (received) Text('Total received ${formatInr(data['totalReceivedPaise'] as int)}'),
        if (received) Text('Pending ${formatInr(data['pendingToReceivePaise'] as int)}'),
        if (!received) Text('Total refunded ${formatInr(data['totalRefundedPaise'] as int)}'),
        Text('Currently held ${formatInr(data['heldBalancePaise'] as int)}', style: const TextStyle(fontWeight: FontWeight.w700)),
      ])), const SizedBox(height: 20), CreovyButton(label: 'View Receipt', icon: Icons.receipt_long_outlined, onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DepositReceiptScreen(workspaceId: account.workspaceId, transactionId: transactionId)))),
      const SizedBox(height: 10), CreovyButton(label: 'Done', variant: CreovyButtonVariant.outline, onPressed: () { final navigator = Navigator.of(context); navigator.pop(); navigator.pop(); }),
    ])));
  }
}
