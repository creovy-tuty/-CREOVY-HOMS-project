import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum DepositTransactionType { received, refunded }
enum DepositPaymentMode { cash, upi, bankTransfer, cheque, other }

extension DepositPaymentModeValue on DepositPaymentMode {
  String get firestoreValue => switch (this) {
    DepositPaymentMode.bankTransfer => 'bank_transfer',
    _ => name,
  };
}

class DepositSubmission {
  const DepositSubmission({
    required this.workspaceId,
    required this.agreementId,
    required this.submissionId,
    required this.amountPaise,
    required this.transactionDate,
    required this.paymentMode,
    this.referenceNumber = '',
    this.notes = '',
  });
  final String workspaceId;
  final String agreementId;
  final String submissionId;
  final int amountPaise;
  final DateTime transactionDate;
  final DepositPaymentMode paymentMode;
  final String referenceNumber;
  final String notes;
}

class DepositTransactionRecord {
  const DepositTransactionRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

class DepositSummaryRecord {
  const DepositSummaryRecord(this.data);
  final Map<String, dynamic> data;
}

class SecurityDepositRepository {
  SecurityDepositRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  static const _maxSafePaise = 9007199254740991;
  static final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');

  /// Generate once per intended movement and retain across retries.
  static String newSubmissionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Map<String, dynamic> _agreementSummary(String id, Map<String, dynamic> agreement) {
    final agreed = agreement['securityDepositAgreedPaise'];
    if (agreed is! int || agreed < 0 || agreed > _maxSafePaise) throw StateError('Agreement deposit amount is invalid.');
    for (final field in ['workspaceId', 'tenantId', 'propertyId', 'unitId']) {
      if (agreement[field] is! String || (agreement[field] as String).isEmpty) throw StateError('Agreement relationships are incomplete.');
    }
    return {
      'workspaceId': agreement['workspaceId'], 'agreementId': id, 'tenantId': agreement['tenantId'],
      'propertyId': agreement['propertyId'], 'unitId': agreement['unitId'],
      'agreedAmountPaise': agreed, 'totalReceivedPaise': 0, 'pendingToReceivePaise': agreed,
      'totalRefundedPaise': 0, 'heldBalancePaise': 0, 'lastTransactionId': null,
    };
  }

  Map<String, dynamic> _checkedSummary(Map<String, dynamic> base, Map<String, dynamic>? saved) {
    if (saved == null) return base;
    for (final field in ['workspaceId', 'agreementId', 'tenantId', 'propertyId', 'unitId', 'agreedAmountPaise']) {
      if (saved[field] != base[field]) throw StateError('Deposit summary relationships are inconsistent.');
    }
    final received = saved['totalReceivedPaise'];
    final refunded = saved['totalRefundedPaise'];
    final pending = saved['pendingToReceivePaise'];
    final held = saved['heldBalancePaise'];
    if (received is! int || refunded is! int || pending is! int || held is! int ||
        received < 0 || refunded < 0 || pending < 0 || held < 0 ||
        received > _maxSafePaise || refunded > _maxSafePaise || pending > _maxSafePaise || held > _maxSafePaise ||
        received > base['agreedAmountPaise'] || refunded > received ||
        pending != base['agreedAmountPaise'] - received || held != received - refunded ||
        saved['lastTransactionId'] is! String) {
      throw StateError('Deposit summary is inconsistent. No movement was recorded.');
    }
    return saved;
  }

  Future<DepositTransactionRecord> recordDepositReceived(DepositSubmission input) =>
      _recordDeposit(input, DepositTransactionType.received);

  Future<DepositTransactionRecord> recordDepositRefund(DepositSubmission input) =>
      _recordDeposit(input, DepositTransactionType.refunded);

  Future<DepositTransactionRecord> _recordDeposit(DepositSubmission input, DepositTransactionType type) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Sign in before recording a deposit movement.');
    if (input.workspaceId.isEmpty || input.agreementId.isEmpty) throw ArgumentError('Workspace and agreement are required.');
    if (!_uuidPattern.hasMatch(input.submissionId)) throw ArgumentError('A stable UUID submission ID is required.');
    if (input.amountPaise <= 0 || input.amountPaise > _maxSafePaise) throw ArgumentError('Amount must be positive integer paise.');
    final referenceNumber = input.referenceNumber.trim();
    final notes = input.notes.trim();
    if (referenceNumber.length > 200 || notes.length > 2000) throw ArgumentError('Reference or notes are too long.');

