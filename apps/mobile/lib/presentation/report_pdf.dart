import 'dart:typed_data';

import 'package:flutter/material.dart' show TextAlign;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/report_models.dart';
import 'receipt_screen.dart' show shapedReceiptValue;

enum ReportExportKind {
  overview('Portfolio overview', 'Portfolio'),
  rent('Rent collection', 'Rent'),
  property('Property performance', 'Property'),
  expenses('Property expenses', 'Expense'),
  bills('Bills & Taxes', 'Bills-Taxes'),
  deposits('Security deposits', 'Security-Deposit'),
  occupancy('Occupancy', 'Occupancy'),
  history('Tenant / agreement rent history', 'Rent-History');

  const ReportExportKind(this.title, this.slug);
  final String title, slug;
}

class ReportPdfData {
  const ReportPdfData({required this.kind, required this.filters, required this.propertyName,
    required this.unitName, required this.propertyNames, required this.unitNames,
    required this.summary, required this.rent, required this.rentRows,
    required this.performance, required this.trend, required this.generatedAt,
    this.rentStatus, this.history, this.agreementHistory = false});
  final ReportExportKind kind;
  final ReportFilters filters;
  final String propertyName, unitName;
  final Map<String, String> propertyNames, unitNames;
  final PortfolioSummary summary;
  final RentReport rent;
  final List<ReportRentRow> rentRows;
  final List<PropertyPerformanceRow> performance;
  final List<MonthlyCashFlowRow> trend;
  final DateTime generatedAt;
  final String? rentStatus;
  final TenantRentReport? history;
  final bool agreementHistory;

  bool get hasData => switch (kind) {
    ReportExportKind.overview => summary.rent.dueCount > 0 || summary.rent.paymentCount > 0 ||
      summary.expenses.expenseCount > 0 || summary.bills.billCount > 0 ||
      summary.bills.paymentCount > 0 || summary.deposits.transactionCount > 0 ||
      summary.deposits.depositAgreedPaise > 0 || summary.deposits.depositCurrentlyHeldPaise > 0 ||
      summary.occupancy.totalRentableUnits > 0 || summary.occupancy.inactiveUnits > 0 ||
      summary.occupancy.activeTenants > 0 || performance.isNotEmpty,
    ReportExportKind.rent => rent.dueCount > 0 || rent.paymentCount > 0,
    ReportExportKind.property => performance.isNotEmpty,
    ReportExportKind.expenses => summary.expenses.expenseCount > 0,
    ReportExportKind.bills => summary.bills.billCount > 0 || summary.bills.paymentCount > 0,
    ReportExportKind.deposits => summary.deposits.transactionCount > 0 ||
      summary.deposits.depositAgreedPaise > 0 || summary.deposits.depositCurrentlyHeldPaise > 0,
    ReportExportKind.occupancy => summary.occupancy.totalRentableUnits > 0 ||
      summary.occupancy.inactiveUnits > 0 || summary.occupancy.activeTenants > 0 || summary.occupancy.activeAgreements > 0 ||
      summary.occupancy.upcomingAgreements > 0 || summary.occupancy.endedAgreements > 0,
    ReportExportKind.history => history != null && (history!.dues.isNotEmpty || history!.payments.isNotEmpty),
  };

  String get fileName {
    final from = _isoDay(filters.from!);
    final through = _isoDay(filters.through!);
    final fromDay = _indiaDay(filters.from!);
    final throughDay = _indiaDay(filters.through!);
    final fullMonth = from.substring(0, 7) == through.substring(0, 7) && fromDay.day == 1 &&
      throughDay.day == DateTime.utc(throughDay.year, throughDay.month + 1, 0).day;
    final period = fullMonth ? from.substring(0, 7) : '$from-to-$through';
    final property = propertyName == 'All properties' ? '' : propertyName
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final safeProperty = (property.length > 32 ? property.substring(0, 32) : property).replaceAll(RegExp(r'-$'), '');
    return 'CREOVY-HOMS-${kind.slug}-Report${safeProperty.isEmpty ? '' : '-$safeProperty'}-$period.pdf';
  }
}

