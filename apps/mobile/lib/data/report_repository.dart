import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../domain/report_models.dart';

class _Row {
  const _Row(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}
class _Month {
  int expected = 0, collected = 0, expenses = 0;
}

/// Read-only reporting over the existing workspace-owned source collections.
class ReportRepository {
  ReportRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  static const _maxRows = 3000;
  static const _maxPaise = 9007199254740991;
  static const _indiaOffset = Duration(hours: 5, minutes: 30);

  DateTime _indiaDay(DateTime value) => value.toUtc().add(_indiaOffset);
  DateTime _midnight(DateTime value) { final day = _indiaDay(value); return DateTime.utc(day.year, day.month, day.day).subtract(_indiaOffset); }
  String _businessDate(DateTime value) { final day = _indiaDay(value); return '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}'; }
  String _month(DateTime value) => _businessDate(value).substring(0, 7);
  String _nextMonth(String key) { final year = int.parse(key.substring(0, 4)), month = int.parse(key.substring(5, 7)); return month == 12 ? '${year + 1}-01' : '$year-${(month + 1).toString().padLeft(2, '0')}'; }
  void _check(String workspaceId, ReportFilters filters) {
    if (_auth.currentUser == null) throw StateError('Sign in to view reports.');
    if (workspaceId.isEmpty || filters.from != null && filters.through != null && _midnight(filters.from!).isAfter(_midnight(filters.through!))) throw ArgumentError('Invalid report workspace or date range.');
    if (filters.rentStatus != null && !['pending', 'partial', 'paid', 'overdue'].contains(filters.rentStatus) ||
        filters.billType != null && !['electricity', 'water_tax', 'property_tax', 'other'].contains(filters.billType) ||
        filters.expenseCategory != null && !['maintenance', 'repair', 'plumbing', 'electrical', 'cleaning', 'painting', 'security', 'labour', 'common_area', 'other'].contains(filters.expenseCategory))
      throw ArgumentError('Invalid report category or status filter.');
  }
  void _rejectTenantScopedNet(ReportFilters filters) {
    if (filters.tenantId != null || filters.agreementId != null || filters.rentStatus != null || filters.expenseCategory != null)
      throw ArgumentError('Net cash flow supports date/property/unit filters only.');
  }
  String _string(_Row row, String key) { final value = row.data[key]; if (value is! String) throw StateError('Invalid $key in ${row.id}.'); return value; }
  int _money(_Row row, String key) { final value = row.data[key]; if (value is! int || value < 0 || value > _maxPaise) throw StateError('Invalid $key in ${row.id}.'); return value; }
  Timestamp _stamp(_Row row, String key) { final value = row.data[key]; if (value is! Timestamp) throw StateError('Invalid $key in ${row.id}.'); return value; }
  int _add(int a, int b) { final result = a + b; if (result > _maxPaise || result < -_maxPaise) throw StateError('Report total exceeds safe integer paise.'); return result; }
  int _sum(Iterable<int> values) => values.fold<int>(0, _add);
  double _rate(int numerator, int denominator) => denominator == 0 ? 0 : (numerator / denominator * 10000).round() / 100;
  bool _location(_Row row, ReportFilters filters) => (filters.propertyId == null || row.data['propertyId'] == filters.propertyId) &&
    (filters.unitId == null || row.data['unitId'] == filters.unitId);
  bool _person(_Row row, ReportFilters filters) => _location(row, filters) &&
    (filters.tenantId == null || row.data['tenantId'] == filters.tenantId) &&
    (filters.agreementId == null || row.data['agreementId'] == filters.agreementId);
  MapEntry<String, String>? _dimension(ReportFilters filters, List<String> keys) {
    for (final key in keys) {
      final value = switch (key) { 'propertyId' => filters.propertyId, 'unitId' => filters.unitId,
        'tenantId' => filters.tenantId, 'agreementId' => filters.agreementId,
        'billType' => filters.billType, 'category' => filters.expenseCategory, _ => null };
      if (value != null && value.isNotEmpty) return MapEntry(key, value);
    }
    return null;
  }
  Future<List<_Row>> _read(String collectionName, String workspaceId, ReportFilters filters,
      {String? dateField, MapEntry<String, String>? indexedDimension, bool ascending = false}) async {
    _check(workspaceId, filters);
    Query<Map<String, dynamic>> source = _firestore.collection(collectionName).where('workspaceId', isEqualTo: workspaceId);
    if (indexedDimension != null) source = source.where(indexedDimension.key, isEqualTo: indexedDimension.value);
    if (dateField != null) {
      if (filters.from != null) source = source.where(dateField, isGreaterThanOrEqualTo: Timestamp.fromDate(_midnight(filters.from!)));
      if (filters.through != null) source = source.where(dateField, isLessThan: Timestamp.fromDate(_midnight(filters.through!).add(const Duration(days: 1))));
      source = source.orderBy(dateField, descending: !ascending);
    }
    final snapshot = await source.limit(_maxRows + 1).get(const GetOptions(source: Source.server));
    if (snapshot.docs.length > _maxRows) throw StateError('$collectionName exceeds the client reporting limit; narrow the date or property filter.');
    return snapshot.docs.map((item) => _Row(item.id, item.data())).toList();
  }
  Future<List<_Row>> _dues(String ws, ReportFilters f) => _read('rentDues', ws, f, dateField: 'dueDate', indexedDimension: _dimension(f, ['tenantId', 'propertyId']));
  Future<List<_Row>> _rentPayments(String ws, ReportFilters f) => _read('rentPayments', ws, f, dateField: 'paymentDate', indexedDimension: _dimension(f, ['tenantId', 'propertyId']));
  Future<List<_Row>> _expenses(String ws, ReportFilters f) => _read('propertyExpenses', ws, f, dateField: 'expenseDate', indexedDimension: _dimension(f, ['unitId', 'propertyId', 'category']));
  Future<List<_Row>> _bills(String ws, ReportFilters f) => _read('propertyBills', ws, f, dateField: 'billDate', indexedDimension: _dimension(f, ['propertyId', 'billType']));
  Future<List<_Row>> _billPayments(String ws, ReportFilters f) => _read('propertyBillPayments', ws, f, dateField: 'paymentDate', indexedDimension: _dimension(f, ['propertyId']));
  Future<List<_Row>> _depositTransactions(String ws, ReportFilters f) {
    final dimension = _dimension(f, ['tenantId', 'agreementId', 'propertyId']);
    return _read('securityDepositTransactions', ws, f, dateField: 'transactionDate', indexedDimension: dimension,
      ascending: dimension?.key == 'tenantId' || dimension?.key == 'agreementId');
  }
  Future<List<_Row>> _agreements(String ws) => _read('rentalAgreements', ws, const ReportFilters());
  Future<List<_Row>> _depositSummaries(String ws) => _read('securityDeposits', ws, const ReportFilters());
  Future<List<_Row>> _units(String ws) => _read('units', ws, const ReportFilters());
  Future<List<_Row>> _properties(String ws) => _read('properties', ws, const ReportFilters());
  Future<List<_Row>> _tenants(String ws) => _read('tenants', ws, const ReportFilters());

