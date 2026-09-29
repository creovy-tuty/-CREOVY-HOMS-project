import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/account_resolver.dart';
import '../data/property_bill_repository.dart';
import '../data/property_repository.dart';
import 'design_system.dart';

const _indiaOffset = Duration(hours: 5, minutes: 30);
DateTime _indiaToday() { final value = DateTime.now().toUtc().add(_indiaOffset); return DateTime.utc(value.year, value.month, value.day); }
DateTime _indiaInstant(DateTime date) => DateTime.utc(date.year, date.month, date.day).subtract(_indiaOffset);
String _date(DateTime instant) { final value = instant.toUtc().add(_indiaOffset); return '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}'; }
String _amountText(int paise) => '${paise ~/ 100}${paise % 100 == 0 ? '' : '.${(paise % 100).toString().padLeft(2, '0')}'}';
int? _paise(String text) {
  final value = text.trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.'); final rupees = int.tryParse(parts.first);
  if (rupees == null || rupees > 90071992547409) return null;
  final amount = rupees * 100 + (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
  return amount > 0 && amount <= 9007199254740991 ? amount : null;
}
String _type(String type) => switch (type) { 'electricity' => 'Electricity / EB', 'water_tax' => 'Water Tax', 'property_tax' => 'Property Tax', _ => 'Other Bill' };
String _mode(String mode) => switch (mode) { 'upi' => 'UPI', 'bank_transfer' => 'Bank transfer', 'cash' => 'Cash', 'cheque' => 'Cheque', _ => 'Other' };
bool _late(PropertyBillRecord bill) => (bill.data['balancePaise'] as int) > 0 &&
  !DateTime.now().toUtc().isBefore((bill.data['dueDate'] as Timestamp).toDate().toUtc().add(const Duration(days: 1)));
String _status(PropertyBillRecord bill) => bill.data['status'] == 'pending' && _late(bill) ? 'Overdue' :
  switch (bill.data['status']) { 'paid' => 'Paid', 'partial' => 'Partial', 'overdue' => 'Overdue', _ => 'Pending' };
bool _canWrite(AccountContext account) => const ['owner', 'manager', 'accountant'].contains(account.role);

class PropertyBillsScreen extends StatefulWidget {
  const PropertyBillsScreen({super.key, required this.account, this.initialPropertyId});
  final AccountContext account;
  final String? initialPropertyId;
  @override State<PropertyBillsScreen> createState() => _PropertyBillsScreenState();
}
class _PropertyBillsScreenState extends State<PropertyBillsScreen> {
  late final PropertyBillRepository repository = PropertyBillRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late final PropertyRepository propertiesRepository = PropertyRepository(FirebaseFirestore.instance);
  late Stream<List<PropertyBillRecord>> billsStream;
  late Stream<List<PropertyRecord>> propertiesStream;
  late Stream<List<UnitRecord>> unitsStream;
  final search = TextEditingController();
  String typeFilter = 'all', statusFilter = 'all';
  late String propertyFilter = widget.initialPropertyId ?? 'all';
  void _connect() { billsStream = repository.watchBills(widget.account.workspaceId); propertiesStream = propertiesRepository.watchProperties(widget.account.workspaceId); unitsStream = propertiesRepository.watchAllUnits(widget.account.workspaceId); }
  @override void initState() { super.initState(); _connect(); _refreshOverdue(); }
  Future<void> _refreshOverdue() async {
    if (!_canWrite(widget.account)) return;
    try { for (final bill in await repository.listBills(widget.account.workspaceId)) {
      if (bill.data['status'] == 'pending' && _late(bill)) await repository.refreshOverdueState(widget.account.workspaceId, bill.id);
    } } catch (_) { /* The list still displays derived past-due context. */ }
  }
  @override void dispose() { search.dispose(); super.dispose(); }
  void _add(List<PropertyRecord> properties, List<UnitRecord> units) => showModalBottomSheet<void>(context: context,
    isScrollControlled: true, backgroundColor: CreovyColors.surface, builder: (_) => _BillEditorSheet(
      account: widget.account, properties: properties, units: units, initialPropertyId: propertyFilter == 'all' ? null : propertyFilter));
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bills & Taxes'), actions: [IconButton(tooltip: 'Refresh overdue', onPressed: _refreshOverdue, icon: const Icon(Icons.refresh_rounded))]),
    body: StreamBuilder<List<PropertyRecord>>(stream: propertiesStream, builder: (context, properties) =>
      StreamBuilder<List<UnitRecord>>(stream: unitsStream, builder: (context, units) =>
      StreamBuilder<List<PropertyBillRecord>>(stream: billsStream, builder: (context, bills) {
        if (properties.hasError || units.hasError || bills.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const EmptyState(title: 'Bills unavailable', body: 'Check your connection and retry.'), const SizedBox(height: 12), CreovyButton(label: 'Retry', icon: Icons.refresh, onPressed: () => setState(_connect))])));
        if (!properties.hasData || !units.hasData || !bills.hasData) return const Padding(padding: EdgeInsets.all(20), child: Column(children: [Skeleton(height: 90), SizedBox(height: 12), Skeleton(height: 90), SizedBox(height: 12), Skeleton(height: 120)]));
        final all = bills.data!; final propertyItems = properties.data!; final unitItems = units.data!;
        final matching = all.where((bill) {
          final name = propertyItems.where((item) => item.id == bill.data['propertyId']).firstOrNull?.data['name'] ?? '';
          final query = '${_type(bill.data['billType'] as String)} $name ${bill.data['providerName']} ${bill.data['consumerNumber']} ${bill.data['periodKey']}'.toLowerCase();
          return query.contains(search.text.toLowerCase()) && (typeFilter == 'all' || bill.data['billType'] == typeFilter) &&
            (propertyFilter == 'all' || bill.data['propertyId'] == propertyFilter) &&
            (statusFilter == 'all' || _status(bill).toLowerCase() == statusFilter);
        }).toList();
        final paid = all.fold<int>(0, (sum, item) => sum + (item.data['totalPaidPaise'] as int));
        final pending = all.where((item) => !_late(item)).fold<int>(0, (sum, item) => sum + (item.data['balancePaise'] as int));
        final overdue = all.where(_late).fold<int>(0, (sum, item) => sum + (item.data['balancePaise'] as int));
        return RefreshIndicator(onRefresh: () async { await _refreshOverdue(); if (mounted) setState(() {}); }, child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 32), children: [
          const Text('Manual tracking for electricity, water, property tax and more.', style: TextStyle(color: CreovyColors.secondary)),
          const SizedBox(height: 18), Wrap(spacing: 9, runSpacing: 9, children: [
            _BillMetric('Total Bills', '${all.length}'), _BillMetric('Pending Amount', formatInr(pending)),
            _BillMetric('Paid Amount', formatInr(paid)), _BillMetric('Overdue Amount', formatInr(overdue)),
          ]), const SizedBox(height: 18), if (_canWrite(widget.account)) SizedBox(width: double.infinity,
            child: CreovyButton(label: 'Add Bill', icon: Icons.add, onPressed: () => _add(propertyItems, unitItems))),
          const SizedBox(height: 18), TextField(controller: search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search bills, provider, property…')),
          const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 150, child: DropdownButtonFormField<String>(value: typeFilter, decoration: const InputDecoration(labelText: 'Bill type'), items: const [DropdownMenuItem(value: 'all', child: Text('All types')), DropdownMenuItem(value: 'electricity', child: Text('Electricity')), DropdownMenuItem(value: 'water_tax', child: Text('Water Tax')), DropdownMenuItem(value: 'property_tax', child: Text('Property Tax')), DropdownMenuItem(value: 'other', child: Text('Other'))], onChanged: (value) => setState(() => typeFilter = value ?? 'all'))),
            SizedBox(width: 170, child: DropdownButtonFormField<String>(value: propertyFilter, decoration: const InputDecoration(labelText: 'Property'), items: [const DropdownMenuItem(value: 'all', child: Text('All properties')), ...propertyItems.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Property', overflow: TextOverflow.ellipsis)))], onChanged: (value) => setState(() => propertyFilter = value ?? 'all'))),
            SizedBox(width: 150, child: DropdownButtonFormField<String>(value: statusFilter, decoration: const InputDecoration(labelText: 'Status'), items: const [DropdownMenuItem(value: 'all', child: Text('All statuses')), DropdownMenuItem(value: 'pending', child: Text('Pending')), DropdownMenuItem(value: 'partial', child: Text('Partial')), DropdownMenuItem(value: 'paid', child: Text('Paid')), DropdownMenuItem(value: 'overdue', child: Text('Overdue'))], onChanged: (value) => setState(() => statusFilter = value ?? 'all'))),
          ]), const SizedBox(height: 20),
          if (matching.isEmpty) EmptyState(title: all.isEmpty ? 'No bills yet' : 'No matching bills', body: all.isEmpty ? 'Add a bill to track due dates and payments.' : 'Try another search or filter.')
          else ...matching.map((bill) { final property = propertyItems.where((item) => item.id == bill.data['propertyId']).firstOrNull; final unit = unitItems.where((item) => item.id == bill.data['unitId']).firstOrNull; return Padding(padding: const EdgeInsets.only(bottom: 10), child: SurfaceCard(padding: EdgeInsets.zero, child: InkWell(borderRadius: BorderRadius.circular(18), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PropertyBillDetailScreen(account: widget.account, billId: bill.id, propertyName: property?.data['name'] as String? ?? 'Property', unitName: unit?.data['name'] as String? ?? 'Property level', properties: propertyItems, units: unitItems))), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Expanded(child: Text(_type(bill.data['billType'] as String), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))), StatusChip(label: _status(bill))]), const SizedBox(height: 5), Text('${property?.data['name'] ?? 'Property'} · ${unit?.data['name'] ?? 'Property level'}', style: const TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 5), Text('${bill.data['providerName']} · ${bill.data['consumerNumber'] == '' ? bill.data['periodKey'] : bill.data['consumerNumber']}', style: const TextStyle(fontSize: 13, color: CreovyColors.secondary)), const SizedBox(height: 8), Text('Period: ${bill.data['periodKey'] == '' ? '—' : bill.data['periodKey']} · Bill: ${formatInr(bill.data['amountPaise'] as int)} · Paid: ${formatInr(bill.data['totalPaidPaise'] as int)}', style: const TextStyle(fontSize: 12, color: CreovyColors.secondary)), const SizedBox(height: 12), Row(children: [Expanded(child: Text('Due ${_date((bill.data['dueDate'] as Timestamp).toDate())}', style: const TextStyle(fontSize: 12, color: CreovyColors.secondary))), Text(formatInr(bill.data['balancePaise'] as int), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))]), if (bill.data['status'] == 'partial' && _late(bill)) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Past due', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CreovyColors.danger)))]))))); }),
        ]));
      }))),
  );
}
class _BillMetric extends StatelessWidget { const _BillMetric(this.label, this.value); final String label, value; @override Widget build(BuildContext context) => SizedBox(width: 148, child: SurfaceCard(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 11, color: CreovyColors.secondary)), const SizedBox(height: 7), Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))]))); }

