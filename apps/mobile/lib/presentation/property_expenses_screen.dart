import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../data/account_resolver.dart';
import '../data/property_expense_repository.dart';
import '../data/property_repository.dart';
import 'design_system.dart';

const _indiaOffset = Duration(hours: 5, minutes: 30);
DateTime _indiaDay(DateTime value) { final day = value.toUtc().add(_indiaOffset); return DateTime.utc(day.year, day.month, day.day); }
String _date(DateTime value) { final day = _indiaDay(value); return '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}'; }
String _createdAt(DateTime value) { final local = value.toUtc().add(_indiaOffset); return '${_date(value)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')} IST'; }
String _category(String value) => switch (value) { 'common_area' => 'Common Area', 'labour' => 'Service / Labour', _ => value.split('_').map((item) => '${item[0].toUpperCase()}${item.substring(1)}').join(' ') };
String _mode(String value) => switch (value) { 'upi' => 'UPI', 'bank_transfer' => 'Bank Transfer', 'cash' => 'Cash', 'cheque' => 'Cheque', _ => 'Other' };
int? _paise(String raw) {
  final value = raw.trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.'); final whole = int.tryParse(parts.first);
  if (whole == null || whole > 90071992547409) return null;
  final amount = whole * 100 + (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
  return amount > 0 && amount <= 9007199254740991 ? amount : null;
}
bool _canWrite(AccountContext account) => const ['owner', 'manager', 'accountant'].contains(account.role);

class PropertyExpensesScreen extends StatefulWidget {
  const PropertyExpensesScreen({super.key, required this.account, this.initialPropertyId, this.initialUnitId, this.openAdd = false});
  final AccountContext account;
  final String? initialPropertyId, initialUnitId;
  final bool openAdd;
  @override State<PropertyExpensesScreen> createState() => _PropertyExpensesScreenState();
}
class _PropertyExpensesScreenState extends State<PropertyExpensesScreen> {
  late final expenseRepository = PropertyExpenseRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late final propertyRepository = PropertyRepository(FirebaseFirestore.instance);
  final search = TextEditingController();
  List<PropertyExpenseRecord>? expenses;
  List<PropertyRecord>? properties;
  List<UnitRecord>? units;
  String? error;
  bool loading = true;
  bool _initialAddOpened = false;
  late String propertyFilter = widget.initialPropertyId ?? 'all';
  late String unitFilter = widget.initialUnitId ?? 'all';
  String categoryFilter = 'all', modeFilter = 'all';
  DateTimeRange? dateRange;
  @override void initState() { super.initState(); _load(); }
  @override void dispose() { search.dispose(); super.dispose(); }
  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final props = await propertyRepository.watchProperties(widget.account.workspaceId).first;
      final unitItems = await propertyRepository.watchAllUnits(widget.account.workspaceId).first;
      final items = await expenseRepository.listExpenses(widget.account.workspaceId);
      if (mounted) setState(() { properties = props; units = unitItems; expenses = items; loading = false; });
      if (mounted && widget.openAdd && !_initialAddOpened) { _initialAddOpened = true; WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _add(); }); }
    } catch (cause) { if (mounted) setState(() { error = '$cause'; loading = false; }); }
  }
  String _property(String id) => properties?.where((item) => item.id == id).firstOrNull?.data['name'] as String? ?? 'Property';
  String _unit(String? id) => id == null ? 'Property level' : units?.where((item) => item.id == id).firstOrNull?.data['name'] as String? ?? 'Unit';
  Future<void> _add() async {
    if (!_canWrite(widget.account)) return;
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => _ExpenseEditorScreen(account: widget.account,
      properties: properties ?? [], units: units ?? [], initialPropertyId: propertyFilter == 'all' ? null : propertyFilter)));
    if (mounted) await _load();
  }
  void _clear() => setState(() { search.clear(); propertyFilter = 'all'; unitFilter = 'all'; categoryFilter = 'all'; modeFilter = 'all'; dateRange = null; });
  @override Widget build(BuildContext context) {
    final all = expenses ?? [];
    final month = _indiaDay(DateTime.now());
    final total = all.fold<int>(0, (sum, item) => sum + (item.data['amountPaise'] as int));
    final thisMonth = all.where((item) { final day = _indiaDay((item.data['expenseDate'] as Timestamp).toDate()); return day.year == month.year && day.month == month.month; })
      .fold<int>(0, (sum, item) => sum + (item.data['amountPaise'] as int));
    final categoryAmounts = <String, int>{};
    for (final item in all) { final key = item.data['category'] as String; categoryAmounts[key] = (categoryAmounts[key] ?? 0) + (item.data['amountPaise'] as int); }
    final top = categoryAmounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final filtered = all.where((item) {
      final data = item.data;
      final day = _indiaDay((data['expenseDate'] as Timestamp).toDate());
      final name = '${data['title']} ${data['vendorName']} ${data['referenceNumber']} ${_property(data['propertyId'] as String)} ${_unit(data['unitId'] as String?)}'.toLowerCase();
      final first = dateRange == null ? null : DateTime.utc(dateRange!.start.year, dateRange!.start.month, dateRange!.start.day);
      final last = dateRange == null ? null : DateTime.utc(dateRange!.end.year, dateRange!.end.month, dateRange!.end.day);
      return name.contains(search.text.trim().toLowerCase()) && (propertyFilter == 'all' || data['propertyId'] == propertyFilter) &&
        (unitFilter == 'all' || data['unitId'] == unitFilter) && (categoryFilter == 'all' || data['category'] == categoryFilter) &&
        (modeFilter == 'all' || data['paymentMode'] == modeFilter) &&
        (first == null || (!day.isBefore(first) && !day.isAfter(last!)));
    }).toList();
    final hasFilters = search.text.isNotEmpty || propertyFilter != 'all' || unitFilter != 'all' || categoryFilter != 'all' || modeFilter != 'all' || dateRange != null;
    return Scaffold(appBar: AppBar(title: const Text('Expenses'), actions: [IconButton(tooltip: 'Refresh expenses', onPressed: _load, icon: const Icon(Icons.refresh_rounded))]),
      body: loading ? const Padding(padding: EdgeInsets.all(20), child: Column(children: [Skeleton(height: 80), SizedBox(height: 12), Skeleton(height: 80), SizedBox(height: 12), Skeleton(height: 110)])) :
      error != null ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [const EmptyState(title: 'Expenses unavailable', body: 'Check your connection and retry.'), const SizedBox(height: 12), CreovyButton(label: 'Retry', icon: Icons.refresh, onPressed: _load)]))) :
      RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(20, 14, 20, 32), children: [
        const Text('Owner spending, clearly separated from rent and deposits.', style: TextStyle(color: CreovyColors.secondary)),
        const SizedBox(height: 18), Wrap(spacing: 9, runSpacing: 9, children: [
          _ExpenseMetric('Total Expenses', formatInr(total)), _ExpenseMetric('This Month', formatInr(thisMonth)),
          _ExpenseMetric('Transactions', '${all.length}'), _ExpenseMetric('Top Category', top.isEmpty ? '—' : _category(top.first.key)),
        ]), const SizedBox(height: 18), if (_canWrite(widget.account)) SizedBox(width: double.infinity,
          child: CreovyButton(label: 'Add Expense', icon: Icons.add, onPressed: _add)),
        const SizedBox(height: 18), TextField(controller: search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search title, vendor, reference…')),
        const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: [
          SizedBox(width: 178, child: DropdownButtonFormField<String>(value: propertyFilter, isExpanded: true, decoration: const InputDecoration(labelText: 'Property'), items: [const DropdownMenuItem(value: 'all', child: Text('All properties')), ...?properties?.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Property', overflow: TextOverflow.ellipsis)))], onChanged: (value) => setState(() { propertyFilter = value ?? 'all'; unitFilter = 'all'; }))),
          SizedBox(width: 150, child: DropdownButtonFormField<String>(value: unitFilter, isExpanded: true, decoration: const InputDecoration(labelText: 'Unit'), items: [const DropdownMenuItem(value: 'all', child: Text('All units')), ...?units?.where((item) => propertyFilter == 'all' || item.data['propertyId'] == propertyFilter).map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Unit', overflow: TextOverflow.ellipsis)))], onChanged: (value) => setState(() => unitFilter = value ?? 'all'))),
          SizedBox(width: 160, child: DropdownButtonFormField<String>(value: categoryFilter, isExpanded: true, decoration: const InputDecoration(labelText: 'Category'), items: [const DropdownMenuItem(value: 'all', child: Text('All categories')), ...PropertyExpenseCategory.values.map((item) => DropdownMenuItem(value: item.firestoreValue, child: Text(_category(item.firestoreValue))))], onChanged: (value) => setState(() => categoryFilter = value ?? 'all'))),
          SizedBox(width: 160, child: DropdownButtonFormField<String>(value: modeFilter, isExpanded: true, decoration: const InputDecoration(labelText: 'Payment Mode'), items: [const DropdownMenuItem(value: 'all', child: Text('All modes')), ...PropertyExpensePaymentMode.values.map((item) => DropdownMenuItem(value: item.firestoreValue, child: Text(_mode(item.firestoreValue))))], onChanged: (value) => setState(() => modeFilter = value ?? 'all'))),
          OutlinedButton.icon(onPressed: () async { final range = await showDateRangePicker(context: context, firstDate: DateTime(2000), lastDate: DateTime(2100), initialDateRange: dateRange); if (range != null) setState(() => dateRange = range); }, icon: const Icon(Icons.date_range_outlined), label: Text(dateRange == null ? 'Date range' : '${dateRange!.start.day.toString().padLeft(2, '0')}/${dateRange!.start.month.toString().padLeft(2, '0')}/${dateRange!.start.year} – ${dateRange!.end.day.toString().padLeft(2, '0')}/${dateRange!.end.month.toString().padLeft(2, '0')}/${dateRange!.end.year}')),
          if (hasFilters) TextButton(onPressed: _clear, child: const Text('Clear filters')),
        ]), const SizedBox(height: 20),
        if (filtered.isEmpty) Column(children: [EmptyState(title: all.isEmpty ? 'No expenses recorded yet' : 'No expenses match these filters', body: all.isEmpty ? 'Record your first owner expense to begin a reliable history.' : 'Try another search or filter.'), const SizedBox(height: 12), if (hasFilters) CreovyButton(label: 'Clear Filters', variant: CreovyButtonVariant.outline, onPressed: _clear) else if (_canWrite(widget.account)) CreovyButton(label: 'Add Expense', onPressed: _add)])
        else ...filtered.map((item) => Padding(padding: const EdgeInsets.only(bottom: 10), child: SurfaceCard(padding: EdgeInsets.zero, child: InkWell(borderRadius: BorderRadius.circular(18), onTap: () async { await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => PropertyExpenseDetailScreen(account: widget.account, expenseId: item.id, propertyName: _property(item.data['propertyId'] as String), unitName: _unit(item.data['unitId'] as String?)))); if (mounted) await _load(); }, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Expanded(child: Text(_category(item.data['category'] as String), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CreovyColors.brand))), Text(formatInr(item.data['amountPaise'] as int), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))]), const SizedBox(height: 5), Text(item.data['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const SizedBox(height: 5), Text('${_property(item.data['propertyId'] as String)} · ${_unit(item.data['unitId'] as String?)}', style: const TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 10), Text('${_date((item.data['expenseDate'] as Timestamp).toDate())} · ${_mode(item.data['paymentMode'] as String)} · ${(item.data['vendorName'] as String).isEmpty ? 'No vendor' : item.data['vendorName']}${(item.data['referenceNumber'] as String).isEmpty ? '' : ' · ${item.data['referenceNumber']}'}', style: const TextStyle(fontSize: 12, color: CreovyColors.secondary))])))))),
      ])));
  }
}
class _ExpenseMetric extends StatelessWidget { const _ExpenseMetric(this.label, this.value); final String label, value; @override Widget build(BuildContext context) => SizedBox(width: 150, child: SurfaceCard(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 11, color: CreovyColors.secondary)), const SizedBox(height: 7), Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))]))); }