const _indiaOffset = Duration(hours: 5, minutes: 30);
DateTime _indiaDay(DateTime value) => value.toUtc().add(_indiaOffset);
String _day(DateTime value) { final day = _indiaDay(value); return '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}'; }
String _isoDay(DateTime value) { final day = _indiaDay(value); return '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}'; }
String _dateTime(DateTime value) { final day = _indiaDay(value); return '${_day(value)} ${day.hour.toString().padLeft(2, '0')}:${day.minute.toString().padLeft(2, '0')} IST'; }
String _money(int paise) {
  final negative = paise < 0;
  final absolute = paise.abs();
  final digits = (absolute ~/ 100).toString();
  var head = digits.length > 3 ? digits.substring(0, digits.length - 3) : '';
  final groups = <String>[];
  while (head.length > 2) { groups.insert(0, head.substring(head.length - 2)); head = head.substring(0, head.length - 2); }
  if (head.isNotEmpty) groups.insert(0, head);
  final rupees = digits.length > 3 ? '${groups.join(',')},${digits.substring(digits.length - 3)}' : digits;
  return 'INR ${negative ? '-' : ''}$rupees.${(absolute % 100).toString().padLeft(2, '0')}';
}
String _human(String value) => value.split('_').map((part) => part.isEmpty ? part : '${part[0].toUpperCase()}${part.substring(1)}').join(' ');

Future<pw.Widget> _value(String value, {double width = 360, double fontSize = 9}) async {
  if (RegExp(r'[^\x00-\x7F]').hasMatch(value)) {
    return shapedReceiptValue(value, width: width, alignment: TextAlign.left, fontSize: fontSize);
  }
  return pw.Text(value, style: pw.TextStyle(fontSize: fontSize, color: PdfColors.grey900));
}

pw.Widget _section(String title) => pw.Padding(padding: const pw.EdgeInsets.only(top: 16, bottom: 7),
  child: pw.Text(title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.deepPurple)));
pw.Widget _note(String text) => pw.Padding(padding: const pw.EdgeInsets.only(top: 8),
  child: pw.Text(text, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)));
pw.Widget _metrics(List<(String, String)> items) => pw.Wrap(spacing: 7, runSpacing: 7, children: items.map((item) =>
  pw.Container(width: 156, padding: const pw.EdgeInsets.all(8), decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5))),
    child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text(item.$1, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      pw.SizedBox(height: 3), pw.Text(item.$2, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
    ]))).toList());

Future<pw.Widget> _row(String label, String detail, {String? subline}) async {
  final labelWidget = await _value(label, width: 440);
  final detailWidget = await _value(detail, width: 440, fontSize: 8);
  return pw.Container(padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 9), margin: const pw.EdgeInsets.only(bottom: 5),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))),
    child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      labelWidget, pw.SizedBox(height: 3), detailWidget,
      if (subline != null) ...[pw.SizedBox(height: 2), pw.Text(subline, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700))],
    ]));
}