class PropertyBillDetailScreen extends StatefulWidget {
  const PropertyBillDetailScreen({super.key, required this.account, required this.billId, required this.propertyName, required this.unitName, required this.properties, required this.units});
  final AccountContext account; final String billId, propertyName, unitName;
  final List<PropertyRecord> properties; final List<UnitRecord> units;
  @override State<PropertyBillDetailScreen> createState() => _PropertyBillDetailScreenState();
}
class _PropertyBillDetailScreenState extends State<PropertyBillDetailScreen> {
  late final PropertyBillRepository repository = PropertyBillRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late Stream<PropertyBillRecord?> billStream;
  late Stream<List<PropertyBillPaymentRecord>> historyStream;
  void _connect() { billStream = repository.watchBill(widget.account.workspaceId, widget.billId); historyStream = repository.watchBillPayments(widget.account.workspaceId, widget.billId); }
  @override void initState() { super.initState(); _connect(); }
  void _edit(PropertyBillRecord bill) => showModalBottomSheet<void>(context: context, isScrollControlled: true,
    backgroundColor: CreovyColors.surface, builder: (_) => _BillEditorSheet(account: widget.account, bill: bill, properties: widget.properties, units: widget.units));
  void _pay(PropertyBillRecord bill) => showModalBottomSheet<void>(context: context, isScrollControlled: true,
    isDismissible: false, enableDrag: false, backgroundColor: CreovyColors.surface,
    builder: (_) => _BillPaymentSheet(account: widget.account, bill: bill, propertyName: widget.propertyName, unitName: widget.unitName));
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Bill Detail')),
    body: StreamBuilder<PropertyBillRecord?>(stream: billStream, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const EmptyState(title: 'Bill unavailable', body: 'Check your connection and retry.'), const SizedBox(height: 12), CreovyButton(label: 'Retry', icon: Icons.refresh, onPressed: () => setState(_connect))])));
      if (snapshot.connectionState == ConnectionState.waiting) return const Padding(padding: EdgeInsets.all(20), child: Column(children: [Skeleton(height: 160), SizedBox(height: 16), Skeleton(height: 140)]));
      final bill = snapshot.data;
      if (bill == null) return const Center(child: EmptyState(title: 'Bill not found', body: 'It is not available in this workspace.'));
      final data = bill.data;
      return ListView(padding: const EdgeInsets.all(20), children: [SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Expanded(child: Text(_type(data['billType'] as String), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))), StatusChip(label: _status(bill))]), const SizedBox(height: 8), Text(data['providerName'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)), Text('${widget.propertyName} · ${widget.unitName}', style: const TextStyle(color: CreovyColors.secondary)), if (data['status'] == 'partial' && _late(bill)) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Past due', style: TextStyle(color: CreovyColors.danger, fontWeight: FontWeight.w700)))])), const SizedBox(height: 12), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _detail('Consumer / assessment', data['consumerNumber'] as String), _detail('Billing period', data['periodKey'] as String), _detail('Bill date', _date((data['billDate'] as Timestamp).toDate())), _detail('Due date', _date((data['dueDate'] as Timestamp).toDate())), _detail('Original amount', formatInr(data['amountPaise'] as int)), _detail('Total paid', formatInr(data['totalPaidPaise'] as int)), _detail('Balance', formatInr(data['balancePaise'] as int)), _detail('Current status', _status(bill)), if ((data['notes'] as String).isNotEmpty) _detail('Notes', data['notes'] as String),
      ])), if (_canWrite(widget.account)) ...[const SizedBox(height: 14), Row(children: [Expanded(child: CreovyButton(label: 'Record Payment', icon: Icons.payments_outlined, onPressed: (data['balancePaise'] as int) > 0 ? () => _pay(bill) : null)), const SizedBox(width: 9), Expanded(child: CreovyButton(label: 'Edit Details', icon: Icons.edit_outlined, variant: CreovyButtonVariant.outline, onPressed: () => _edit(bill)))]), ], const SizedBox(height: 25), const Text('Payment History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 10), StreamBuilder<List<PropertyBillPaymentRecord>>(stream: historyStream, builder: (context, history) {
        if (history.hasError) return Column(children: [const EmptyState(title: 'History unavailable', body: 'Check your connection and retry.'), const SizedBox(height: 10), CreovyButton(label: 'Retry History', icon: Icons.refresh, onPressed: () => setState(_connect))]);
        if (!history.hasData) return const Skeleton(height: 90);
        if (history.data!.isEmpty) return const EmptyState(title: 'No payments yet', body: 'Confirmed bill payments will remain here.');
        return Column(children: history.data!.map((item) => Padding(padding: const EdgeInsets.only(bottom: 9), child: SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Expanded(child: Text(formatInr(item.data['amountPaise'] as int), style: const TextStyle(fontWeight: FontWeight.w700))), Text(_date((item.data['paymentDate'] as Timestamp).toDate()), style: const TextStyle(color: CreovyColors.secondary))]), const SizedBox(height: 5), Text('${_mode(item.data['paymentMode'] as String)} · ${item.data['referenceNumber'] == '' ? 'No reference' : item.data['referenceNumber']}', style: const TextStyle(fontSize: 13, color: CreovyColors.secondary)), if ((item.data['notes'] as String).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 5), child: Text(item.data['notes'] as String)), const SizedBox(height: 5), Text('Recorded by ${item.data['createdBy']}', style: const TextStyle(fontSize: 11, color: CreovyColors.muted))])))).toList());
      })]);
    }));
  Widget _detail(String title, String value) => Padding(padding: const EdgeInsets.only(bottom: 11), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 150, child: Text(title, style: const TextStyle(color: CreovyColors.secondary, fontSize: 13))), Expanded(child: Text(value.isEmpty ? '—' : value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)))]));
}

