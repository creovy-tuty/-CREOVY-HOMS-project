import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class DepositReceiptRecord {
  const DepositReceiptRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
  String get receiptNumber => data['receiptNumber'] as String;
  String get depositTransactionId => data['depositTransactionId'] as String;
  String get transactionType => data['transactionType'] as String;
  String get tenantName => data['tenantName'] as String;
  String get propertyName => data['propertyName'] as String;
  String get unitName => data['unitName'] as String;
  int get amountPaise => data['amountPaise'] as int;
  Timestamp get transactionDate => data['transactionDate'] as Timestamp;
  String get paymentMode => data['paymentMode'] as String;
  String get referenceNumber => data['referenceNumber'] as String;
}

class DepositLedgerRecord {
  const DepositLedgerRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

class SecurityDepositFinancialRepository {
  SecurityDepositFinancialRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  void _requireSignIn() { if (_auth.currentUser == null) throw StateError('Sign in to view deposit records.'); }

  /// Pre-Step 7C transactions may not have receipts. Never backfill on read.
  Future<DepositReceiptRecord?> getDepositReceipt(String workspaceId, String transactionId) async {
    _requireSignIn();
    final item = await _firestore.collection('securityDepositReceipts').doc(transactionId).get();
    return item.exists && item.data()?['workspaceId'] == workspaceId ? DepositReceiptRecord(item.id, item.data()!) : null;
  }

  Future<DepositLedgerRecord?> getDepositLedgerEntry(String workspaceId, String transactionId) async {
    _requireSignIn();
    final item = await _firestore.collection('securityDepositLedger').doc('deposit_$transactionId').get();
    return item.exists && item.data()?['workspaceId'] == workspaceId ? DepositLedgerRecord(item.id, item.data()!) : null;
  }

  Future<List<DepositLedgerRecord>> listDepositLedger(String workspaceId, String agreementId) async {
    _requireSignIn();
    final result = await _firestore.collection('securityDepositLedger')
        .where('workspaceId', isEqualTo: workspaceId).where('agreementId', isEqualTo: agreementId)
        .orderBy('transactionDate').get();
    return result.docs.map((item) => DepositLedgerRecord(item.id, item.data())).toList();
  }

  Stream<List<DepositLedgerRecord>> watchDepositLedger(String workspaceId, String agreementId) =>
      _firestore.collection('securityDepositLedger')
          .where('workspaceId', isEqualTo: workspaceId).where('agreementId', isEqualTo: agreementId)
          .orderBy('transactionDate').snapshots().map((result) => result.docs.map((item) => DepositLedgerRecord(item.id, item.data())).toList());
}
