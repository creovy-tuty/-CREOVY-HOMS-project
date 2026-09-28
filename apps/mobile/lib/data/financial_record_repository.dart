import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RentReceiptRecord {
  const RentReceiptRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
  String get workspaceId => data['workspaceId'] as String;
  String get receiptNumber => data['receiptNumber'] as String;
  String get paymentId => data['paymentId'] as String;
  String get rentDueId => data['rentDueId'] as String;
  String get agreementId => data['agreementId'] as String;
  String get tenantId => data['tenantId'] as String;
  String get tenantName => data['tenantName'] as String;
  String get propertyId => data['propertyId'] as String;
  String get propertyName => data['propertyName'] as String;
  String get unitId => data['unitId'] as String;
  String get unitName => data['unitName'] as String;
  String get periodKey => data['periodKey'] as String;
  int get amountPaise => data['amountPaise'] as int;
  Timestamp get paymentDate => data['paymentDate'] as Timestamp;
  String get paymentMode => data['paymentMode'] as String;
  String get referenceNumber => data['referenceNumber'] as String;
  String get createdBy => data['createdBy'] as String;
  Timestamp get createdAt => data['createdAt'] as Timestamp;
}

class RentLedgerEntryRecord {
  const RentLedgerEntryRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
  String get workspaceId => data['workspaceId'] as String;
  String get tenantId => data['tenantId'] as String;
  String get agreementId => data['agreementId'] as String;
  String get propertyId => data['propertyId'] as String;
  String get unitId => data['unitId'] as String;
  String get rentDueId => data['rentDueId'] as String;
  String get paymentId => data['paymentId'] as String;
  String get receiptId => data['receiptId'] as String;
  String get periodKey => data['periodKey'] as String;
  String get entryType => data['entryType'] as String;
  int get amountPaise => data['amountPaise'] as int;
  Timestamp get transactionDate => data['transactionDate'] as Timestamp;
  String get paymentMode => data['paymentMode'] as String;
  String get referenceNumber => data['referenceNumber'] as String;
  String get description => data['description'] as String;
  String get createdBy => data['createdBy'] as String;
  Timestamp get createdAt => data['createdAt'] as Timestamp;
}

class FinancialRecordRepository {
  FinancialRecordRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  void _requireSignIn() { if (_auth.currentUser == null) throw StateError('Sign in to view financial records.'); }

  /// The receipt document ID equals the payment UUID. Pre-Step 6C payments may return null.
  Future<RentReceiptRecord?> getReceiptByPayment(String workspaceId, String paymentId) async {
    _requireSignIn();
    final item = await _firestore.collection('receipts').doc(paymentId).get();
    return item.exists && item.data()?['workspaceId'] == workspaceId ? RentReceiptRecord(item.id, item.data()!) : null;
  }

  Future<List<RentReceiptRecord>> listReceiptsForTenant(String workspaceId, String tenantId) async {
    _requireSignIn();
    final result = await _firestore.collection('receipts').where('workspaceId', isEqualTo: workspaceId)
        .where('tenantId', isEqualTo: tenantId).orderBy('createdAt', descending: true).get();
    return result.docs.map((item) => RentReceiptRecord(item.id, item.data())).toList();
  }

  Future<List<RentReceiptRecord>> listWorkspaceReceipts(String workspaceId) async {
    _requireSignIn();
    final result = await _firestore.collection('receipts').where('workspaceId', isEqualTo: workspaceId)
        .orderBy('createdAt', descending: true).get();
    return result.docs.map((item) => RentReceiptRecord(item.id, item.data())).toList();
  }

  Future<RentReceiptRecord?> findReceiptByNumber(String workspaceId, String receiptNumber) async {
    _requireSignIn();
    final result = await _firestore.collection('receipts').where('workspaceId', isEqualTo: workspaceId)
        .where('receiptNumber', isEqualTo: receiptNumber).limit(1).get();
    return result.docs.isEmpty ? null : RentReceiptRecord(result.docs.first.id, result.docs.first.data());
  }

  Future<List<RentLedgerEntryRecord>> listTenantLedger(String workspaceId, String tenantId) async {
    _requireSignIn();
    final result = await _firestore.collection('tenantLedger').where('workspaceId', isEqualTo: workspaceId)
        .where('tenantId', isEqualTo: tenantId).orderBy('transactionDate').get();
    final entries = result.docs.map((item) => RentLedgerEntryRecord(item.id, item.data())).toList();
    entries.sort((a, b) { final dates = (a.data['transactionDate'] as Timestamp).compareTo(b.data['transactionDate'] as Timestamp); return dates != 0 ? dates : a.id.compareTo(b.id); });
    return entries;
  }

  Future<List<RentLedgerEntryRecord>> listAgreementLedger(String workspaceId, String agreementId) async {
    _requireSignIn();
    final result = await _firestore.collection('tenantLedger').where('workspaceId', isEqualTo: workspaceId)
        .where('agreementId', isEqualTo: agreementId).orderBy('transactionDate').get();
    final entries = result.docs.map((item) => RentLedgerEntryRecord(item.id, item.data())).toList();
    entries.sort((a, b) { final dates = (a.data['transactionDate'] as Timestamp).compareTo(b.data['transactionDate'] as Timestamp); return dates != 0 ? dates : a.id.compareTo(b.id); });
    return entries;
  }
}
