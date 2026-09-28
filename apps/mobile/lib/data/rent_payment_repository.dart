import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum RentPaymentMode { cash, upi, bankTransfer, cheque, other }

extension RentPaymentModeValue on RentPaymentMode {
  String get firestoreValue => switch (this) {
    RentPaymentMode.bankTransfer => 'bank_transfer',
    _ => name,
  };
}

class RentPaymentRecord {
  const RentPaymentRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}

class RentPaymentSubmission {
  const RentPaymentSubmission({
    required this.workspaceId,
    required this.rentDueId,
    required this.submissionId,
    required this.amountPaise,
    required this.paymentDate,
    required this.paymentMode,
    this.referenceNumber = '',
    this.notes = '',
  });
  final String workspaceId;
  final String rentDueId;
  final String submissionId;
  final int amountPaise;
  final DateTime paymentDate;
  final RentPaymentMode paymentMode;
  final String referenceNumber;
  final String notes;
}

class RentPaymentRepository {
  RentPaymentRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Generate once per intended submission and retain across retries.
  static String newSubmissionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// The caller creates one UUID per intended payment and retains it across retries.
  /// A retried submission returns the existing record without charging the due again.
  Future<RentPaymentRecord> recordPayment(RentPaymentSubmission input) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Sign in before recording a payment.');
    if (!RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$').hasMatch(input.submissionId)) {
      throw ArgumentError('A valid stable payment submission ID is required.');
    }
    if (input.amountPaise <= 0 || input.amountPaise > 9007199254740991) throw ArgumentError('Payment must be a positive safe integer amount in paise.');
    if (input.referenceNumber.trim().length > 200 || input.notes.trim().length > 2000) throw ArgumentError('Payment reference or notes are too long.');
    if (input.workspaceId.isEmpty || input.rentDueId.isEmpty) throw ArgumentError('A workspace and rent due are required.');

