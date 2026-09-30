import 'package:cloud_firestore/cloud_firestore.dart';

/// Inclusive Asia/Kolkata calendar-day bounds. Context IDs are optional and
/// apply only to collections that actually carry that relationship.
class ReportFilters {
  const ReportFilters({this.from, this.through, this.propertyId, this.unitId,
    this.tenantId, this.agreementId, this.rentStatus, this.billType, this.expenseCategory});
  final DateTime? from, through;
  final String? propertyId, unitId, tenantId, agreementId, rentStatus, billType, expenseCategory;
  ReportFilters copyWith({String? tenantId, String? propertyId}) => ReportFilters(from: from, through: through,
    propertyId: propertyId ?? this.propertyId, unitId: unitId, tenantId: tenantId ?? this.tenantId,
    agreementId: agreementId, rentStatus: rentStatus, billType: billType, expenseCategory: expenseCategory);
}
class ReportMoneyGroup {
  const ReportMoneyGroup(this.key, this.amountPaise, this.count);
  final String key;
  final int amountPaise, count;
}
class RentReport {
  const RentReport({required this.expectedRentPaise, required this.rentCollectedPaise,
    required this.collectedAgainstExpectedPaise, required this.outstandingPaise,
    required this.overduePaise, required this.collectionRatePercent, required this.dueCount,
    required this.paymentCount, required this.asOfBusinessDate});
  final int expectedRentPaise, rentCollectedPaise, collectedAgainstExpectedPaise, outstandingPaise, overduePaise, dueCount, paymentCount;
  final double collectionRatePercent;
  final String asOfBusinessDate;
}
class ExpenseReport {
  const ExpenseReport({required this.totalExpensesPaise, required this.expenseCount,
    required this.byCategory, required this.byProperty, required this.byUnit});
  final int totalExpensesPaise, expenseCount;
  final List<ReportMoneyGroup> byCategory, byProperty, byUnit;
}
class BillsReport {
  const BillsReport({required this.billsRaisedPaise, required this.billsPaidPaise,
    required this.billsOutstandingPaise, required this.billsOverduePaise,
    required this.paymentsByBillType, required this.billCount, required this.paymentCount,
    required this.asOfBusinessDate});
  final int billsRaisedPaise, billsPaidPaise, billsOutstandingPaise, billsOverduePaise, billCount, paymentCount;
  final List<ReportMoneyGroup> paymentsByBillType;
  final String asOfBusinessDate;
}
class DepositReport {
  const DepositReport({required this.depositAgreedPaise, required this.depositReceivedPaise,
    required this.depositRefundedPaise, required this.depositCurrentlyHeldPaise, required this.transactionCount});
  final int depositAgreedPaise, depositReceivedPaise, depositRefundedPaise, depositCurrentlyHeldPaise, transactionCount;
}
class OccupancyReport {
  const OccupancyReport({required this.totalRentableUnits, required this.occupiedUnits,
    required this.vacantUnits, required this.maintenanceUnits, required this.inactiveUnits,
    required this.occupancyRatePercent, required this.activeTenants, required this.activeAgreements,
    required this.upcomingAgreements, required this.endedAgreements});
  final int totalRentableUnits, occupiedUnits, vacantUnits, maintenanceUnits, inactiveUnits;
  final int activeTenants, activeAgreements, upcomingAgreements, endedAgreements;
  final double occupancyRatePercent;
}
class PortfolioSummary {
  const PortfolioSummary({required this.rent, required this.expenses, required this.bills,
    required this.deposits, required this.occupancy, required this.netPropertyCashFlowPaise});
  final RentReport rent;
  final ExpenseReport expenses;
  final BillsReport bills;
  final DepositReport deposits;
  final OccupancyReport occupancy;
  final int netPropertyCashFlowPaise;
}
class PropertyPerformanceRow {
  const PropertyPerformanceRow({required this.propertyId, required this.propertyName,
    required this.expectedRentPaise, required this.rentCollectedPaise, required this.outstandingPaise,
    required this.propertyExpensesPaise, required this.netCashFlowPaise,
    required this.totalRentableUnits, required this.occupiedUnits, required this.occupancyRatePercent});
  final String propertyId, propertyName;
  final int expectedRentPaise, rentCollectedPaise, outstandingPaise, propertyExpensesPaise, netCashFlowPaise;
  final int totalRentableUnits, occupiedUnits;
  final double occupancyRatePercent;
}
class ReportHistoryRow {
  const ReportHistoryRow({required this.id, required this.agreementId, required this.propertyId,
    required this.unitId, required this.periodKey, required this.amountPaise, required this.date, this.paidPaise, this.balancePaise});
  final String id, agreementId, propertyId, unitId, periodKey;
  final int amountPaise;
  final int? paidPaise, balancePaise;
  final Timestamp date;
}
class TenantRentReport {
  const TenantRentReport({required this.tenantId, required this.tenantName,
    required this.rent, required this.dues, required this.payments});
  final String tenantId, tenantName;
  final RentReport rent;
  final List<ReportHistoryRow> dues, payments;
}
class ReportRentRow {
  const ReportRentRow({required this.dueId, required this.tenantId, required this.tenantName,
    required this.agreementId, required this.propertyId, required this.propertyName,
    required this.unitId, required this.unitName, required this.periodKey, required this.dueDate,
    required this.expectedPaise, required this.paidPaise, required this.balancePaise, required this.status});
  final String dueId, tenantId, tenantName, agreementId, propertyId, propertyName, unitId, unitName, periodKey, status;
  final Timestamp dueDate;
  final int expectedPaise, paidPaise, balancePaise;
}
class MonthlyCashFlowRow {
  const MonthlyCashFlowRow({required this.periodKey, required this.expectedRentPaise,
    required this.rentCollectedPaise, required this.propertyExpensesPaise, required this.netCashFlowPaise});
  final String periodKey;
  final int expectedRentPaise, rentCollectedPaise, propertyExpensesPaise, netCashFlowPaise;
}