class _ExpenseEditorScreen extends StatefulWidget {
  const _ExpenseEditorScreen({required this.account, required this.properties, required this.units, this.initialPropertyId});
  final AccountContext account;
  final List<PropertyRecord> properties;
  final List<UnitRecord> units;
  final String? initialPropertyId;
  @override State<_ExpenseEditorScreen> createState() => _ExpenseEditorScreenState();
}
class _ExpenseEditorScreenState extends State<_ExpenseEditorScreen> {
  late final repository = PropertyExpenseRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  final title = TextEditingController(), vendor = TextEditingController(), amount = TextEditingController(), reference = TextEditingController(), notes = TextEditingController();
  late String propertyId = widget.initialPropertyId ?? '';
  String unitId = '';
  PropertyExpenseCategory category = PropertyExpenseCategory.maintenance;
  PropertyExpensePaymentMode paymentMode = PropertyExpensePaymentMode.cash;
  DateTime expenseDate = DateTime.now();
  String submissionId = PropertyExpenseRepository.newExpenseSubmissionId();
  bool attempted = false, busy = false, inFlight = false;
  String stage = 'form';
  String? error;
  PropertyExpenseRecord? result;
  @override void dispose() { title.dispose(); vendor.dispose(); amount.dispose(); reference.dispose(); notes.dispose(); super.dispose(); }
  void _changed({bool financial = false}) { if (attempted && financial) { submissionId = PropertyExpenseRepository.newExpenseSubmissionId(); attempted = false; } setState(() { stage = 'form'; error = null; }); }
  String get propertyName => widget.properties.where((item) => item.id == propertyId).firstOrNull?.data['name'] as String? ?? 'Property';
  String get unitName => unitId.isEmpty ? 'Property level' : widget.units.where((item) => item.id == unitId).firstOrNull?.data['name'] as String? ?? 'Unit';
  void _review() {
    if (propertyId.isEmpty || unitId.isNotEmpty && !widget.units.any((item) => item.id == unitId && item.data['propertyId'] == propertyId) ||
        title.text.trim().isEmpty || title.text.trim().length > 200 || vendor.text.trim().length > 200 ||
        reference.text.trim().length > 200 || notes.text.trim().length > 2000 || _paise(amount.text) == null) {
      setState(() => error = 'Check property, unit, title, positive amount and field lengths.'); return;
    }
    setState(() { error = null; stage = 'review'; });
  }
  Future<void> _submit() async {
    if (inFlight || _paise(amount.text) == null) return;
    inFlight = true; setState(() { busy = true; error = null; });
    try {
      final input = PropertyExpenseSubmission(workspaceId: widget.account.workspaceId, submissionId: submissionId,
        propertyId: propertyId, unitId: unitId.isEmpty ? null : unitId, category: category, title: title.text,
        vendorName: vendor.text, amountPaise: _paise(amount.text)!, expenseDate: expenseDate,
        paymentMode: paymentMode, referenceNumber: reference.text, notes: notes.text);
      attempted = true;
      final saved = await repository.createExpense(input);
      if (mounted) setState(() { result = saved; stage = 'success'; });
    } catch (cause) { if (mounted) setState(() => error = '$cause Retry with the same submission ID if uncertain.'); }
    finally { inFlight = false; if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(stage == 'success' ? 'Expense Recorded' : stage == 'review' ? 'Review Expense' : 'Add Expense')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: ListView(padding: const EdgeInsets.all(20), children: [
      if (stage == 'form') ...[
        const Text('Record one actual owner expense.', style: TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 18),
        DropdownButtonFormField<String>(value: propertyId, decoration: const InputDecoration(labelText: 'Property *'), items: [const DropdownMenuItem(value: '', child: Text('Select property')), ...widget.properties.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Property')))], onChanged: (value) { propertyId = value ?? ''; unitId = ''; _changed(financial: true); }), const SizedBox(height: 12),
        DropdownButtonFormField<String>(value: unitId, decoration: const InputDecoration(labelText: 'Unit (optional)'), items: [const DropdownMenuItem(value: '', child: Text('Property level')), ...widget.units.where((item) => item.data['propertyId'] == propertyId).map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Unit')))], onChanged: (value) { unitId = value ?? ''; _changed(financial: true); }), const SizedBox(height: 12),
        DropdownButtonFormField<PropertyExpenseCategory>(value: category, decoration: const InputDecoration(labelText: 'Category'), items: PropertyExpenseCategory.values.map((item) => DropdownMenuItem(value: item, child: Text(_category(item.firestoreValue)))).toList(), onChanged: (value) { category = value ?? category; _changed(financial: true); }), const SizedBox(height: 12),
        TextField(controller: title, maxLength: 200, onChanged: (_) => _changed(), decoration: const InputDecoration(labelText: 'Title *')), const SizedBox(height: 8),
        TextField(controller: vendor, maxLength: 200, onChanged: (_) => _changed(), decoration: const InputDecoration(labelText: 'Vendor Name')), const SizedBox(height: 8),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => _changed(financial: true), decoration: const InputDecoration(labelText: 'Amount (₹) *')), const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: () async { final selected = _indiaDay(expenseDate); final day = await showDatePicker(context: context, initialDate: DateTime(selected.year, selected.month, selected.day), firstDate: DateTime(2000), lastDate: DateTime(2100)); if (day != null) { expenseDate = DateTime.utc(day.year, day.month, day.day).subtract(_indiaOffset); _changed(financial: true); } }, icon: const Icon(Icons.event_outlined), label: Text('Expense Date  ${_date(expenseDate)}')), const SizedBox(height: 12),
        DropdownButtonFormField<PropertyExpensePaymentMode>(value: paymentMode, decoration: const InputDecoration(labelText: 'Payment Mode'), items: PropertyExpensePaymentMode.values.map((item) => DropdownMenuItem(value: item, child: Text(_mode(item.firestoreValue)))).toList(), onChanged: (value) { paymentMode = value ?? paymentMode; _changed(financial: true); }), const SizedBox(height: 12),
        TextField(controller: reference, maxLength: 200, onChanged: (_) => _changed(financial: true), decoration: const InputDecoration(labelText: 'Reference Number')), const SizedBox(height: 8),
        TextField(controller: notes, maxLength: 2000, maxLines: 3, onChanged: (_) => _changed(), decoration: const InputDecoration(labelText: 'Notes')), const SizedBox(height: 12),
        if (error != null) Text(error!, style: const TextStyle(color: CreovyColors.danger)), const SizedBox(height: 12),
        CreovyButton(label: 'Review Expense', onPressed: _review),
      ] else if (stage == 'review') ...[
        const Text('No expense is recorded until you confirm.', style: TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 18),
        SurfaceCard(child: Column(children: [
          _detailRow('Property', propertyName), _detailRow('Unit', unitName), _detailRow('Category', _category(category.firestoreValue)),
          _detailRow('Title', title.text.trim()), _detailRow('Vendor', vendor.text.trim().isEmpty ? '—' : vendor.text.trim()),
          _detailRow('Amount', formatInr(_paise(amount.text) ?? 0)), _detailRow('Expense Date', _date(expenseDate)),
          _detailRow('Payment Mode', _mode(paymentMode.firestoreValue)), _detailRow('Reference', reference.text.trim().isEmpty ? '—' : reference.text.trim()),
        ])), const SizedBox(height: 16), if (error != null) Text(error!, style: const TextStyle(color: CreovyColors.danger)),
        Row(children: [Expanded(child: CreovyButton(label: 'Back', variant: CreovyButtonVariant.outline, onPressed: busy ? null : () => setState(() => stage = 'form'))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: attempted ? 'Retry Same Expense' : 'Confirm Expense', loading: busy, onPressed: busy ? null : _submit))]),
      ] else if (result != null) ...[
        SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Expense Recorded', style: TextStyle(color: CreovyColors.success, fontWeight: FontWeight.w700)), const SizedBox(height: 10), Text(formatInr(result!.data['amountPaise'] as int), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)), const SizedBox(height: 6), Text('$propertyName · $unitName'), const SizedBox(height: 8), Text('${_category(result!.data['category'] as String)} · ${_date((result!.data['expenseDate'] as Timestamp).toDate())}', style: const TextStyle(color: CreovyColors.secondary))])), const SizedBox(height: 20),
        Row(children: [Expanded(child: CreovyButton(label: 'Done', variant: CreovyButtonVariant.outline, onPressed: () => Navigator.pop(context))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: 'View Expense', onPressed: () async { await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => PropertyExpenseDetailScreen(account: widget.account, expenseId: result!.id, propertyName: propertyName, unitName: unitName))); if (context.mounted) Navigator.pop(context); }))]),
      ],
    ]))));
}