    final agreementRef = _firestore.collection('rentalAgreements').doc(input.agreementId);
    final summaryRef = _firestore.collection('securityDeposits').doc(input.agreementId);
    final movementRef = _firestore.collection('securityDepositTransactions').doc(input.submissionId);
    final receiptRef = _firestore.collection('securityDepositReceipts').doc(input.submissionId);
    final ledgerRef = _firestore.collection('securityDepositLedger').doc('deposit_${input.submissionId}');
    await _firestore.runTransaction((transaction) async {
      final agreement = await transaction.get(agreementRef);
      final summary = await transaction.get(summaryRef);
      final previous = await transaction.get(movementRef);
      if (!agreement.exists) throw StateError('Rental agreement could not be found.');
      final base = _agreementSummary(agreement.id, agreement.data()!);
      if (base['workspaceId'] != input.workspaceId) throw StateError('Agreement is outside the selected workspace.');
      final transactionDate = Timestamp.fromDate(DateTime.fromMillisecondsSinceEpoch(input.transactionDate.millisecondsSinceEpoch, isUtc: true));
      if (previous.exists) {
        final saved = previous.data()!;
        if (saved['workspaceId'] != input.workspaceId || saved['agreementId'] != input.agreementId ||
            saved['tenantId'] != base['tenantId'] || saved['propertyId'] != base['propertyId'] || saved['unitId'] != base['unitId'] ||
            saved['transactionType'] != type.name || saved['amountPaise'] != input.amountPaise ||
            saved['transactionDate'] is! Timestamp ||
            (saved['transactionDate'] as Timestamp).millisecondsSinceEpoch != transactionDate.millisecondsSinceEpoch ||
            saved['paymentMode'] != input.paymentMode.firestoreValue ||
            saved['referenceNumber'] != referenceNumber || saved['notes'] != notes ||
            saved['createdBy'] != user.uid || saved['submissionId'] != input.submissionId) {
          throw StateError('This submission ID already belongs to another deposit movement.');
        }
        return;
      }
      final current = _checkedSummary(base, summary.exists ? summary.data() : null);
      if (type == DepositTransactionType.received && input.amountPaise > current['pendingToReceivePaise']) {
        throw StateError('Deposit collection exceeds the contractual amount remaining.');
      }
      if (type == DepositTransactionType.refunded && input.amountPaise > current['heldBalancePaise']) {
        throw StateError('Refund exceeds the deposit currently held.');
      }
      final tenant = await transaction.get(_firestore.collection('tenants').doc(base['tenantId'] as String));
      final property = await transaction.get(_firestore.collection('properties').doc(base['propertyId'] as String));
      final unit = await transaction.get(_firestore.collection('units').doc(base['unitId'] as String));
      if (!tenant.exists || !property.exists || !unit.exists ||
          tenant.data()?['workspaceId'] != input.workspaceId || property.data()?['workspaceId'] != input.workspaceId ||
          unit.data()?['workspaceId'] != input.workspaceId || unit.data()?['propertyId'] != base['propertyId'] ||
          tenant.data()?['fullName'] is! String || property.data()?['name'] is! String || unit.data()?['name'] is! String) {
        throw StateError('Tenant, property, or unit details are unavailable. Deposit was not recorded.');
      }
      final received = (current['totalReceivedPaise'] as int) + (type == DepositTransactionType.received ? input.amountPaise : 0);
      final refunded = (current['totalRefundedPaise'] as int) + (type == DepositTransactionType.refunded ? input.amountPaise : 0);
      transaction.set(movementRef, {
        'workspaceId': base['workspaceId'], 'submissionId': input.submissionId, 'agreementId': base['agreementId'],
        'tenantId': base['tenantId'], 'propertyId': base['propertyId'], 'unitId': base['unitId'],
        'transactionType': type.name, 'amountPaise': input.amountPaise, 'transactionDate': transactionDate,
        'paymentMode': input.paymentMode.firestoreValue, 'referenceNumber': referenceNumber, 'notes': notes,
        'createdBy': user.uid, 'createdAt': FieldValue.serverTimestamp(),
      });
      final receiptNumber = '${type == DepositTransactionType.received ? 'CRV-D-R-' : 'CRV-D-F-'}${input.submissionId}';
      transaction.set(receiptRef, {
        'workspaceId': input.workspaceId, 'receiptNumber': receiptNumber, 'depositTransactionId': input.submissionId,
        'agreementId': base['agreementId'], 'tenantId': base['tenantId'], 'propertyId': base['propertyId'], 'unitId': base['unitId'],
        'tenantName': tenant.data()!['fullName'], 'propertyName': property.data()!['name'], 'unitName': unit.data()!['name'],
        'transactionType': type.name, 'amountPaise': input.amountPaise, 'transactionDate': transactionDate,
        'paymentMode': input.paymentMode.firestoreValue, 'referenceNumber': referenceNumber,
        'agreedAmountPaise': base['agreedAmountPaise'], 'totalReceivedPaise': received, 'heldBalancePaise': received - refunded,
        'createdBy': user.uid, 'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.set(ledgerRef, {
        'workspaceId': input.workspaceId, 'tenantId': base['tenantId'], 'agreementId': base['agreementId'],
        'propertyId': base['propertyId'], 'unitId': base['unitId'], 'depositTransactionId': input.submissionId,
        'depositReceiptId': input.submissionId,
        'entryType': type == DepositTransactionType.received ? 'deposit_received' : 'deposit_refunded',
        'amountPaise': input.amountPaise, 'transactionDate': transactionDate,
        'paymentMode': input.paymentMode.firestoreValue, 'referenceNumber': referenceNumber,
        'description': type == DepositTransactionType.received ? 'Security deposit received' : 'Security deposit refunded',
        'createdBy': user.uid, 'createdAt': FieldValue.serverTimestamp(),
      });
      final totals = {
        'totalReceivedPaise': received, 'pendingToReceivePaise': (base['agreedAmountPaise'] as int) - received,
        'totalRefundedPaise': refunded, 'heldBalancePaise': received - refunded,
        'lastTransactionId': input.submissionId, 'updatedAt': FieldValue.serverTimestamp(),
      };
      if (summary.exists) {
        transaction.update(summaryRef, totals);
      } else {
        transaction.set(summaryRef, {...base, ...totals, 'createdAt': FieldValue.serverTimestamp()});
      }
    });
    final saved = await movementRef.get();
    if (!saved.exists) throw StateError('Deposit movement committed but could not be reloaded. Retry with the same submission ID.');
    return DepositTransactionRecord(saved.id, saved.data()!);
  }

