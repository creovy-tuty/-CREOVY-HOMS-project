import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../data/account_resolver.dart';
import '../data/property_repository.dart';
import '../data/report_repository.dart';
import '../data/tenant_repository.dart';
import '../domain/report_models.dart';
import 'agreement_screens.dart';
import 'design_system.dart';
import 'properties_screen.dart';
import 'report_pdf.dart';

const _indiaOffset = Duration(hours: 5, minutes: 30);
DateTime _indiaDay(DateTime value) { final local = value.toUtc().add(_indiaOffset); return DateTime.utc(local.year, local.month, local.day); }
DateTime _indiaMidnight(DateTime value) => _indiaDay(value).subtract(_indiaOffset);
String _date(DateTime value) { final day = _indiaDay(value); return '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}'; }
String _human(String value) => value.split('_').map((part) => part.isEmpty ? part : '${part[0].toUpperCase()}${part.substring(1)}').join(' ');
String _error(Object cause) { final message = '$cause'; return message.contains('client reporting limit') ? 'This report is too large for on-device reporting. Narrow the date range or property filter.' : message; }
ReportFilters _initialFilters() { final today = _indiaDay(DateTime.now()); return ReportFilters(from: _indiaMidnight(DateTime.utc(today.year, today.month)), through: _indiaMidnight(today)); }

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.account});
  final AccountContext account;
  @override State<ReportsScreen> createState() => _ReportsScreenState();
}
class _ReportsScreenState extends State<ReportsScreen> {
  late final reports = ReportRepository(FirebaseFirestore.instance, FirebaseAuth.instance);
  late final propertyRepository = PropertyRepository(FirebaseFirestore.instance);
  late final tenantRepository = TenantRepository(FirebaseFirestore.instance);
  late ReportFilters filters = _initialFilters();
  String? rentStatus;
  List<PropertyRecord> properties = [];
  List<UnitRecord> units = [];
  PortfolioSummary? summary;
  RentReport? rent;
  List<ReportRentRow> rentRows = [];
  List<PropertyPerformanceRow> performance = [];
  List<MonthlyCashFlowRow> trend = [];
  String? error;
  bool loading = true;
  bool _exportBusy = false;
  int _loadVersion = 0;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final version = ++_loadVersion;
    setState(() { loading = true; error = null; summary = null; });
    try {
      final contextRows = await Future.wait<Object>([
        propertyRepository.watchProperties(widget.account.workspaceId).first,
        propertyRepository.watchAllUnits(widget.account.workspaceId).first,
      ]);
      final result = await Future.wait<Object>([
        reports.getPortfolioSummary(widget.account.workspaceId, filters: filters),
        reports.getRentReport(widget.account.workspaceId, filters: ReportFilters(from: filters.from, through: filters.through,
          propertyId: filters.propertyId, unitId: filters.unitId, rentStatus: rentStatus)),
        reports.getRentBreakdown(widget.account.workspaceId, filters: ReportFilters(from: filters.from, through: filters.through,
          propertyId: filters.propertyId, unitId: filters.unitId, rentStatus: rentStatus)),
        reports.getPropertyPerformance(widget.account.workspaceId, filters: filters),
        reports.getMonthlyCashFlowTrend(widget.account.workspaceId, filters: filters),
      ]);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        properties = contextRows[0] as List<PropertyRecord>; units = contextRows[1] as List<UnitRecord>;
        summary = result[0] as PortfolioSummary; rent = result[1] as RentReport;
        rentRows = result[2] as List<ReportRentRow>; performance = result[3] as List<PropertyPerformanceRow>;
        trend = result[4] as List<MonthlyCashFlowRow>; loading = false;
      });
    } catch (cause) { if (mounted && version == _loadVersion) setState(() { error = _error(cause); loading = false; }); }
  }
  Future<void> _filters() async {
    var from = filters.from ?? _initialFilters().from!;
    var through = filters.through ?? _initialFilters().through!;
    String? propertyId = filters.propertyId, unitId = filters.unitId;
    String? status = rentStatus;
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, backgroundColor: CreovyColors.canvas,
      builder: (sheetContext) => StatefulBuilder(builder: (sheetContext, change) {
        final visibleUnits = units.where((unit) => propertyId == null || unit.data['propertyId'] == propertyId).toList();
        Future<void> chooseDate(bool beginning) async {
          final current = _indiaDay(beginning ? from : through);
          final selected = await showDatePicker(context: sheetContext, initialDate: current, firstDate: DateTime(2000), lastDate: DateTime(2100), helpText: beginning ? 'From · DD/MM/YYYY' : 'Through · DD/MM/YYYY');
          if (selected != null) change(() { if (beginning) { from = _indiaMidnight(selected); } else { through = _indiaMidnight(selected); } });
        }
        return SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.viewInsetsOf(sheetContext).bottom + 24), child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Report filters', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: CreovyColors.ink)),
          const SizedBox(height: 4), const Text('Dates use Asia/Kolkata business days.', style: TextStyle(color: CreovyColors.secondary, fontSize: 13)),
          const SizedBox(height: 18),
          Row(children: [Expanded(child: OutlinedButton.icon(onPressed: () => chooseDate(true), icon: const Icon(Icons.event), label: Text('From  ${_date(from)}'))), const SizedBox(width: 8), Expanded(child: OutlinedButton.icon(onPressed: () => chooseDate(false), icon: const Icon(Icons.event), label: Text('Through  ${_date(through)}')))]),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(value: propertyId ?? '', isExpanded: true, decoration: const InputDecoration(labelText: 'Property'), items: [const DropdownMenuItem(value: '', child: Text('All properties')), ...properties.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Property', overflow: TextOverflow.ellipsis)))], onChanged: (value) => change(() { propertyId = value == '' ? null : value; unitId = null; })),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: unitId ?? '', isExpanded: true, decoration: const InputDecoration(labelText: 'Unit'), items: [const DropdownMenuItem(value: '', child: Text('All units')), ...visibleUnits.map((item) => DropdownMenuItem(value: item.id, child: Text(item.data['name'] as String? ?? 'Unit', overflow: TextOverflow.ellipsis)))], onChanged: (value) => change(() => unitId = value == '' ? null : value)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: status ?? '', isExpanded: true, decoration: const InputDecoration(labelText: 'Rent status · rent report only'), items: [const DropdownMenuItem(value: '', child: Text('All statuses')), ...['pending', 'partial', 'paid', 'overdue'].map((item) => DropdownMenuItem(value: item, child: Text(_human(item))))], onChanged: (value) => change(() => status = value == '' ? null : value)),
          const SizedBox(height: 20),
          Row(children: [Expanded(child: CreovyButton(label: 'Reset', icon: Icons.restart_alt, variant: CreovyButtonVariant.outline, onPressed: () { setState(() { filters = _initialFilters(); rentStatus = null; }); Navigator.pop(sheetContext); _load(); })), const SizedBox(width: 10), Expanded(child: CreovyButton(label: 'Apply', icon: Icons.check, onPressed: () { if (from.isAfter(through)) { ScaffoldMessenger.of(sheetContext).showSnackBar(const SnackBar(content: Text('From date must be on or before Through date.'))); return; } setState(() { filters = ReportFilters(from: from, through: through, propertyId: propertyId, unitId: unitId); rentStatus = status; }); Navigator.pop(sheetContext); _load(); }))]),
        ]))));
      }));
  }
  Future<void> _openProperty(String propertyId) async {
    PropertyRecord? selected;
    for (final property in properties) { if (property.id == propertyId) { selected = property; break; } }
    if (selected == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PropertyDetail(account: widget.account, property: selected!)));
  }
  Future<void> _openTenant(String tenantId) async {
    try {
      final tenants = await tenantRepository.watchTenants(widget.account.workspaceId).first;
      if (!mounted) return;
      final selected = tenants.where((item) => item.id == tenantId).firstOrNull;
      if (selected == null) throw StateError('Tenant no longer exists in this workspace.');
      await Navigator.push(context, MaterialPageRoute(builder: (_) => TenantDetailScreen(account: widget.account, tenant: selected)));
    } catch (cause) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error(cause)))); }
  }
  Future<void> _openAgreement(String agreementId) async {
    try {
      final agreements = await tenantRepository.watchAgreements(widget.account.workspaceId).first;
      if (!mounted) return;
      final selected = agreements.where((item) => item.id == agreementId).firstOrNull;
      if (selected == null) throw StateError('Agreement no longer exists in this workspace.');
      await Navigator.push(context, MaterialPageRoute(builder: (_) => AgreementDetailScreen(account: widget.account, agreement: selected)));
    } catch (cause) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error(cause)))); }
  }
  Future<void> _export(ReportExportKind kind, {bool share = false, TenantRentReport? history, bool agreementOnly = false}) async {
    if (_exportBusy || loading || error != null || summary == null || rent == null) return;
    final property = filters.propertyId == null ? null : properties.where((item) => item.id == filters.propertyId).firstOrNull;
    final unit = filters.unitId == null ? null : units.where((item) => item.id == filters.unitId).firstOrNull;
    if (filters.propertyId != null && property == null || filters.unitId != null && unit == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report context is incomplete. Reload before exporting.')));
      return;
    }
    final data = ReportPdfData(kind: kind, filters: filters,
      propertyName: property?.data['name'] as String? ?? 'All properties',
      unitName: unit?.data['name'] as String? ?? 'All units',
      propertyNames: {for (final item in properties) item.id: item.data['name'] as String? ?? 'Property'},
      unitNames: {for (final item in units) item.id: item.data['name'] as String? ?? 'Unit'},
      summary: summary!, rent: rent!, rentRows: rentRows, performance: performance, trend: trend,
      generatedAt: DateTime.now(), rentStatus: rentStatus, history: history, agreementHistory: agreementOnly);
    if (!data.hasData) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No records match this report scope. Adjust the filters before exporting.')));
      return;
    }
    setState(() => _exportBusy = true);
    try {
      final bytes = await createReportPdf(data);
      if (share) { await Printing.sharePdf(bytes: bytes, filename: data.fileName); }
      else { await Printing.layoutPdf(onLayout: (_) async => bytes, name: data.fileName); }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report PDF could not be prepared. Please retry.')));
    } finally { if (mounted) setState(() => _exportBusy = false); }
  }
  void _exportMenu() {
    if (_exportBusy || loading || error != null) return;
    showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true, builder: (sheetContext) => SafeArea(child: ListView(
      shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        const ListTile(title: Text('Export report'), subtitle: Text('Uses the applied date, property and unit. Rent status applies to Rent collection only.')),
        ...ReportExportKind.values.where((kind) => kind != ReportExportKind.history).map((kind) => ListTile(
          title: Text(kind.title),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: 'Preview or print ${kind.title} PDF', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: () { Navigator.pop(sheetContext); _export(kind); }),
            IconButton(tooltip: 'Share ${kind.title} PDF', icon: const Icon(Icons.share_outlined), onPressed: () { Navigator.pop(sheetContext); _export(kind, share: true); }),
          ]),
        )),
      ])));
  }
  void _tenantHistory(ReportRentRow row, {bool agreementOnly = false}) {
    showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (sheetContext) =>
      SafeArea(child: FractionallySizedBox(heightFactor: .82, child: Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 16), child: FutureBuilder<TenantRentReport>(
        future: agreementOnly
          ? reports.getAgreementRentReport(widget.account.workspaceId, row.agreementId, filters: filters)
          : reports.getTenantRentReport(widget.account.workspaceId, row.tenantId, filters: filters),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Column(children: [FeedbackAlert(message: _error(snapshot.error!)), TextButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('Close'))]);
          if (!snapshot.hasData) return const Column(children: [Skeleton(height: 28), SizedBox(height: 14), Skeleton(height: 90)]);
          final report = snapshot.data!;
          return ListView(children: [
            Text(agreementOnly ? 'Agreement rent history' : 'Tenant rent history', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            Text(agreementOnly ? '${report.tenantName} · ${row.propertyName} · ${row.unitName}' : '${report.tenantName} · All agreements', style: const TextStyle(color: CreovyColors.secondary)),
            const SizedBox(height: 12), _Metrics(items: [
              _Value('Expected', formatInr(report.rent.expectedRentPaise)), _Value('Paid in period', formatInr(report.rent.rentCollectedPaise)),
              _Value('Outstanding', formatInr(report.rent.outstandingPaise))]),
            const SizedBox(height: 12), Wrap(spacing: 8, children: [
              TextButton(onPressed: () { Navigator.pop(sheetContext); _tenantHistory(row, agreementOnly: !agreementOnly); }, child: Text(agreementOnly ? 'All tenant history' : 'This agreement only')),
              TextButton(onPressed: () { Navigator.pop(sheetContext); _openTenant(row.tenantId); }, child: const Text('View Tenant')),
              TextButton(onPressed: () { Navigator.pop(sheetContext); _openAgreement(row.agreementId); }, child: const Text('View Agreement')),
              TextButton.icon(onPressed: () => _export(ReportExportKind.history, history: report, agreementOnly: agreementOnly), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Preview PDF')),
              TextButton.icon(onPressed: () => _export(ReportExportKind.history, history: report, agreementOnly: agreementOnly, share: true), icon: const Icon(Icons.share_outlined), label: const Text('Share PDF')),
            ]),
            const SizedBox(height: 10), const _Title('Rent dues'),
            if (report.dues.isEmpty) const EmptyState(title: 'No dues', body: 'No due records match this period.') else ...report.dues.map((item) => ListTile(contentPadding: EdgeInsets.zero,
              title: Text('${item.periodKey} · Agreement ${item.agreementId.length > 8 ? item.agreementId.substring(0, 8) : item.agreementId}'),
              subtitle: Text('${properties.where((property) => property.id == item.propertyId).firstOrNull?.data['name'] ?? 'Property'} · ${units.where((unit) => unit.id == item.unitId).firstOrNull?.data['name'] ?? 'Unit'}\nExpected ${formatInr(item.amountPaise)} · Paid ${formatInr(item.paidPaise)} · Outstanding ${formatInr(item.balancePaise)}'))),
            const SizedBox(height: 10), const _Title('Payment transactions'),
            if (report.payments.isEmpty) const EmptyState(title: 'No payments', body: 'No payments match this period.') else ...report.payments.map((item) => ListTile(contentPadding: EdgeInsets.zero, title: Text(formatInr(item.amountPaise)), subtitle: Text('${item.periodKey} · ${_date(item.date.toDate())}'))),
          ]);
        },
      )))));
  }
  @override Widget build(BuildContext context) {
    final s = summary, r = rent;
    return Scaffold(backgroundColor: CreovyColors.canvas, appBar: AppBar(title: const Text('Reports & Analytics'), backgroundColor: CreovyColors.canvas, actions: [IconButton(tooltip: 'Export reports', onPressed: loading || error != null || _exportBusy ? null : _exportMenu, icon: _exportBusy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.ios_share_outlined)), IconButton(tooltip: 'Filters', onPressed: _exportBusy ? null : _filters, icon: const Icon(Icons.tune_rounded))]),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Text('${_date(filters.from!)} – ${_date(filters.through!)} · Asia/Kolkata', style: const TextStyle(fontSize: 12, color: CreovyColors.secondary)),
        if (filters.propertyId != null || filters.unitId != null) Padding(padding: const EdgeInsets.only(top: 5), child: Text('Filtered: ${properties.where((item) => item.id == filters.propertyId).firstOrNull?.data['name'] ?? 'All properties'}${filters.unitId == null ? '' : ' · ${units.where((item) => item.id == filters.unitId).firstOrNull?.data['name'] ?? 'Unit'}'}', style: const TextStyle(fontSize: 12, color: CreovyColors.brand))),
        const SizedBox(height: 14),
        if (loading) ...[const Skeleton(height: 96), const SizedBox(height: 10), const Skeleton(height: 96), const SizedBox(height: 18), const Skeleton(height: 220)]
        else if (error != null) SurfaceCard(child: Column(children: [FeedbackAlert(message: error!, tone: CreovyColors.danger), const SizedBox(height: 12), CreovyButton(label: 'Retry', icon: Icons.refresh, onPressed: _load)]))
        else if (s != null && r != null) ...[
          const _Title('Portfolio overview'),
          const SizedBox(height: 9),
          _Metrics(items: [_Value('Expected Rent', formatInr(s.rent.expectedRentPaise)), _Value('Rent Collected', formatInr(s.rent.rentCollectedPaise)), _Value('Rent Outstanding', formatInr(s.rent.outstandingPaise)), _Value('Rent Overdue', formatInr(s.rent.overduePaise)), _Value('Property Expenses', formatInr(s.expenses.totalExpensesPaise)), _Value('Net Cash Flow', formatInr(s.netPropertyCashFlowPaise)), _Value('Occupancy Rate', '${s.occupancy.occupancyRatePercent.toStringAsFixed(2)}%')]),
          const SizedBox(height: 18),
          _ReportSection(title: 'Rent report', subtitle: 'Due-date view · ${r.dueCount} dues', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Metrics(items: [_Value('Expected', formatInr(r.expectedRentPaise)), _Value('Collected', formatInr(r.rentCollectedPaise)), _Value('Outstanding', formatInr(r.outstandingPaise)), _Value('Overdue', formatInr(r.overduePaise)), _Value('Collection rate', '${r.collectionRatePercent.toStringAsFixed(2)}%')]),
            const SizedBox(height: 8), const Text('Collection rate uses cash-period payments linked to selected dues. Balances are current.', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)),
            const SizedBox(height: 12),
            if (rentRows.isEmpty) const EmptyState(title: 'No rent dues', body: 'Try a different date or property filter.')
            else ...rentRows.map((row) => Padding(padding: const EdgeInsets.only(bottom: 8), child: SurfaceCard(padding: EdgeInsets.zero, child: InkWell(borderRadius: BorderRadius.circular(18), onTap: () => _tenantHistory(row), child: Padding(padding: const EdgeInsets.all(13), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text('${row.propertyName} · ${row.unitName}', style: const TextStyle(fontWeight: FontWeight.w700))), StatusChip(label: _human(row.status))]),
              const SizedBox(height: 4), Text('${row.tenantName} · ${row.periodKey} · ${_date(row.dueDate.toDate())}', style: const TextStyle(fontSize: 12, color: CreovyColors.secondary)),
              const SizedBox(height: 9), Wrap(spacing: 15, runSpacing: 6, children: ['Expected ${formatInr(row.expectedPaise)}', 'Paid to date ${formatInr(row.paidPaise)}', 'Balance ${formatInr(row.balancePaise)}'].map((item) => Text(item, style: const TextStyle(fontSize: 12))).toList()),
              const SizedBox(height: 4), const Text('Tap for tenant & agreement history', style: TextStyle(fontSize: 11, color: CreovyColors.brand)),
            ])))))),
          ])),
          const SizedBox(height: 14),
          _ReportSection(title: 'Monthly cash flow', subtitle: 'Actual cash dates · YYYY-MM', child: _Trend(rows: trend)),
          const SizedBox(height: 14),
          _ReportSection(title: 'Property performance', child: performance.isEmpty ? const EmptyState(title: 'No properties', body: 'Choose another property or unit.') : Column(children: performance.map((row) => Padding(padding: const EdgeInsets.only(bottom: 8), child: SurfaceCard(padding: EdgeInsets.zero, child: InkWell(onTap: () => _openProperty(row.propertyId), child: Padding(padding: const EdgeInsets.all(13), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(row.propertyName, style: const TextStyle(fontWeight: FontWeight.w700))), const Icon(Icons.chevron_right, color: CreovyColors.secondary)]),
            const SizedBox(height: 7), _Metrics(items: [_Value('Expected', formatInr(row.expectedRentPaise)), _Value('Collected', formatInr(row.rentCollectedPaise)), _Value('Outstanding', formatInr(row.outstandingPaise)), _Value('Expenses', formatInr(row.propertyExpensesPaise)), _Value('Net cash', formatInr(row.netCashFlowPaise)), _Value('Occupancy', '${row.occupancyRatePercent.toStringAsFixed(2)}% · ${row.occupiedUnits}/${row.totalRentableUnits}')]),
          ])))))).toList())),
          const SizedBox(height: 14),
          _ReportSection(title: 'Property expenses', subtitle: 'Bills & Taxes excluded', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Metrics(items: [_Value('Total', formatInr(s.expenses.totalExpensesPaise)), _Value('Expense count', '${s.expenses.expenseCount}')]),
            const SizedBox(height: 10), const Text('By category', style: TextStyle(fontWeight: FontWeight.w700)),
            if (s.expenses.byCategory.isEmpty) const EmptyState(title: 'No expenses', body: 'No expenses match this period.') else ...s.expenses.byCategory.map((item) => _GroupRow(_human(item.key), formatInr(item.amountPaise))),
            const SizedBox(height: 10), const Text('By property', style: TextStyle(fontWeight: FontWeight.w700)),
            ...s.expenses.byProperty.map((item) => _GroupRow(properties.where((property) => property.id == item.key).firstOrNull?.data['name'] as String? ?? item.key, formatInr(item.amountPaise))),
          ])),
          const SizedBox(height: 14),
          _ReportSection(title: 'Bills & Taxes', subtitle: 'Separate from property expenses', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Metrics(items: [_Value('Raised', formatInr(s.bills.billsRaisedPaise)), _Value('Paid', formatInr(s.bills.billsPaidPaise)), _Value('Outstanding', formatInr(s.bills.billsOutstandingPaise)), _Value('Overdue', formatInr(s.bills.billsOverduePaise))]),
            const SizedBox(height: 10), const Text('Payments by bill type', style: TextStyle(fontWeight: FontWeight.w700)),
            if (s.bills.paymentsByBillType.isEmpty) const EmptyState(title: 'No bill payments', body: 'No bill payments match this period.') else ...s.bills.paymentsByBillType.map((item) => _GroupRow(_human(item.key), formatInr(item.amountPaise))),
          ])),
          const SizedBox(height: 14),
          _ReportSection(title: 'Security deposits', subtitle: 'Separate funds', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Metrics(items: [_Value('Agreed', formatInr(s.deposits.depositAgreedPaise)), _Value('Received', formatInr(s.deposits.depositReceivedPaise)), _Value('Refunded', formatInr(s.deposits.depositRefundedPaise)), _Value('Currently held', formatInr(s.deposits.depositCurrentlyHeldPaise))]),
            const SizedBox(height: 10), const Text('Security deposits are tracked separately and are not counted as rental income or Net Cash Flow.', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)),
          ])),
          const SizedBox(height: 14),
          _ReportSection(title: 'Occupancy & agreements', subtitle: 'Current snapshot', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Metrics(items: [_Value('Rentable units', '${s.occupancy.totalRentableUnits}'), _Value('Occupied', '${s.occupancy.occupiedUnits}'), _Value('Vacant', '${s.occupancy.vacantUnits}'), _Value('Maintenance', '${s.occupancy.maintenanceUnits}'), _Value('Occupancy rate', '${s.occupancy.occupancyRatePercent.toStringAsFixed(2)}%')]),
            const SizedBox(height: 8), Text('Inactive units (${s.occupancy.inactiveUnits}) are excluded from rentable inventory.', style: const TextStyle(fontSize: 12, color: CreovyColors.secondary)),
            const SizedBox(height: 12), _Metrics(items: [_Value('Active tenants', '${s.occupancy.activeTenants}'), _Value('Active agreements', '${s.occupancy.activeAgreements}'), _Value('Upcoming agreements', '${s.occupancy.upcomingAgreements}'), _Value('Ended agreements', '${s.occupancy.endedAgreements}')]),
          ])),
          const SizedBox(height: 18), const Text('Current balances and occupancy are live snapshots. Use Export reports for PDF preview, printing or sharing. CSV/Excel export is not available.', style: TextStyle(fontSize: 12, color: CreovyColors.secondary)),
        ],
      ])),
    );
  }
}
class _Value { const _Value(this.label, this.value); final String label, value; }
class _Title extends StatelessWidget { const _Title(this.label); final String label; @override Widget build(BuildContext context) => Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: CreovyColors.ink)); }
class _Metrics extends StatelessWidget {
  const _Metrics({required this.items}); final List<_Value> items;
  @override Widget build(BuildContext context) => LayoutBuilder(builder: (context, size) {
    final width = (size.maxWidth - 8) / 2;
    return Wrap(spacing: 8, runSpacing: 8, children: items.map((item) => SizedBox(width: width, child: Container(padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: CreovyColors.canvas, borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.label, style: const TextStyle(fontSize: 11, color: CreovyColors.secondary)), const SizedBox(height: 3), Text(item.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CreovyColors.ink))])))).toList());
  });
}
class _ReportSection extends StatelessWidget {
  const _ReportSection({required this.title, required this.child, this.subtitle}); final String title; final String? subtitle; final Widget child;
  @override Widget build(BuildContext context) => SurfaceCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_Title(title), if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(subtitle!, style: const TextStyle(fontSize: 12, color: CreovyColors.secondary))), const SizedBox(height: 14), child]));
}
class _GroupRow extends StatelessWidget { const _GroupRow(this.label, this.value); final String label, value; @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [Expanded(child: Text(label, style: const TextStyle(fontSize: 13))), Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))])); }
class _Trend extends StatelessWidget {
  const _Trend({required this.rows}); final List<MonthlyCashFlowRow> rows;
  @override Widget build(BuildContext context) {
    if (rows.isEmpty) return const EmptyState(title: 'No monthly activity', body: 'Choose another date range to see a trend.');
    final maximum = rows.expand((row) => [row.expectedRentPaise.abs(), row.rentCollectedPaise.abs(), row.propertyExpensesPaise.abs(), row.netCashFlowPaise.abs()]).fold<int>(1, (a, b) => b > a ? b : a);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Expected  •  Collected  •  Expenses  •  Net cash', style: TextStyle(fontSize: 11, color: CreovyColors.secondary)),
      const SizedBox(height: 10),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: rows.map((row) => Padding(padding: const EdgeInsets.only(right: 9), child: Container(width: 172, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: CreovyColors.canvas, borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(row.periodKey, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _TrendBar('Expected', row.expectedRentPaise, maximum, const Color(0xFFA78BFA)),
        _TrendBar('Collected', row.rentCollectedPaise, maximum, CreovyColors.brand),
        _TrendBar('Expenses', row.propertyExpensesPaise, maximum, CreovyColors.warning),
        _TrendBar('Net cash', row.netCashFlowPaise, maximum, CreovyColors.accent),
      ])))).toList())),
      const SizedBox(height: 8), const Text('Bar lengths compare absolute amounts; signed net cash values are shown.', style: TextStyle(fontSize: 11, color: CreovyColors.secondary)),
    ]);
  }
}
class _TrendBar extends StatelessWidget {
  const _TrendBar(this.label, this.value, this.maximum, this.color); final String label; final int value, maximum; final Color color;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [Expanded(child: Text(label, style: const TextStyle(fontSize: 10, color: CreovyColors.secondary))), Text(formatInr(value), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600))]),
    const SizedBox(height: 3), Container(height: 5, width: 148, decoration: BoxDecoration(color: CreovyColors.border, borderRadius: BorderRadius.circular(5)), alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: value.abs() / maximum, child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5))))),
  ]));
}