Future<Uint8List> createReportPdf(ReportPdfData data) async {
  if (!data.hasData) throw StateError('No records match the selected report scope.');
  final content = <pw.Widget>[
    pw.Text('${data.kind.title} report', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 12),
    pw.Text('Period: ${_day(data.filters.from!)} - ${_day(data.filters.through!)}', style: const pw.TextStyle(fontSize: 9)),
    pw.Text('Generated: ${_dateTime(data.generatedAt)}', style: const pw.TextStyle(fontSize: 9)),
    pw.Text('Business timezone: Asia/Kolkata  |  Currency: INR', style: const pw.TextStyle(fontSize: 9)),
  ];
  content.add(await _row('Property', data.propertyName));
  content.add(await _row('Unit', data.unitName));
  content.add(_note('Rent status: ${data.kind == ReportExportKind.rent ? (data.rentStatus == null ? 'All statuses' : _human(data.rentStatus!)) : 'Not applied to this report'}'));

  final s = data.summary, r = data.rent;
  switch (data.kind) {
    case ReportExportKind.overview:
      content.addAll([_section('Portfolio KPIs'), _metrics([
        ('Expected rent', _money(s.rent.expectedRentPaise)), ('Rent collected', _money(s.rent.rentCollectedPaise)),
        ('Outstanding', _money(s.rent.outstandingPaise)), ('Overdue', _money(s.rent.overduePaise)),
        ('Property expenses', _money(s.expenses.totalExpensesPaise)), ('Net property cash flow', _money(s.netPropertyCashFlowPaise)),
        ('Occupancy rate', '${s.occupancy.occupancyRatePercent.toStringAsFixed(2)}%'),
      ]), _section('Monthly cash flow')]);
      if (data.trend.isEmpty) content.add(_note('No monthly cash-flow rows match this period.'));
      for (final row in data.trend) {
        content.add(await _row(row.periodKey, 'Expected ${_money(row.expectedRentPaise)}  |  Collected ${_money(row.rentCollectedPaise)}',
          subline: 'Expenses ${_money(row.propertyExpensesPaise)}  |  Net cash ${_money(row.netCashFlowPaise)}'));
      }
      if (data.performance.isNotEmpty) {
        content.add(_section('Property performance'));
        for (final row in data.performance) {
          content.add(await _row(row.propertyName, 'Expected ${_money(row.expectedRentPaise)}  |  Collected ${_money(row.rentCollectedPaise)}',
            subline: 'Expenses ${_money(row.propertyExpensesPaise)}  |  Net cash ${_money(row.netCashFlowPaise)}  |  Occupancy ${row.occupancyRatePercent.toStringAsFixed(2)}%'));
        }
      }
      content.addAll([_section('Bills & Taxes - separate tracking'), _metrics([
        ('Raised', _money(s.bills.billsRaisedPaise)), ('Paid', _money(s.bills.billsPaidPaise)),
        ('Outstanding', _money(s.bills.billsOutstandingPaise)),
      ]), _section('Security deposits - separate funds'), _metrics([
        ('Agreed', _money(s.deposits.depositAgreedPaise)), ('Received', _money(s.deposits.depositReceivedPaise)),
        ('Refunded', _money(s.deposits.depositRefundedPaise)), ('Held', _money(s.deposits.depositCurrentlyHeldPaise)),
      ])]);
      content.add(_note('Security deposits and Bills & Taxes are separate funds/tracking and are not included in net property cash flow.'));
      break;
    case ReportExportKind.rent:
      content.addAll([_section('Rent collection KPIs'), _metrics([
        ('Expected rent', _money(r.expectedRentPaise)), ('Collected', _money(r.rentCollectedPaise)),
        ('Outstanding', _money(r.outstandingPaise)), ('Overdue', _money(r.overduePaise)),
        ('Collection rate', '${r.collectionRatePercent.toStringAsFixed(2)}%'),
      ]), _note('Due-date view. Collection rate uses cash-period payments linked to selected dues; balances are current.'), _section('Rent dues')]);
      if (data.rentRows.isEmpty) content.add(_note('No rent dues match the selected due-date scope.'));
      for (final row in data.rentRows) {
        content.add(await _row('${row.propertyName} / ${row.unitName} / ${row.tenantName}',
          '${row.periodKey}  |  Due ${_day(row.dueDate.toDate())}  |  ${_human(row.status)}',
          subline: 'Expected ${_money(row.expectedPaise)}  |  Paid to date ${_money(row.paidPaise)}  |  Balance ${_money(row.balancePaise)}'));
      }
      break;
    case ReportExportKind.property:
      content.add(_section('Property performance'));
      for (final row in data.performance) {
        content.add(await _row(row.propertyName, 'Expected ${_money(row.expectedRentPaise)}  |  Collected ${_money(row.rentCollectedPaise)}  |  Outstanding ${_money(row.outstandingPaise)}',
          subline: 'Expenses ${_money(row.propertyExpensesPaise)}  |  Net cash ${_money(row.netCashFlowPaise)}  |  Occupancy ${row.occupancyRatePercent.toStringAsFixed(2)}% (${row.occupiedUnits}/${row.totalRentableUnits})'));
      }
      break;
    case ReportExportKind.expenses:
      content.addAll([_section('Property expense KPIs'), _metrics([
        ('Total expenses', _money(s.expenses.totalExpensesPaise)), ('Expense count', '${s.expenses.expenseCount}'),
      ]), _section('By category')]);
      for (final item in s.expenses.byCategory) { content.add(await _row(_human(item.key), '${_money(item.amountPaise)}  |  ${item.count} expenses')); }
      content.add(_section('By property'));
      for (final item in s.expenses.byProperty) { content.add(await _row(data.propertyNames[item.key] ?? 'Property', '${_money(item.amountPaise)}  |  ${item.count} expenses')); }
      if (s.expenses.byUnit.isNotEmpty) {
        content.add(_section('By unit'));
        for (final item in s.expenses.byUnit) { content.add(await _row(data.unitNames[item.key] ?? 'Unit', '${_money(item.amountPaise)}  |  ${item.count} expenses')); }
      }
      content.add(_note('Bills & Taxes and security deposits are excluded from property expenses.'));
      break;
    case ReportExportKind.bills:
      content.addAll([_section('Bills & Taxes KPIs'), _metrics([
        ('Raised', _money(s.bills.billsRaisedPaise)), ('Paid', _money(s.bills.billsPaidPaise)),
        ('Outstanding', _money(s.bills.billsOutstandingPaise)), ('Overdue', _money(s.bills.billsOverduePaise)),
        ('Bill count', '${s.bills.billCount}'), ('Payment count', '${s.bills.paymentCount}'),
      ]), _section('Payments by bill type')]);
      if (s.bills.paymentsByBillType.isEmpty) content.add(_note('No bill payments match this period.'));
      for (final item in s.bills.paymentsByBillType) { content.add(await _row(_human(item.key), '${_money(item.amountPaise)}  |  ${item.count} payments')); }
      content.add(_note('Bills & Taxes are manual tracking and are separate from property expenses.'));
      break;
    case ReportExportKind.deposits:
      content.addAll([_section('Security deposit balances'), _metrics([
        ('Agreed', _money(s.deposits.depositAgreedPaise)), ('Received', _money(s.deposits.depositReceivedPaise)),
        ('Refunded', _money(s.deposits.depositRefundedPaise)), ('Currently held', _money(s.deposits.depositCurrentlyHeldPaise)),
        ('Transaction count', '${s.deposits.transactionCount}'),
      ]), _note('Security deposits are separate funds, not rental income or net property cash flow. Agreed and held are current balances; received and refunded follow transaction dates.')]);
      break;
    case ReportExportKind.occupancy:
      content.addAll([_section('Current occupancy'), _metrics([
        ('Rentable units', '${s.occupancy.totalRentableUnits}'), ('Occupied', '${s.occupancy.occupiedUnits}'),
        ('Vacant', '${s.occupancy.vacantUnits}'), ('Maintenance', '${s.occupancy.maintenanceUnits}'),
        ('Inactive', '${s.occupancy.inactiveUnits}'), ('Occupancy rate', '${s.occupancy.occupancyRatePercent.toStringAsFixed(2)}%'),
      ]), _section('Tenants & agreements'), _metrics([
        ('Active tenants', '${s.occupancy.activeTenants}'), ('Active agreements', '${s.occupancy.activeAgreements}'),
        ('Upcoming agreements', '${s.occupancy.upcomingAgreements}'), ('Ended agreements', '${s.occupancy.endedAgreements}'),
      ]), _note('Current occupancy snapshot, not historic occupancy as of the selected dates.')]);
      break;
    case ReportExportKind.history:
      final history = data.history!;
      content.add(await _row(data.agreementHistory ? 'Agreement rent history' : 'Tenant rent history', history.tenantName));
      content.addAll([_section('Rent history KPIs'), _metrics([
        ('Expected', _money(history.rent.expectedRentPaise)), ('Paid in period', _money(history.rent.rentCollectedPaise)),
        ('Outstanding', _money(history.rent.outstandingPaise)),
      ]), _section('Rent dues')]);
      if (history.dues.isEmpty) content.add(_note('No rent dues match this history period.'));
      for (final item in history.dues) {
        final location = '${data.propertyNames[item.propertyId] ?? 'Property'} / ${data.unitNames[item.unitId] ?? 'Unit'}';
        content.add(await _row(location, '${item.periodKey}  |  Due ${_day(item.date.toDate())}',
          subline: 'Expected ${_money(item.amountPaise)}  |  Paid to date ${_money(item.paidPaise ?? 0)}  |  Balance ${_money(item.balancePaise ?? 0)}'));
      }
      content.add(_section('Payment transactions'));
      if (history.payments.isEmpty) content.add(_note('No payment transactions match this history period.'));
      for (final item in history.payments) {
        final location = '${data.propertyNames[item.propertyId] ?? 'Property'} / ${data.unitNames[item.unitId] ?? 'Unit'}';
        content.add(await _row(location, '${item.periodKey}  |  Payment ${_day(item.date.toDate())}', subline: 'Amount ${_money(item.amountPaise)}'));
      }
      break;
  }

  final pdf = pw.Document();
  pdf.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(40, 50, 40, 48), maxPages: 1000,
    header: (_) => pw.Container(padding: const pw.EdgeInsets.only(bottom: 9), margin: const pw.EdgeInsets.only(bottom: 12),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.deepPurple, width: 1.5))),
      child: pw.Text('CREOVY HOMS', style: pw.TextStyle(color: PdfColors.deepPurple, fontSize: 13, fontWeight: pw.FontWeight.bold, letterSpacing: 1.5))),
    footer: (context) => pw.Container(padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: PdfColors.grey300))),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Generated from authorized workspace report data', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      ])),
    build: (_) => content));
  return pdf.save();
}