class _BillEditorSheet extends StatefulWidget {
  const _BillEditorSheet({required this.account, required this.properties, required this.units, this.initialPropertyId, this.bill});
  final AccountContext account; final List<PropertyRecord> properties; final List<UnitRecord> units;
  final String? initialPropertyId; final PropertyBillRecord? bill;
  @override State<_BillEditorSheet> createState() => _BillEditorSheetState();
}
class _BillEditorSheetState extends State<_BillEditorSheet> {
  late final PropertyBillRepository repository = PropertyBillRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late String? propertyId = widget.bill?.data['propertyId'] as String? ?? widget.initialPropertyId;
  late String? unitId = widget.bill?.data['unitId'] as String?;
  late PropertyBillType type = PropertyBillType.values.firstWhere((item) => item.firestoreValue == widget.bill?.data['billType'], orElse: () => PropertyBillType.electricity);
  late final provider = TextEditingController(text: widget.bill?.data['providerName'] as String? ?? '');
  late final consumer = TextEditingController(text: widget.bill?.data['consumerNumber'] as String? ?? '');
  late final period = TextEditingController(text: widget.bill?.data['periodKey'] as String? ?? '');
  late final amount = TextEditingController(text: widget.bill == null ? '' : _amountText(widget.bill!.data['amountPaise'] as int));
  late final notes = TextEditingController(text: widget.bill?.data['notes'] as String? ?? '');
  late DateTime billDate = widget.bill == null ? _indiaToday() : _calendar((widget.bill!.data['billDate'] as Timestamp).toDate());
  late DateTime dueDate = widget.bill == null ? _indiaToday() : _calendar((widget.bill!.data['dueDate'] as Timestamp).toDate());
  bool busy = false; String error = '';
  bool get paid => widget.bill != null && (widget.bill!.data['totalPaidPaise'] as int) > 0;
  DateTime _calendar(DateTime instant) { final day = instant.toUtc().add(_indiaOffset); return DateTime.utc(day.year, day.month, day.day); }
  @override void dispose() { provider.dispose(); consumer.dispose(); period.dispose(); amount.dispose(); notes.dispose(); super.dispose(); }
  Future<void> _pick(bool due) async { final current = due ? dueDate : billDate; final value = await showDatePicker(context: context, initialDate: DateTime(current.year, current.month, current.day), firstDate: DateTime(2000), lastDate: DateTime(2100)); if (value != null) setState(() { if (due) { dueDate = DateTime.utc(value.year, value.month, value.day); } else { billDate = DateTime.utc(value.year, value.month, value.day); } }); }
  Future<void> _save() async {
    if (busy) return;
    final paise = _paise(amount.text);
    if (propertyId == null || provider.text.trim().isEmpty || paise == null || dueDate.isBefore(billDate)) { setState(() => error = 'Select a property, provider, valid amount and due date.'); return; }
    setState(() { busy = true; error = ''; });
    try {
      if (widget.bill == null) {
        await repository.createBill(PropertyBillDraft(workspaceId: widget.account.workspaceId, propertyId: propertyId!, unitId: unitId, billType: type, providerName: provider.text, consumerNumber: consumer.text, periodKey: period.text, billDate: _indiaInstant(billDate), dueDate: _indiaInstant(dueDate), amountPaise: paise, notes: notes.text));
      } else {
        await repository.updateSafeBillMetadata(widget.account.workspaceId, widget.bill!.id, paid ? SafePropertyBillMetadata(notes: notes.text) : SafePropertyBillMetadata(providerName: provider.text, consumerNumber: consumer.text, periodKey: period.text, billDate: _indiaInstant(billDate), dueDate: _indiaInstant(dueDate), amountPaise: paise, notes: notes.text));
      }
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.bill == null ? 'Bill added successfully.' : 'Bill details updated.'))); Navigator.pop(context); }
    } catch (cause) { if (mounted) setState(() => error = cause.toString()); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92), child: SingleChildScrollView(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
    Row(children: [Expanded(child: Text(widget.bill == null ? 'Add Bill' : 'Edit Safe Details', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))), IconButton(onPressed: busy ? null : () => Navigator.pop(context), icon: const Icon(Icons.close))]),
    if (paid) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: FeedbackAlert(message: 'This bill has payment history. Only notes can be changed.')),
    const SizedBox(height: 12), DropdownButtonFormField<PropertyBillType>(value: type, decoration: const InputDecoration(labelText: 'Bill type'), items: PropertyBillType.values.map((item) => DropdownMenuItem(value: item, child: Text(_type(item.firestoreValue)))).toList(), onChanged: widget.bill != null ? null : (value) => setState(() => type = value ?? type)),
    const SizedBox(height: 12), DropdownButtonFormField<String>(value: propertyId, decoration: const InputDecoration(labelText: 'Property *'), items: widget.properties.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Property'))).toList(), onChanged: widget.bill != null ? null : (value) => setState(() { propertyId = value; unitId = null; })),
    const SizedBox(height: 12), DropdownButtonFormField<String>(value: unitId, decoration: const InputDecoration(labelText: 'Unit (optional)'), items: [const DropdownMenuItem<String>(value: null, child: Text('Property level')), ...widget.units.where((item) => item.data['propertyId'] == propertyId).map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Unit')))], onChanged: widget.bill != null ? null : (value) => setState(() => unitId = value)),
    const SizedBox(height: 14), CreovyTextField(label: 'Provider / authority *', controller: provider, enabled: !paid), const SizedBox(height: 12), CreovyTextField(label: 'Consumer / assessment number', controller: consumer, enabled: !paid), const SizedBox(height: 12), CreovyTextField(label: 'Billing period', controller: period, enabled: !paid), const SizedBox(height: 12), CreovyTextField(label: 'Amount (₹) *', controller: amount, enabled: !paid, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
    ListTile(contentPadding: EdgeInsets.zero, title: const Text('Bill date'), subtitle: Text(_date(_indiaInstant(billDate))), trailing: const Icon(Icons.calendar_today_outlined), onTap: paid ? null : () => _pick(false)),
    ListTile(contentPadding: EdgeInsets.zero, title: const Text('Due date'), subtitle: Text(_date(_indiaInstant(dueDate))), trailing: const Icon(Icons.calendar_today_outlined), onTap: paid ? null : () => _pick(true)),
    CreovyTextField(label: 'Notes', controller: notes), if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: error, tone: CreovyColors.danger)), const SizedBox(height: 18), SizedBox(width: double.infinity, child: CreovyButton(label: widget.bill == null ? 'Add Bill' : 'Save Details', icon: Icons.check, loading: busy, onPressed: _save)),
  ])))));
}

