import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/rent_due_repository.dart';
import '../data/rent_payment_repository.dart';
import 'design_system.dart';
import 'receipt_screen.dart';

String _amountText(int paise) { final minor = paise % 100; return '${paise ~/ 100}${minor == 0 ? '' : '.${minor.toString().padLeft(2, '0')}'}'; }
int? _parsePaise(String text) {
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final rupees = int.tryParse(parts.first);
  if (rupees == null || rupees > 90071992547409) return null;
  final minor = parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0'));
  final paise = rupees * 100 + minor;
  return paise <= 9007199254740991 ? paise : null;
}

class CollectRentSheet extends StatefulWidget {
  const CollectRentSheet({super.key, required this.due, required this.tenantName, required this.propertyName, required this.unitName});
  final RentDueRecord due;
  final String tenantName, propertyName, unitName;
  @override State<CollectRentSheet> createState() => _CollectRentSheetState();
}

class _CollectRentSheetState extends State<CollectRentSheet> {
  late final RentDueRepository _dues = RentDueRepository(FirebaseFirestore.instance);
  late final Stream<RentDueRecord?> _dueStream = _dues.watchDue(widget.due.data['workspaceId'] as String, widget.due.id);
  late final RentPaymentRepository _payments = RentPaymentRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late final TextEditingController _amount = TextEditingController(text: _amountText((widget.due.data['balancePaise'] as num).toInt()));
  final TextEditingController _reference = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  late String _submissionId = RentPaymentRepository.newSubmissionId();
  late DateTime _date = _businessToday();
  RentPaymentMode _mode = RentPaymentMode.upi;
  String _stage = 'edit';
  String _error = '';
  bool _submitting = false;
  bool _attempted = false;
  int? _reviewedBalance;
  RentDueRecord? _successDue;
  int? _received;

  @override void initState() { super.initState(); _amount.addListener(_onTextChanged); _reference.addListener(_onTextChanged); _notes.addListener(_onTextChanged); }
  void _onTextChanged() { if (!mounted) return; setState(() { if (_attempted) { _submissionId = RentPaymentRepository.newSubmissionId(); _attempted = false; } _error = ''; }); }