  Future<DepositSummaryRecord> getDepositSummary(String workspaceId, String agreementId) async {
    if (_auth.currentUser == null) throw StateError('Sign in to view deposits.');
    final agreement = await _firestore.collection('rentalAgreements').doc(agreementId).get();
    if (!agreement.exists) throw StateError('Rental agreement could not be found.');
    final base = _agreementSummary(agreement.id, agreement.data()!);
    if (base['workspaceId'] != workspaceId) throw StateError('Agreement is outside the selected workspace.');
    final summary = await _firestore.collection('securityDeposits').doc(agreementId).get();
    return DepositSummaryRecord(_checkedSummary(base, summary.exists ? summary.data() : null));
  }

  Future<DepositTransactionRecord?> getDepositTransaction(String workspaceId, String transactionId) async {
    if (_auth.currentUser == null) throw StateError('Sign in to view deposits.');
    final item = await _firestore.collection('securityDepositTransactions').doc(transactionId).get();
    return item.exists && item.data()?['workspaceId'] == workspaceId ? DepositTransactionRecord(item.id, item.data()!) : null;
  }

  Future<List<DepositTransactionRecord>> listDepositTransactions(String workspaceId, String agreementId) async {
    if (_auth.currentUser == null) throw StateError('Sign in to view deposits.');
    final snapshot = await _firestore.collection('securityDepositTransactions')
        .where('workspaceId', isEqualTo: workspaceId)
        .where('agreementId', isEqualTo: agreementId)
        .orderBy('transactionDate')
        .get();
    final movements = snapshot.docs.map((doc) => DepositTransactionRecord(doc.id, doc.data())).toList();
    movements.sort((a, b) {
      final dates = (a.data['transactionDate'] as Timestamp).compareTo(b.data['transactionDate'] as Timestamp);
      return dates != 0 ? dates : a.id.compareTo(b.id);
    });
    return movements;
  }

  /// Read-only live views of the same Firestore records used by Web.
  Stream<DepositSummaryRecord> watchDepositSummary(String workspaceId, String agreementId) =>
      _firestore.collection('securityDeposits').doc(agreementId).snapshots()
          .asyncMap((_) => getDepositSummary(workspaceId, agreementId));

  Stream<List<DepositTransactionRecord>> watchDepositTransactions(String workspaceId, String agreementId) =>
      _firestore.collection('securityDepositTransactions')
          .where('workspaceId', isEqualTo: workspaceId)
          .where('agreementId', isEqualTo: agreementId)
          .orderBy('transactionDate')
          .snapshots()
          .map((snapshot) {
            final movements = snapshot.docs.map((doc) => DepositTransactionRecord(doc.id, doc.data())).toList();
            movements.sort((a, b) {
              final dates = (a.data['transactionDate'] as Timestamp).compareTo(b.data['transactionDate'] as Timestamp);
              return dates != 0 ? dates : a.id.compareTo(b.id);
            });
            return movements;
          });
}
