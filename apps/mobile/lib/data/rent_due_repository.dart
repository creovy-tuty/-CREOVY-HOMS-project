import 'package:cloud_firestore/cloud_firestore.dart';
import 'tenant_repository.dart';

class RentDueRecord { RentDueRecord(this.id, this.data); final String id; final Map<String, dynamic> data; }
class RentDueRepository {
  RentDueRepository(this._firestore); final FirebaseFirestore _firestore;
  Stream<List<RentDueRecord>> watchDues(String workspaceId) => _firestore.collection('rentDues').where('workspaceId', isEqualTo: workspaceId).snapshots().map((value) => value.docs.map((item) => RentDueRecord(item.id, item.data())).toList());
  Stream<RentDueRecord?> watchDue(String workspaceId, String rentDueId) => _firestore.collection('rentDues').doc(rentDueId).snapshots().map((item) => item.exists && item.data()?['workspaceId'] == workspaceId ? RentDueRecord(item.id, item.data()!) : null);
  Future<RentDueRecord?> getDue(String workspaceId, String rentDueId) async { final item = await _firestore.collection('rentDues').doc(rentDueId).get(const GetOptions(source: Source.server)); return item.exists && item.data()?['workspaceId'] == workspaceId ? RentDueRecord(item.id, item.data()!) : null; }
  DateTime businessToday() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    return DateTime.utc(now.year, now.month, now.day);
  }
  bool isOverdue(RentDueRecord due) {
    final date = due.data['dueDate'];
    if (date is! Timestamp || (due.data['balancePaise'] as num? ?? 0) <= 0) return false;
    final local = date.toDate().toUtc().add(const Duration(hours: 5, minutes: 30));
    return DateTime.utc(local.year, local.month, local.day).isBefore(businessToday());
  }
  Future<void> refreshOverdue(List<RentDueRecord> dues) async {
    for (final due in dues) {
      if (due.data['status'] != 'pending' || !isOverdue(due)) continue;
      final reference = _firestore.collection('rentDues').doc(due.id);
      await _firestore.runTransaction((tx) async {
        final current = await tx.get(reference);
        if (!current.exists || current.data()?['status'] != 'pending') return;
        final latest = RentDueRecord(due.id, current.data()!);
        if (!isOverdue(latest)) return;
        tx.update(reference, {'status': 'overdue', 'updatedAt': FieldValue.serverTimestamp()});
      });
    }
  }
  String periodKey(int year, int month) => '$year-${month.toString().padLeft(2, '0')}';
  DateTime dueDateFor(int year, int month, int dueDay) { final last = DateTime.utc(year, month + 1, 0).day; return DateTime.utc(year, month, dueDay.clamp(1, last).toInt() - 1, 18, 30); }
  Future<void> ensureDues(String workspaceId, List<AgreementRecord> agreements) async { final now = businessToday(); for (final entry in agreements) { final a = entry.data; final status = a['status'] as String? ?? 'draft'; if (status == 'draft' || status == 'cancelled' || a['workspaceId'] != workspaceId) continue; final start = DateTime.parse(a['startDate'] as String); final end = a['endDate'] == null ? now : DateTime.parse(a['endDate'] as String); var cursor = DateTime(start.year, start.month); final cap = DateTime(end.year, end.month); final current = DateTime(now.year, now.month); while (!cursor.isAfter(cap) && !cursor.isAfter(current)) { final key = periodKey(cursor.year, cursor.month); final id = '${entry.id}_$key'; final date = dueDateFor(cursor.year, cursor.month, a['rentDueDay'] as int); final due = _firestore.collection('rentDues').doc(id); await _firestore.runTransaction((tx) async { if ((await tx.get(due)).exists) return; tx.set(due, {'workspaceId': workspaceId, 'agreementId': entry.id, 'tenantId': a['tenantId'], 'propertyId': a['propertyId'], 'unitId': a['unitId'], 'rentYear': cursor.year, 'rentMonth': cursor.month, 'periodKey': key, 'dueDate': Timestamp.fromDate(date), 'rentAmountPaise': a['monthlyRentPaise'], 'totalPaidPaise': 0, 'balancePaise': a['monthlyRentPaise'], 'status': DateTime.utc(cursor.year, cursor.month, (a['rentDueDay'] as int).clamp(1, DateTime.utc(cursor.year, cursor.month + 1, 0).day).toInt()).isBefore(now) ? 'overdue' : 'pending', 'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()}); }); cursor = DateTime(cursor.year, cursor.month + 1); } } }
}