    final dueRef = _firestore.collection('rentDues').doc(input.rentDueId);
    final paymentRef = _firestore.collection('rentPayments').doc(input.submissionId);
    final receiptRef = _firestore.collection('receipts').doc(input.submissionId);
    final ledgerRef = _firestore.collection('tenantLedger').doc('rent_payment_${input.submissionId}');
    await _firestore.runTransaction((transaction) async {
      final due = await transaction.get(dueRef);
      final previous = await transaction.get(paymentRef);
      if (previous.exists) {
        final saved = previous.data()!;
        if (saved['workspaceId'] != input.workspaceId || saved['rentDueId'] != input.rentDueId ||
            saved['amountPaise'] != input.amountPaise || saved['createdBy'] != user.uid ||
            saved['paymentMode'] != input.paymentMode.firestoreValue ||
            (saved['paymentDate'] as Timestamp).millisecondsSinceEpoch != input.paymentDate.millisecondsSinceEpoch ||
            saved['referenceNumber'] != input.referenceNumber.trim() ||
            saved['notes'] != input.notes.trim()) {
          throw StateError('This submission ID already belongs to another payment.');
        }
        return;
      }
      if (!due.exists) throw StateError('Rent due could not be found.');
      final current = due.data()!;
      if (current['workspaceId'] != input.workspaceId) throw StateError('Rent due is outside the selected workspace.');
      final rentAmount = current['rentAmountPaise'];
      final paid = current['totalPaidPaise'];
      final balance = current['balancePaise'];
      if (rentAmount is! int || paid is! int || balance is! int ||
          rentAmount < 0 || rentAmount > 9007199254740991 ||
          paid < 0 || paid > 9007199254740991 ||
          balance < 0 || balance > 9007199254740991 ||
          paid + balance != rentAmount) {
        throw StateError('Rent due totals are inconsistent. Payment was not recorded.');
      }
      if ((paid == 0 && balance > 0 && current['status'] != 'pending' && current['status'] != 'overdue') ||
          (paid > 0 && balance > 0 && current['status'] != 'partial') ||
          (balance == 0 && current['status'] != 'paid')) {
        throw StateError('Rent due status is inconsistent. Payment was not recorded.');
      }
      if (balance == 0) throw StateError('This rent due is already fully paid.');
      if (input.amountPaise > balance) throw StateError('Payment exceeds the outstanding balance.');

      final tenant = await transaction.get(_firestore.collection('tenants').doc(current['tenantId'] as String));
      final property = await transaction.get(_firestore.collection('properties').doc(current['propertyId'] as String));
      final unit = await transaction.get(_firestore.collection('units').doc(current['unitId'] as String));
      if (!tenant.exists || !property.exists || !unit.exists ||
          tenant.data()?['workspaceId'] != input.workspaceId || property.data()?['workspaceId'] != input.workspaceId ||
          unit.data()?['workspaceId'] != input.workspaceId) {
        throw StateError('The tenant, property, or unit snapshot is unavailable. Payment was not recorded.');
      }

      final nextPaid = paid + input.amountPaise;
      final nextBalance = balance - input.amountPaise;
      final paymentDate = Timestamp.fromDate(DateTime.fromMillisecondsSinceEpoch(input.paymentDate.millisecondsSinceEpoch, isUtc: true));
      transaction.set(paymentRef, {
        'submissionId': input.submissionId,
        'workspaceId': input.workspaceId,
        'rentDueId': input.rentDueId,
        'agreementId': current['agreementId'],
        'tenantId': current['tenantId'],
        'propertyId': current['propertyId'],
        'unitId': current['unitId'],
        'periodKey': current['periodKey'],
        'amountPaise': input.amountPaise,
        'paymentDate': paymentDate,
        'paymentMode': input.paymentMode.firestoreValue,
        'referenceNumber': input.referenceNumber.trim(),
        'notes': input.notes.trim(),
        'createdBy': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.set(receiptRef, {
        'workspaceId': input.workspaceId,
        'receiptNumber': 'CRV-R-${input.submissionId}',
        'paymentId': input.submissionId,
        'rentDueId': input.rentDueId,
        'agreementId': current['agreementId'],
        'tenantId': current['tenantId'],
        'tenantName': tenant.data()!['fullName'],
        'propertyId': current['propertyId'],
        'propertyName': property.data()!['name'],
        'unitId': current['unitId'],
        'unitName': unit.data()!['name'],
        'periodKey': current['periodKey'],
        'amountPaise': input.amountPaise,
        'paymentDate': paymentDate,
        'paymentMode': input.paymentMode.firestoreValue,
        'referenceNumber': input.referenceNumber.trim(),
        'createdBy': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.set(ledgerRef, {
        'workspaceId': input.workspaceId,
        'tenantId': current['tenantId'],
        'agreementId': current['agreementId'],
        'propertyId': current['propertyId'],
        'unitId': current['unitId'],
        'rentDueId': input.rentDueId,
        'paymentId': input.submissionId,
        'receiptId': receiptRef.id,
        'periodKey': current['periodKey'],
        'entryType': 'rent_payment',
        'amountPaise': input.amountPaise,
        'transactionDate': paymentDate,
        'paymentMode': input.paymentMode.firestoreValue,
        'referenceNumber': input.referenceNumber.trim(),
        'description': 'Rent payment for ${current['periodKey']}',
        'createdBy': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.update(dueRef, {
        'totalPaidPaise': nextPaid,
        'balancePaise': nextBalance,
        'status': nextBalance == 0 ? 'paid' : 'partial',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    final saved = await paymentRef.get();
    if (!saved.exists) throw StateError('Payment committed but could not be reloaded. Retry with the same submission ID.');
    return RentPaymentRecord(saved.id, saved.data()!);
  }

  Future<List<RentPaymentRecord>> listPaymentsForDue(String workspaceId, String rentDueId) async {
    if (_auth.currentUser == null) throw StateError('Sign in to view payments.');
    final snapshot = await _firestore.collection('rentPayments')
        .where('workspaceId', isEqualTo: workspaceId)
        .where('rentDueId', isEqualTo: rentDueId)
        .orderBy('paymentDate')
        .get();
    final payments = snapshot.docs.map((doc) => RentPaymentRecord(doc.id, doc.data())).toList();
    payments.sort((a, b) {
      final dates = (a.data['paymentDate'] as Timestamp).compareTo(b.data['paymentDate'] as Timestamp);
      return dates != 0 ? dates : a.id.compareTo(b.id);
    });
    return payments;
  }
}