Widget _detailRow(String label, String value) => Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Text(label, style: const TextStyle(color: CreovyColors.secondary))), const SizedBox(width: 12), Expanded(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)))]));

class PropertyExpenseDetailScreen extends StatefulWidget {
  const PropertyExpenseDetailScreen({super.key, required this.account, required this.expenseId, required this.propertyName, required this.unitName});
  final AccountContext account;
  final String expenseId, propertyName, unitName;
  @override State<PropertyExpenseDetailScreen> createState() => _PropertyExpenseDetailScreenState();
}
class _PropertyExpenseDetailScreenState extends State<PropertyExpenseDetailScreen> {
  late final repository = PropertyExpenseRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  PropertyExpenseRecord? expense;
  String? error;
  bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { setState(() { loading = true; error = null; }); try { final item = await repository.getExpense(widget.account.workspaceId, widget.expenseId); if (mounted) setState(() { expense = item; loading = false; }); } catch (cause) { if (mounted) setState(() { error = '$cause'; loading = false; }); } }
  Future<void> _edit() async { if (expense == null) return; await showModalBottomSheet<void>(context: context, isScrollControlled: true, backgroundColor: CreovyColors.surface, builder: (_) => _SafeExpenseEditSheet(repository: repository, expense: expense!)); if (mounted) await _load(); }
  @override Widget build(BuildContext context) {
    final item = expense;
    return Scaffold(appBar: AppBar(title: const Text('Expense Detail')), body: loading ? const Padding(padding: EdgeInsets.all(20), child: Column(children: [Skeleton(height: 90), SizedBox(height: 12), Skeleton(height: 150)])) :
      error != null || item == null ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [EmptyState(title: 'Expense unavailable', body: error ?? 'This expense could not be found.'), const SizedBox(height: 12), CreovyButton(label: 'Retry', icon: Icons.refresh, onPressed: _load)])) :
      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: ListView(padding: const EdgeInsets.all(20), children: [
        Text(_category(item.data['category'] as String), style: const TextStyle(color: CreovyColors.brand, fontWeight: FontWeight.w700)), const SizedBox(height: 6), Text(item.data['title'] as String, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)), const SizedBox(height: 5), Text('${widget.propertyName} · ${widget.unitName}', style: const TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 18),
        SurfaceCard(child: Column(children: [_detailRow('Amount', formatInr(item.data['amountPaise'] as int)), _detailRow('Expense Date', _date((item.data['expenseDate'] as Timestamp).toDate())), _detailRow('Vendor', (item.data['vendorName'] as String).isEmpty ? '—' : item.data['vendorName'] as String), _detailRow('Payment Mode', _mode(item.data['paymentMode'] as String)), _detailRow('Reference', (item.data['referenceNumber'] as String).isEmpty ? '—' : item.data['referenceNumber'] as String), _detailRow('Recorded By', item.data['createdBy'] as String), _detailRow('Created At', _createdAt((item.data['createdAt'] as Timestamp).toDate()))])), const SizedBox(height: 16),
        SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Notes', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8), Text((item.data['notes'] as String).isEmpty ? 'No notes' : item.data['notes'] as String)])),
        if (_canWrite(widget.account)) ...[const SizedBox(height: 18), CreovyButton(label: 'Edit Safe Details', icon: Icons.edit_outlined, variant: CreovyButtonVariant.outline, onPressed: _edit)],
      ]))));
  }
}