  DateTime _businessToday() { final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)); return DateTime.utc(now.year, now.month, now.day); }
  DateTime get _paymentInstant => DateTime.utc(_date.year, _date.month, _date.day).subtract(const Duration(hours: 5, minutes: 30));
  @override void dispose() { _amount.dispose(); _reference.dispose(); _notes.dispose(); super.dispose(); }
  void _changeIntent(VoidCallback change) { setState(() { if (_attempted) { _submissionId = RentPaymentRepository.newSubmissionId(); _attempted = false; } change(); _error = ''; }); }

  Future<void> _chooseDate() async {
    final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (picked != null && (picked.year != _date.year || picked.month != _date.month || picked.day != _date.day)) _changeIntent(() => _date = DateTime.utc(picked.year, picked.month, picked.day));
  }

  Future<void> _submit(RentDueRecord current) async {
    if (_submitting) return;
    final amountPaise = _parsePaise(_amount.text.trim());
    final balance = (current.data['balancePaise'] as num).toInt();
    if (amountPaise == null || amountPaise <= 0 || (!_attempted && (amountPaise > balance || _reviewedBalance != balance))) {
      setState(() { _stage = 'edit'; _error = 'The outstanding balance changed. Please review the updated amount.'; });
      return;
    }
    setState(() { _submitting = true; _attempted = true; _error = ''; });
    try {
      await _payments.recordPayment(RentPaymentSubmission(workspaceId: current.data['workspaceId'] as String, rentDueId: current.id, submissionId: _submissionId,
        amountPaise: amountPaise, paymentDate: _paymentInstant, paymentMode: _mode, referenceNumber: _reference.text, notes: _notes.text));
      final latest = await _dues.getDue(current.data['workspaceId'] as String, current.id);
      if (latest == null) throw StateError('Payment was recorded, but the latest due could not be loaded. Retry safely with the same submission ID.');
      if (mounted) setState(() { _successDue = latest; _received = amountPaise; _stage = 'success'; });
    } catch (error) {
      final message = error.toString().replaceFirst(RegExp(r'^(Bad state|Invalid argument): '), '');
      final rejectedForBalance = message.contains('Payment exceeds the outstanding balance') || message.contains('already fully paid') || message.contains('totals are inconsistent') || message.contains('status is inconsistent');
      if (mounted) setState(() {
        if (rejectedForBalance) { _stage = 'edit'; _error = 'The outstanding balance changed. Please review the updated amount.'; }
        else { _error = '$message Retry with the same submission ID if the result is uncertain.'; }
      });
    } finally { if (mounted) setState(() => _submitting = false); }
  }

  @override Widget build(BuildContext context) => PopScope(canPop: !_submitting, child: StreamBuilder<RentDueRecord?>(
    stream: _dueStream,
    builder: (context, snapshot) {
      final current = snapshot.data ?? widget.due;
      final balance = (current.data['balancePaise'] as num).toInt();
      final amountPaise = _parsePaise(_amount.text.trim());
      final valid = !snapshot.hasError && amountPaise != null && amountPaise > 0 && amountPaise <= balance;
      final changed = _stage == 'confirm' && !_attempted && _reviewedBalance != balance;
      return SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92), child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [Expanded(child: Text(_stage == 'success' ? 'Payment recorded successfully' : _stage == 'confirm' ? 'Confirm Payment' : 'Collect Rent', style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700, color: CreovyColors.ink))), IconButton(onPressed: _submitting ? null : () => Navigator.pop(context), icon: const Icon(Icons.close), tooltip: 'Close')]),
        const SizedBox(height: 18), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.tenantName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), Text('${widget.propertyName} · ${widget.unitName}', style: const TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 12), Text('Rent period ${current.data['periodKey']} · Rent ${formatInr((current.data['rentAmountPaise'] as num).toInt())}'), Text('Already paid ${formatInr(((_successDue ?? current).data['totalPaidPaise'] as num).toInt())}'), Text('Current balance ${formatInr(((_successDue ?? current).data['balancePaise'] as num).toInt())}', style: const TextStyle(fontWeight: FontWeight.w700))])),
        if (snapshot.hasError) const Padding(padding: EdgeInsets.only(top: 12), child: FeedbackAlert(message: 'Live balance is unavailable. Please reconnect before recording rent.', tone: CreovyColors.danger)),
        if (_stage == 'edit') ...[
          const SizedBox(height: 18), CreovyTextField(label: 'Receiving now (₹)', controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), errorText: _amount.text.isNotEmpty && !valid ? 'Enter an amount above ₹0 and no more than the balance.' : null),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: balance > 0 ? () { final full = _amountText(balance); if (_amount.text != full) _amount.text = full; } : null, child: const Text('Pay Full Balance'))),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Payment date'), subtitle: Text('${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}'), trailing: const Icon(Icons.calendar_today_outlined), onTap: _chooseDate),
          DropdownButtonFormField<RentPaymentMode>(value: _mode, decoration: const InputDecoration(labelText: 'Payment mode'), items: RentPaymentMode.values.map((mode) => DropdownMenuItem(value: mode, child: Text(switch (mode) { RentPaymentMode.cash => 'Cash', RentPaymentMode.upi => 'UPI', RentPaymentMode.bankTransfer => 'Bank Transfer', RentPaymentMode.cheque => 'Cheque', RentPaymentMode.other => 'Other' }))).toList(), onChanged: (mode) { if (mode != null && mode != _mode) _changeIntent(() => _mode = mode); }),
          const SizedBox(height: 14), CreovyTextField(label: 'Reference number (optional)', controller: _reference), const SizedBox(height: 14), CreovyTextField(label: 'Notes (optional)', controller: _notes),
          const SizedBox(height: 14), SurfaceCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Balance after payment'), Text(valid ? formatInr(balance - amountPaise!) : '—', style: const TextStyle(fontWeight: FontWeight.w700, color: CreovyColors.brand))])),
          if (_error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: _error, tone: CreovyColors.danger)),
          const SizedBox(height: 18), SizedBox(width: double.infinity, child: CreovyButton(label: 'Review Payment', icon: Icons.arrow_forward_rounded, onPressed: valid ? () => setState(() { _reviewedBalance = balance; _stage = 'confirm'; _error = ''; }) : null)),
        ],
        if (_stage == 'confirm') ...[
          const SizedBox(height: 18), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Receiving now: ${formatInr(amountPaise)}', style: const TextStyle(fontWeight: FontWeight.w700)), Text('Mode: ${switch (_mode) { RentPaymentMode.cash => 'Cash', RentPaymentMode.upi => 'UPI', RentPaymentMode.bankTransfer => 'Bank Transfer', RentPaymentMode.cheque => 'Cheque', RentPaymentMode.other => 'Other' }}'), Text('Payment date: ${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}'), Text('Balance after payment: ${formatInr((_reviewedBalance ?? balance) - (amountPaise ?? 0))}') ])),
          if (changed || _error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: changed ? 'The outstanding balance changed. Please review the updated amount.' : _error, tone: CreovyColors.danger)),
          const SizedBox(height: 18), Row(children: [Expanded(child: CreovyButton(label: 'Back', icon: Icons.arrow_back, variant: CreovyButtonVariant.outline, onPressed: _submitting ? null : () => setState(() => _stage = 'edit'))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: _attempted ? 'Retry Payment' : 'Confirm Payment', icon: Icons.check, loading: _submitting, onPressed: !_submitting && ((valid && !changed) || _attempted) ? () => _submit(current) : null))]),
        ],
        if (_stage == 'success' && _successDue != null) ...[
          const SizedBox(height: 18), FeedbackAlert(message: 'Received ${formatInr(_received)}', tone: CreovyColors.success), const SizedBox(height: 14), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Total paid ${formatInr((_successDue!.data['totalPaidPaise'] as num).toInt())}'), Text('Balance ${formatInr((_successDue!.data['balancePaise'] as num).toInt())}'), const SizedBox(height: 8), StatusChip(label: (_successDue!.data['status'] as String) == 'paid' ? 'Paid' : 'Partial')])), const SizedBox(height: 18), Row(children: [Expanded(child: CreovyButton(label: 'Done', icon: Icons.check, variant: CreovyButtonVariant.outline, onPressed: () => Navigator.pop(context))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: 'View Receipt', icon: Icons.receipt_long_outlined, onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiptScreen(workspaceId: widget.due.data['workspaceId'] as String, paymentId: _submissionId)))))]),
        ],
      ]))))));
    },
  ));
}