class _BillPaymentSheet extends StatefulWidget {
  const _BillPaymentSheet({required this.account, required this.bill, required this.propertyName, required this.unitName});
  final AccountContext account; final PropertyBillRecord bill; final String propertyName, unitName;
  @override State<_BillPaymentSheet> createState() => _BillPaymentSheetState();
}
class _BillPaymentSheetState extends State<_BillPaymentSheet> {
  late final PropertyBillRepository repository = PropertyBillRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late PropertyBillRecord current = widget.bill;
  late final amount = TextEditingController(text: _amountText(widget.bill.data['balancePaise'] as int));
  final reference = TextEditingController(), notes = TextEditingController();
  late DateTime date = _indiaToday(); PropertyBillPaymentMode mode = PropertyBillPaymentMode.upi;
  String stage = 'edit', error = '', submissionId = PropertyBillRepository.newPaymentSubmissionId();
  bool busy = false, attempted = false; int? reviewedBalance, paidAmount; PropertyBillRecord? success;
  @override void initState() { super.initState(); amount.addListener(_changed); reference.addListener(_changed); notes.addListener(_changed); }
  void _changed() { if (!mounted) return; setState(() { if (attempted) { submissionId = PropertyBillRepository.newPaymentSubmissionId(); attempted = false; } stage = 'edit'; error = ''; }); }
  @override void dispose() { amount.dispose(); reference.dispose(); notes.dispose(); super.dispose(); }
  void _changeIntent(VoidCallback update) => setState(() { if (attempted) { submissionId = PropertyBillRepository.newPaymentSubmissionId(); attempted = false; } update(); stage = 'edit'; error = ''; });
  Future<void> _pick() async { final value = await showDatePicker(context: context, initialDate: DateTime(date.year, date.month, date.day), firstDate: DateTime(2000), lastDate: DateTime(2100)); if (value != null) _changeIntent(() => date = DateTime.utc(value.year, value.month, value.day)); }
  Future<void> _review() async {
    final value = _paise(amount.text); if (value == null) return;
    setState(() { busy = true; error = ''; });
    try { final latest = await repository.getBill(widget.account.workspaceId, widget.bill.id); if (latest == null) throw StateError('Bill is no longer available.');
      final previousBalance = current.data['balancePaise'] as int;
      if (!mounted) return; setState(() { current = latest; if (latest.data['balancePaise'] != previousBalance || value > (latest.data['balancePaise'] as int)) { error = 'Balance changed on another device. Review the latest amount again.'; stage = 'edit'; } else { reviewedBalance = latest.data['balancePaise'] as int; stage = 'confirm'; } });
    } catch (cause) { if (mounted) setState(() => error = cause.toString()); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> _submit() async {
    if (busy) return; final value = _paise(amount.text); if (value == null) return;
    setState(() { busy = true; error = ''; });
    try {
      final previous = attempted ? await repository.getBillPayment(widget.account.workspaceId, submissionId) : null;
      if (previous == null) {
        final latest = await repository.getBill(widget.account.workspaceId, widget.bill.id);
        if (latest == null) throw StateError('Bill is no longer available.');
        if (latest.data['balancePaise'] != reviewedBalance || value > (latest.data['balancePaise'] as int)) {
          if (mounted) setState(() { current = latest; stage = 'edit'; error = 'Balance changed on another device. Review the latest amount again.'; });
          return;
        }
      }
      attempted = true;
      await repository.recordBillPayment(PropertyBillPaymentSubmission(workspaceId: widget.account.workspaceId, billId: widget.bill.id, submissionId: submissionId, amountPaise: value, paymentDate: _indiaInstant(date), paymentMode: mode, referenceNumber: reference.text, notes: notes.text));
      final latest = await repository.getBill(widget.account.workspaceId, widget.bill.id);
      if (latest == null) throw StateError('Payment recorded, but bill reload failed. Retry with the same submission ID.');
      if (mounted) setState(() { success = latest; paidAmount = value; stage = 'success'; });
    } catch (cause) {
      final message = cause.toString();
      if (message.contains('Payment exceeds the outstanding balance') || message.contains('Bill totals or status are inconsistent')) {
        PropertyBillRecord? latest;
        try { latest = await repository.getBill(widget.account.workspaceId, widget.bill.id); } catch (_) { /* Keep the reviewed snapshot until reconnect. */ }
        if (mounted) setState(() { if (latest != null) current = latest!; stage = 'edit'; error = 'Balance changed on another device. Review the latest bill and amount again.'; });
      } else if (mounted) setState(() { error = '$message Retry with the same submission ID if uncertain.'; });
    }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) {
    final balance = current.data['balancePaise'] as int; final value = _paise(amount.text); final valid = value != null && value <= balance;
    return PopScope(canPop: !busy, child: SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92), child: SingleChildScrollView(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [Expanded(child: Text(stage == 'success' ? 'Payment Recorded' : stage == 'confirm' ? 'Confirm Bill Payment' : 'Record Bill Payment', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))), IconButton(onPressed: busy ? null : () => Navigator.pop(context), icon: const Icon(Icons.close))]),
      const SizedBox(height: 12), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${_type(current.data['billType'] as String)} · ${current.data['providerName']}', style: const TextStyle(fontWeight: FontWeight.w700)), Text('${widget.propertyName} · ${widget.unitName}', style: const TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 8), Text('Current balance ${formatInr((success ?? current).data['balancePaise'] as int)}')])),
      if (stage == 'edit') ...[const SizedBox(height: 16), CreovyTextField(label: 'Amount paying (₹)', controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), errorText: amount.text.isNotEmpty && !valid ? 'Enter a positive amount up to the balance.' : null), Align(alignment: Alignment.centerRight, child: TextButton(onPressed: balance > 0 ? () => amount.text = _amountText(balance) : null, child: const Text('Use full balance'))), ListTile(contentPadding: EdgeInsets.zero, title: const Text('Payment date'), subtitle: Text(_date(_indiaInstant(date))), trailing: const Icon(Icons.calendar_today_outlined), onTap: _pick), DropdownButtonFormField<PropertyBillPaymentMode>(value: mode, decoration: const InputDecoration(labelText: 'Payment mode'), items: PropertyBillPaymentMode.values.map((item) => DropdownMenuItem(value: item, child: Text(_mode(item.firestoreValue)))).toList(), onChanged: (item) { if (item != null && item != mode) _changeIntent(() => mode = item); }), const SizedBox(height: 12), CreovyTextField(label: 'Reference number', controller: reference), const SizedBox(height: 12), CreovyTextField(label: 'Notes', controller: notes), const SizedBox(height: 12), SurfaceCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Balance after payment'), Text(valid ? formatInr(balance - value) : '—', style: const TextStyle(fontWeight: FontWeight.w700, color: CreovyColors.brand))])), if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: error, tone: CreovyColors.danger)), const SizedBox(height: 16), SizedBox(width: double.infinity, child: CreovyButton(label: 'Review Payment', icon: Icons.arrow_forward, loading: busy, onPressed: valid ? _review : null))],
      if (stage == 'confirm') ...[const SizedBox(height: 16), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Bill: ${_type(current.data['billType'] as String)} · ${current.data['providerName']}'), Text('Property / Unit: ${widget.propertyName} · ${widget.unitName}'), Text('Amount paying: ${formatInr(value)}', style: const TextStyle(fontWeight: FontWeight.w700)), Text('Current balance: ${formatInr(reviewedBalance)}'), Text('Balance after payment: ${formatInr((reviewedBalance ?? balance) - (value ?? 0))}'), Text('Mode: ${_mode(mode.firestoreValue)}'), Text('Payment date: ${_date(_indiaInstant(date))}')])), if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: FeedbackAlert(message: error, tone: CreovyColors.danger)), const SizedBox(height: 16), Row(children: [Expanded(child: CreovyButton(label: 'Back', icon: Icons.arrow_back, variant: CreovyButtonVariant.outline, onPressed: busy ? null : () => setState(() => stage = 'edit'))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: attempted ? 'Retry Payment' : 'Confirm Payment', icon: Icons.check, loading: busy, onPressed: valid && reviewedBalance == balance ? _submit : null))])],
      if (stage == 'success' && success != null) ...[const SizedBox(height: 16), FeedbackAlert(message: 'Payment Recorded · ${formatInr(paidAmount)}', tone: CreovyColors.success), const SizedBox(height: 12), SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Total paid ${formatInr(success!.data['totalPaidPaise'] as int)}'), Text('Remaining balance ${formatInr(success!.data['balancePaise'] as int)}'), const SizedBox(height: 8), StatusChip(label: _status(success!))])), const SizedBox(height: 16), Row(children: [Expanded(child: CreovyButton(label: 'Done', icon: Icons.check, variant: CreovyButtonVariant.outline, onPressed: () => Navigator.pop(context))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: 'View Bill', icon: Icons.receipt_long_outlined, onPressed: () => Navigator.pop(context)))])],
    ]))))));
  }
}