class _SafeExpenseEditSheet extends StatefulWidget { const _SafeExpenseEditSheet({required this.repository, required this.expense}); final PropertyExpenseRepository repository; final PropertyExpenseRecord expense; @override State<_SafeExpenseEditSheet> createState() => _SafeExpenseEditSheetState(); }
class _SafeExpenseEditSheetState extends State<_SafeExpenseEditSheet> {
  late final title = TextEditingController(text: widget.expense.data['title'] as String);
  late final vendor = TextEditingController(text: widget.expense.data['vendorName'] as String);
  late final notes = TextEditingController(text: widget.expense.data['notes'] as String);
  bool confirm = false, busy = false;
  String? error;
  @override void dispose() { title.dispose(); vendor.dispose(); notes.dispose(); super.dispose(); }
  Future<void> _save() async {
    setState(() { busy = true; error = null; });
    try { await widget.repository.updateSafeExpenseMetadata(widget.expense.data['workspaceId'] as String, widget.expense.id,
      SafePropertyExpenseMetadata(title: title.text, vendorName: vendor.text, notes: notes.text)); if (mounted) Navigator.pop(context); }
    catch (cause) { if (mounted) setState(() => error = '$cause'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.viewInsetsOf(context).bottom + 20), child: SingleChildScrollView(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Edit Safe Details', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)), const SizedBox(height: 8), const Text('Amount, property, date and payment identity remain locked.', style: TextStyle(color: CreovyColors.secondary)), const SizedBox(height: 18),
    if (!confirm) ...[TextField(controller: title, maxLength: 200, decoration: const InputDecoration(labelText: 'Title *')), const SizedBox(height: 8), TextField(controller: vendor, maxLength: 200, decoration: const InputDecoration(labelText: 'Vendor Name')), const SizedBox(height: 8), TextField(controller: notes, maxLength: 2000, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')), const SizedBox(height: 12), CreovyButton(label: 'Review Changes', onPressed: () { if (title.text.trim().isNotEmpty) setState(() => confirm = true); })]
    else ...[SurfaceCard(child: Column(children: [_detailRow('Title', title.text.trim()), _detailRow('Vendor', vendor.text.trim().isEmpty ? '—' : vendor.text.trim()), _detailRow('Notes', notes.text.trim().isEmpty ? '—' : notes.text.trim())])), const SizedBox(height: 12), Row(children: [Expanded(child: CreovyButton(label: 'Back', variant: CreovyButtonVariant.outline, onPressed: busy ? null : () => setState(() => confirm = false))), const SizedBox(width: 10), Expanded(child: CreovyButton(label: 'Save Changes', loading: busy, onPressed: busy ? null : _save))])],
    if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: CreovyColors.danger))),
  ]))))));
}