  String _rentStatus(_Row due, DateTime asOf) {
    if (_money(due, 'balancePaise') == 0) return 'paid';
    if (_money(due, 'totalPaidPaise') > 0) return 'partial';
    return _stamp(due, 'dueDate').toDate().isBefore(asOf) ? 'overdue' : 'pending';
  }
  List<_Row> _selectedDues(List<_Row> rows, ReportFilters filters, DateTime asOf) => rows.where((row) =>
    _person(row, filters) && (filters.rentStatus == null || _rentStatus(row, asOf) == filters.rentStatus)).toList();
  RentReport _rentResult(List<_Row> dueRows, List<_Row> paymentRows, ReportFilters filters) {
    final today = _midnight(DateTime.now());
    final selectedDues = _selectedDues(dueRows, filters, today);
    final dueIds = selectedDues.map((row) => row.id).toSet();
    final selectedPayments = paymentRows.where((row) => _person(row, filters) &&
      (filters.rentStatus == null || dueIds.contains(_string(row, 'rentDueId')))).toList();
    final expected = _sum(selectedDues.map((row) => _money(row, 'rentAmountPaise')));
    final collected = _sum(selectedPayments.map((row) => _money(row, 'amountPaise')));
    final against = _sum(selectedPayments.where((row) => dueIds.contains(_string(row, 'rentDueId'))).map((row) => _money(row, 'amountPaise')));
    final outstanding = _sum(selectedDues.map((row) => _money(row, 'balancePaise')));
    final overdue = _sum(selectedDues.where((row) => _stamp(row, 'dueDate').toDate().isBefore(today)).map((row) => _money(row, 'balancePaise')));
    return RentReport(expectedRentPaise: expected, rentCollectedPaise: collected,
      collectedAgainstExpectedPaise: against, outstandingPaise: outstanding, overduePaise: overdue,
      collectionRatePercent: _rate(against, expected), dueCount: selectedDues.length,
      paymentCount: selectedPayments.length, asOfBusinessDate: _businessDate(DateTime.now()));
  }
  List<ReportMoneyGroup> _groups(List<_Row> rows, String field) {
    final amounts = <String, int>{}, counts = <String, int>{};
    for (final row in rows) { final key = _string(row, field); amounts[key] = _add(amounts[key] ?? 0, _money(row, 'amountPaise')); counts[key] = (counts[key] ?? 0) + 1; }
    final keys = amounts.keys.toList()..sort();
    return keys.map((key) => ReportMoneyGroup(key, amounts[key]!, counts[key]!)).toList();
  }
  ExpenseReport _expenseResult(List<_Row> rows, ReportFilters filters) {
    final selected = rows.where((row) => _location(row, filters) &&
      (filters.expenseCategory == null || row.data['category'] == filters.expenseCategory)).toList();
    return ExpenseReport(totalExpensesPaise: _sum(selected.map((row) => _money(row, 'amountPaise'))),
      expenseCount: selected.length, byCategory: _groups(selected, 'category'),
      byProperty: _groups(selected, 'propertyId'), byUnit: _groups(selected.where((row) => row.data['unitId'] != null).toList(), 'unitId'));
  }
  BillsReport _billsResult(List<_Row> billRows, List<_Row> paymentRows, ReportFilters filters) {
    final selectedBills = billRows.where((row) => _location(row, filters) &&
      (filters.billType == null || row.data['billType'] == filters.billType)).toList();
    final selectedPayments = paymentRows.where((row) => _location(row, filters) &&
      (filters.billType == null || row.data['billType'] == filters.billType)).toList();
    final today = _midnight(DateTime.now());
    return BillsReport(billsRaisedPaise: _sum(selectedBills.map((row) => _money(row, 'amountPaise'))),
      billsPaidPaise: _sum(selectedPayments.map((row) => _money(row, 'amountPaise'))),
      billsOutstandingPaise: _sum(selectedBills.map((row) => _money(row, 'balancePaise'))),
      billsOverduePaise: _sum(selectedBills.where((row) => _stamp(row, 'dueDate').toDate().isBefore(today)).map((row) => _money(row, 'balancePaise'))),
      paymentsByBillType: _groups(selectedPayments, 'billType'), billCount: selectedBills.length,
      paymentCount: selectedPayments.length, asOfBusinessDate: _businessDate(DateTime.now()));
  }
  DepositReport _depositResult(List<_Row> agreementRows, List<_Row> summaryRows, List<_Row> txRows, ReportFilters filters) {
    final eligible = agreementRows.where((row) => _person(row, filters) && !['draft', 'cancelled'].contains(_string(row, 'status')));
    final summaries = summaryRows.where((row) => _person(row, filters));
    final tx = txRows.where((row) => _person(row, filters)).toList();
    return DepositReport(depositAgreedPaise: _sum(eligible.map((row) => _money(row, 'securityDepositAgreedPaise'))),
      depositReceivedPaise: _sum(tx.where((row) => row.data['transactionType'] == 'received').map((row) => _money(row, 'amountPaise'))),
      depositRefundedPaise: _sum(tx.where((row) => row.data['transactionType'] == 'refunded').map((row) => _money(row, 'amountPaise'))),
      depositCurrentlyHeldPaise: _sum(summaries.map((row) => _money(row, 'heldBalancePaise'))), transactionCount: tx.length);
  }
  OccupancyReport _occupancyResult(List<_Row> unitRows, List<_Row> agreementRows, ReportFilters filters) {
    final inventory = unitRows.where((row) => (filters.propertyId == null || row.data['propertyId'] == filters.propertyId) &&
      (filters.unitId == null || row.id == filters.unitId)).toList();
    final related = agreementRows.where((row) => _person(row, filters)).toList();
    final active = related.where((row) => row.data['status'] == 'active').toList();
    final occupiedIds = agreementRows.where((row) => row.data['status'] == 'active').map((row) => _string(row, 'unitId')).toSet();
    final rentable = inventory.where((row) => !['inactive', 'maintenance'].contains(_string(row, 'status'))).toList();
    final occupied = rentable.where((row) => occupiedIds.contains(row.id)).length;
    return OccupancyReport(totalRentableUnits: rentable.length, occupiedUnits: occupied,
      vacantUnits: rentable.length - occupied,
      maintenanceUnits: inventory.where((row) => row.data['status'] == 'maintenance').length,
      inactiveUnits: inventory.where((row) => row.data['status'] == 'inactive').length,
      occupancyRatePercent: _rate(occupied, rentable.length),
      activeTenants: active.map((row) => _string(row, 'tenantId')).toSet().length,
      activeAgreements: active.length, upcomingAgreements: related.where((row) => row.data['status'] == 'upcoming').length,
      endedAgreements: related.where((row) => row.data['status'] == 'ended').length);
  }

  Future<RentReport> getRentReport(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters);
    final rows = await Future.wait<List<_Row>>([_dues(workspaceId, filters), _rentPayments(workspaceId, filters)]);
    return _rentResult(rows[0], rows[1], filters);
  }
  Future<List<ReportRentRow>> getRentBreakdown(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters);
    final rows = await Future.wait<List<_Row>>([_dues(workspaceId, filters), _properties(workspaceId), _units(workspaceId), _tenants(workspaceId)]);
    Map<String, String> names(List<_Row> source, String key) => {for (final row in source) row.id: _string(row, key)};
    final propertyNames = names(rows[1], 'name'), unitNames = names(rows[2], 'name'), tenantNames = names(rows[3], 'fullName');
    final today = _midnight(DateTime.now());
    return _selectedDues(rows[0], filters, today).map((row) => ReportRentRow(
      dueId: row.id, tenantId: _string(row, 'tenantId'), tenantName: tenantNames[_string(row, 'tenantId')] ?? 'Tenant',
      agreementId: _string(row, 'agreementId'), propertyId: _string(row, 'propertyId'),
      propertyName: propertyNames[_string(row, 'propertyId')] ?? 'Property', unitId: _string(row, 'unitId'),
      unitName: unitNames[_string(row, 'unitId')] ?? 'Unit', periodKey: _string(row, 'periodKey'),
      dueDate: _stamp(row, 'dueDate'), expectedPaise: _money(row, 'rentAmountPaise'),
      paidPaise: _money(row, 'totalPaidPaise'), balancePaise: _money(row, 'balancePaise'),
      status: _rentStatus(row, today))).toList();
  }
  Future<ExpenseReport> getExpenseReport(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters); return _expenseResult(await _expenses(workspaceId, filters), filters);
  }
  Future<BillsReport> getBillsReport(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters);
    final rows = await Future.wait<List<_Row>>([_bills(workspaceId, filters), _billPayments(workspaceId, filters)]);
    return _billsResult(rows[0], rows[1], filters);
  }
  Future<DepositReport> getDepositReport(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters);
    final rows = await Future.wait<List<_Row>>([_agreements(workspaceId), _depositSummaries(workspaceId), _depositTransactions(workspaceId, filters)]);
    return _depositResult(rows[0], rows[1], rows[2], filters);
  }
  Future<OccupancyReport> getOccupancyReport(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters);
    final rows = await Future.wait<List<_Row>>([_units(workspaceId), _agreements(workspaceId)]);
    return _occupancyResult(rows[0], rows[1], filters);
  }
  Future<PortfolioSummary> getPortfolioSummary(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters); _rejectTenantScopedNet(filters);
    final rent = await getRentReport(workspaceId, filters: filters);
    final expenses = await getExpenseReport(workspaceId, filters: filters);
    final bills = await getBillsReport(workspaceId, filters: filters);
    final deposits = await getDepositReport(workspaceId, filters: filters);
    final occupancy = await getOccupancyReport(workspaceId, filters: filters);
    return PortfolioSummary(rent: rent, expenses: expenses, bills: bills, deposits: deposits,
      occupancy: occupancy, netPropertyCashFlowPaise: _add(rent.rentCollectedPaise, -expenses.totalExpensesPaise));
  }
  Future<List<PropertyPerformanceRow>> getPropertyPerformance(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters); _rejectTenantScopedNet(filters);
    final rows = await Future.wait<List<_Row>>([_properties(workspaceId), _dues(workspaceId, filters), _rentPayments(workspaceId, filters),
      _expenses(workspaceId, filters), _units(workspaceId), _agreements(workspaceId)]);
    _Row? selectedUnit;
    if (filters.unitId != null) {
      for (final unit in rows[4]) { if (unit.id == filters.unitId) { selectedUnit = unit; break; } }
    }
    return rows[0].where((property) => (filters.propertyId == null || property.id == filters.propertyId) &&
      (filters.unitId == null || selectedUnit?.data['propertyId'] == property.id)).map((property) {
      final scoped = filters.copyWith(propertyId: property.id);
      final rent = _rentResult(rows[1], rows[2], scoped);
      final expense = _expenseResult(rows[3], scoped);
      final occupancy = _occupancyResult(rows[4], rows[5], scoped);
      return PropertyPerformanceRow(propertyId: property.id, propertyName: _string(property, 'name'),
        expectedRentPaise: rent.expectedRentPaise, rentCollectedPaise: rent.rentCollectedPaise,
        outstandingPaise: rent.outstandingPaise, propertyExpensesPaise: expense.totalExpensesPaise,
        netCashFlowPaise: _add(rent.rentCollectedPaise, -expense.totalExpensesPaise),
        totalRentableUnits: occupancy.totalRentableUnits, occupiedUnits: occupancy.occupiedUnits,
        occupancyRatePercent: occupancy.occupancyRatePercent);
    }).toList();
  }
  Future<TenantRentReport> getTenantRentReport(String workspaceId, String tenantId, {ReportFilters filters = const ReportFilters()}) async {
    final scoped = filters.copyWith(tenantId: tenantId);
    _check(workspaceId, scoped);
    if (tenantId.isEmpty) throw ArgumentError('Tenant is required.');
    final tenant = await _firestore.collection('tenants').doc(tenantId).get(const GetOptions(source: Source.server));
    if (!tenant.exists || tenant.data()?['workspaceId'] != workspaceId) throw StateError('Tenant not found in workspace.');
    final rows = await Future.wait<List<_Row>>([_dues(workspaceId, scoped), _rentPayments(workspaceId, scoped)]);
    final selectedDues = _selectedDues(rows[0], scoped, _midnight(DateTime.now()));
    final dueIds = selectedDues.map((row) => row.id).toSet();
    final selectedPayments = rows[1].where((row) => _person(row, scoped) &&
      (scoped.rentStatus == null || dueIds.contains(_string(row, 'rentDueId')))).toList();
    ReportHistoryRow history(_Row row, String amountField, String dateField, bool balance) => ReportHistoryRow(
      id: row.id, agreementId: _string(row, 'agreementId'), propertyId: _string(row, 'propertyId'),
      unitId: _string(row, 'unitId'), periodKey: _string(row, 'periodKey'), amountPaise: _money(row, amountField),
      paidPaise: balance ? _money(row, 'totalPaidPaise') : null,
      balancePaise: balance ? _money(row, 'balancePaise') : null, date: _stamp(row, dateField));
    return TenantRentReport(tenantId: tenantId, tenantName: tenant.data()?['fullName'] as String? ?? '',
      rent: _rentResult(rows[0], rows[1], scoped),
      dues: selectedDues.map((row) => history(row, 'rentAmountPaise', 'dueDate', true)).toList(),
      payments: selectedPayments.map((row) => history(row, 'amountPaise', 'paymentDate', false)).toList());
  }
  Future<TenantRentReport> getAgreementRentReport(String workspaceId, String agreementId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters);
    if (agreementId.isEmpty) throw ArgumentError('Agreement is required.');
    final agreement = await _firestore.collection('rentalAgreements').doc(agreementId).get(const GetOptions(source: Source.server));
    final data = agreement.data();
    if (!agreement.exists || data?['workspaceId'] != workspaceId || data?['tenantId'] is! String)
      throw StateError('Agreement not found in workspace.');
    return getTenantRentReport(workspaceId, data!['tenantId'] as String, filters: ReportFilters(
      from: filters.from, through: filters.through, propertyId: filters.propertyId, unitId: filters.unitId,
      tenantId: data['tenantId'] as String, agreementId: agreementId, rentStatus: filters.rentStatus,
      billType: filters.billType, expenseCategory: filters.expenseCategory));
  }
  Future<List<MonthlyCashFlowRow>> getMonthlyCashFlowTrend(String workspaceId, {ReportFilters filters = const ReportFilters()}) async {
    _check(workspaceId, filters); _rejectTenantScopedNet(filters);
    final rows = await Future.wait<List<_Row>>([_dues(workspaceId, filters), _rentPayments(workspaceId, filters), _expenses(workspaceId, filters)]);
    final selectedDues = _selectedDues(rows[0], filters, _midnight(DateTime.now()));
    final dueIds = selectedDues.map((row) => row.id).toSet();
    final selectedPayments = rows[1].where((row) => _person(row, filters) &&
      (filters.rentStatus == null || dueIds.contains(_string(row, 'rentDueId'))));
    final selectedExpenses = rows[2].where((row) => _location(row, filters) &&
      (filters.expenseCategory == null || row.data['category'] == filters.expenseCategory));
    final months = <String, _Month>{};
    _Month bucket(String key) => months.putIfAbsent(key, () => _Month());
    for (final row in selectedDues) { final month = bucket(_string(row, 'periodKey')); month.expected = _add(month.expected, _money(row, 'rentAmountPaise')); }
    for (final row in selectedPayments) { final month = bucket(_month(_stamp(row, 'paymentDate').toDate())); month.collected = _add(month.collected, _money(row, 'amountPaise')); }
    for (final row in selectedExpenses) { final month = bucket(_month(_stamp(row, 'expenseDate').toDate())); month.expenses = _add(month.expenses, _money(row, 'amountPaise')); }
    final keys = months.keys.toList()..sort();
    final first = filters.from == null ? (keys.isEmpty ? null : keys.first) : _month(filters.from!);
    final last = filters.through == null ? (keys.isEmpty ? null : keys.last) : _month(filters.through!);
    if (first == null || last == null) return [];
    final result = <MonthlyCashFlowRow>[];
    for (var key = first; key.compareTo(last) <= 0; key = _nextMonth(key)) {
      if (result.length >= 120) throw StateError('Monthly trend exceeds 120 months; narrow the reporting range.');
      final month = bucket(key);
      result.add(MonthlyCashFlowRow(periodKey: key, expectedRentPaise: month.expected,
        rentCollectedPaise: month.collected, propertyExpensesPaise: month.expenses,
        netCashFlowPaise: _add(month.collected, -month.expenses)));
    }
    return result;
  }
}
