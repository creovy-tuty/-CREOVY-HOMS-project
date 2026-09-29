import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum PropertyBillType { electricity, waterTax, propertyTax, other }
enum PropertyBillStatus { pending, partial, paid, overdue }
extension PropertyBillTypeValue on PropertyBillType {
  String get firestoreValue => switch (this) {
    PropertyBillType.waterTax => 'water_tax',
    PropertyBillType.propertyTax => 'property_tax',
    _ => name,
  };
}
enum PropertyBillPaymentMode { cash, upi, bankTransfer, cheque, other }
extension PropertyBillPaymentModeValue on PropertyBillPaymentMode {
  String get firestoreValue => this == PropertyBillPaymentMode.bankTransfer ? 'bank_transfer' : name;
}

class PropertyBillRecord {
  const PropertyBillRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}
class PropertyBillPaymentRecord {
  const PropertyBillPaymentRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}
class PropertyBillDraft {
  const PropertyBillDraft({required this.workspaceId, required this.propertyId, required this.billType,
    required this.providerName, required this.billDate, required this.dueDate, required this.amountPaise,
    this.unitId, this.consumerNumber = '', this.periodKey = '', this.notes = ''});
  final String workspaceId, propertyId, providerName, consumerNumber, periodKey, notes;
  final String? unitId;
  final PropertyBillType billType;
  final DateTime billDate, dueDate;
  final int amountPaise;
}
class SafePropertyBillMetadata {
  const SafePropertyBillMetadata({this.providerName, this.consumerNumber, this.periodKey,
    this.billDate, this.dueDate, this.amountPaise, this.notes});
  final String? providerName, consumerNumber, periodKey, notes;
  final DateTime? billDate, dueDate;
  final int? amountPaise;
}
class PropertyBillPaymentSubmission {
  const PropertyBillPaymentSubmission({required this.workspaceId, required this.billId, required this.submissionId,
    required this.amountPaise, required this.paymentDate, required this.paymentMode,
    this.referenceNumber = '', this.notes = ''});
  final String workspaceId, billId, submissionId, referenceNumber, notes;
  final int amountPaise;
  final DateTime paymentDate;
  final PropertyBillPaymentMode paymentMode;
}

class PropertyBillRepository {
  PropertyBillRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  static const _maxPaise = 9007199254740991;
  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');
  static const _indiaOffset = Duration(hours: 5, minutes: 30);

  /// Generate once per intended payment and keep the ID and payload on retry.
  static String newPaymentSubmissionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _signedIn() { if (_auth.currentUser == null) throw StateError('Sign in to manage bills.'); }
  bool _validMoney(int value) => value > 0 && value <= _maxPaise;
  String _text(String value, int limit) {
    final clean = value.trim();
    if (clean.length > limit) throw ArgumentError('Text exceeds $limit characters.');
    return clean;
  }
  DateTime _indiaDay(DateTime instant) => instant.toUtc().add(_indiaOffset);
  Timestamp _indiaMidnight(DateTime day) {
    final india = _indiaDay(day);
    return Timestamp.fromDate(DateTime.utc(india.year, india.month, india.day).subtract(_indiaOffset));
  }
  bool _overdue(Timestamp dueDate) => !DateTime.now().toUtc().isBefore(
    dueDate.toDate().toUtc().add(const Duration(days: 1)));
  bool isBillLate(PropertyBillRecord bill) => (bill.data['balancePaise'] as int) > 0 &&
    _overdue(bill.data['dueDate'] as Timestamp);
  String _status(int paid, int balance, Timestamp dueDate) =>
    balance == 0 ? 'paid' : paid > 0 ? 'partial' : _overdue(dueDate) ? 'overdue' : 'pending';
  void _assertTotals(Map<String, dynamic> bill) {
    final amount = bill['amountPaise']; final paid = bill['totalPaidPaise']; final balance = bill['balancePaise'];
    if (amount is! int || paid is! int || balance is! int || !_validMoney(amount) ||
        paid < 0 || balance < 0 || paid + balance != amount || bill['dueDate'] is! Timestamp ||
        !(balance == 0 && bill['status'] == 'paid' || paid > 0 && balance > 0 && bill['status'] == 'partial' ||
          paid == 0 && balance > 0 && (bill['status'] == 'pending' || bill['status'] == 'overdue'))) {
      throw StateError('Bill totals or status are inconsistent.');
    }
  }

  Future<PropertyBillRecord> createBill(PropertyBillDraft input) async {
    _signedIn();
    final userId = _auth.currentUser!.uid;
    if (input.workspaceId.isEmpty || input.propertyId.isEmpty || !_validMoney(input.amountPaise)) throw ArgumentError('Invalid bill details.');
    final provider = _text(input.providerName, 200);
    if (provider.isEmpty) throw ArgumentError('Provider or authority name is required.');
    final billDate = Timestamp.fromDate(input.billDate.toUtc());
    final dueDate = _indiaMidnight(input.dueDate);
    if (dueDate.millisecondsSinceEpoch < _indiaMidnight(input.billDate).millisecondsSinceEpoch) throw ArgumentError('Due date precedes bill date.');
    final billRef = _firestore.collection('propertyBills').doc();
    await _firestore.runTransaction((tx) async {
      final property = await tx.get(_firestore.collection('properties').doc(input.propertyId));
      final unit = input.unitId == null ? null : await tx.get(_firestore.collection('units').doc(input.unitId));
      if (!property.exists || property.data()?['workspaceId'] != input.workspaceId ||
          unit != null && (!unit.exists || unit.data()?['workspaceId'] != input.workspaceId || unit.data()?['propertyId'] != input.propertyId)) {
        throw StateError('Property or unit does not belong to this workspace.');
      }
      tx.set(billRef, {
        'workspaceId': input.workspaceId, 'propertyId': input.propertyId, 'unitId': input.unitId,
        'billType': input.billType.firestoreValue, 'providerName': provider,
        'consumerNumber': _text(input.consumerNumber, 200), 'periodKey': _text(input.periodKey, 40),
        'billDate': billDate, 'dueDate': dueDate, 'amountPaise': input.amountPaise,
        'totalPaidPaise': 0, 'balancePaise': input.amountPaise, 'status': _status(0, input.amountPaise, dueDate),
        'notes': _text(input.notes, 2000), 'lastPaymentId': null, 'createdBy': userId,
        'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    final saved = await billRef.get();
    if (!saved.exists) throw StateError('Bill was created but could not be reloaded.');
    return PropertyBillRecord(saved.id, saved.data()!);
  }

  Future<PropertyBillRecord> updateSafeBillMetadata(String workspaceId, String billId, SafePropertyBillMetadata changes) async {
    _signedIn();
    final reference = _firestore.collection('propertyBills').doc(billId);
    await _firestore.runTransaction((tx) async {
      final snapshot = await tx.get(reference);
      if (!snapshot.exists || snapshot.data()?['workspaceId'] != workspaceId) throw StateError('Bill not found in workspace.');
      final current = snapshot.data()!; _assertTotals(current);
      if ((current['totalPaidPaise'] != 0 || current['lastPaymentId'] != null) &&
          (changes.amountPaise != null || changes.providerName != null || changes.consumerNumber != null ||
           changes.periodKey != null || changes.billDate != null || changes.dueDate != null)) {
        throw StateError('Only notes can be edited after a payment.');
      }
      final amount = changes.amountPaise ?? current['amountPaise'] as int;
      if (!_validMoney(amount)) throw ArgumentError('Amount must be positive integer paise.');
      final billDate = changes.billDate == null ? current['billDate'] as Timestamp : Timestamp.fromDate(changes.billDate!.toUtc());
      final dueDate = changes.dueDate == null ? current['dueDate'] as Timestamp : _indiaMidnight(changes.dueDate!);
      if (dueDate.millisecondsSinceEpoch < _indiaMidnight(billDate.toDate()).millisecondsSinceEpoch) throw ArgumentError('Due date precedes bill date.');
      final provider = changes.providerName == null ? current['providerName'] as String : _text(changes.providerName!, 200);
      if (provider.isEmpty) throw ArgumentError('Provider or authority name is required.');
      tx.update(reference, {
        'providerName': provider,
        'consumerNumber': changes.consumerNumber == null ? current['consumerNumber'] : _text(changes.consumerNumber!, 200),
        'periodKey': changes.periodKey == null ? current['periodKey'] : _text(changes.periodKey!, 40),
        'notes': changes.notes == null ? current['notes'] : _text(changes.notes!, 2000),
        'billDate': billDate, 'dueDate': dueDate, 'amountPaise': amount,
        'balancePaise': amount - (current['totalPaidPaise'] as int),
        'status': _status(current['totalPaidPaise'] as int, amount - (current['totalPaidPaise'] as int), dueDate),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    final saved = await reference.get();
    if (!saved.exists) throw StateError('Bill was updated but could not be reloaded.');
    return PropertyBillRecord(saved.id, saved.data()!);
  }

  Future<PropertyBillRecord?> getBill(String workspaceId, String billId) async {
    _signedIn();
    final saved = await _firestore.collection('propertyBills').doc(billId).get(const GetOptions(source: Source.server));
    return saved.exists && saved.data()?['workspaceId'] == workspaceId ? PropertyBillRecord(saved.id, saved.data()!) : null;
  }

  Stream<PropertyBillRecord?> watchBill(String workspaceId, String billId) =>
    _firestore.collection('propertyBills').doc(billId).snapshots().map((saved) =>
      saved.exists && saved.data()?['workspaceId'] == workspaceId ? PropertyBillRecord(saved.id, saved.data()!) : null);

  Future<List<PropertyBillRecord>> listBills(String workspaceId, {String? propertyId, String? unitId,
    PropertyBillType? billType, String? status, String? periodKey}) async {
    _signedIn();
    final result = await _firestore.collection('propertyBills').where('workspaceId', isEqualTo: workspaceId).orderBy('dueDate').get();
    return result.docs.where((item) =>
      (propertyId == null || item.data()['propertyId'] == propertyId) &&
      (unitId == null || item.data()['unitId'] == unitId) &&
      (billType == null || item.data()['billType'] == billType.firestoreValue) &&
      (status == null || item.data()['status'] == status) &&
      (periodKey == null || item.data()['periodKey'] == periodKey))
      .map((item) => PropertyBillRecord(item.id, item.data())).toList();
  }

  Stream<List<PropertyBillRecord>> watchBills(String workspaceId) => _firestore.collection('propertyBills')
    .where('workspaceId', isEqualTo: workspaceId).orderBy('dueDate').snapshots()
    .map((result) => result.docs.map((item) => PropertyBillRecord(item.id, item.data())).toList());

  Future<PropertyBillPaymentRecord> recordBillPayment(PropertyBillPaymentSubmission input) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Sign in before recording a bill payment.');
    if (input.workspaceId.isEmpty || input.billId.isEmpty || !_uuid.hasMatch(input.submissionId) || !_validMoney(input.amountPaise)) {
      throw ArgumentError('Invalid bill payment submission.');
    }
    final referenceNumber = _text(input.referenceNumber, 200);
    final notes = _text(input.notes, 2000);
    final paymentDate = Timestamp.fromDate(DateTime.fromMillisecondsSinceEpoch(input.paymentDate.millisecondsSinceEpoch, isUtc: true));
    final billRef = _firestore.collection('propertyBills').doc(input.billId);
    final paymentRef = _firestore.collection('propertyBillPayments').doc(input.submissionId);
    await _firestore.runTransaction((tx) async {
      final bill = await tx.get(billRef);
      final previous = await tx.get(paymentRef);
      if (previous.exists) {
        final saved = previous.data()!;
        if (saved['workspaceId'] != input.workspaceId || saved['billId'] != input.billId || saved['submissionId'] != input.submissionId ||
            saved['amountPaise'] != input.amountPaise || saved['paymentDate'] is! Timestamp ||
            (saved['paymentDate'] as Timestamp).millisecondsSinceEpoch != paymentDate.millisecondsSinceEpoch ||
            saved['paymentMode'] != input.paymentMode.firestoreValue || saved['referenceNumber'] != referenceNumber ||
            saved['notes'] != notes || saved['createdBy'] != user.uid) throw StateError('Submission ID already belongs to another payment.');
        return;
      }
      if (!bill.exists || bill.data()?['workspaceId'] != input.workspaceId) throw StateError('Bill not found in workspace.');
      final current = bill.data()!; _assertTotals(current);
      final balance = current['balancePaise'] as int;
      if (input.amountPaise > balance) throw StateError('Payment exceeds the outstanding balance.');
      final remaining = balance - input.amountPaise;
      tx.set(paymentRef, {
        'workspaceId': input.workspaceId, 'submissionId': input.submissionId, 'billId': input.billId,
        'propertyId': current['propertyId'], 'unitId': current['unitId'], 'billType': current['billType'],
        'amountPaise': input.amountPaise, 'paymentDate': paymentDate,
        'paymentMode': input.paymentMode.firestoreValue, 'referenceNumber': referenceNumber, 'notes': notes,
        'createdBy': user.uid, 'createdAt': FieldValue.serverTimestamp(),
      });
      tx.update(billRef, {
        'totalPaidPaise': (current['totalPaidPaise'] as int) + input.amountPaise,
        'balancePaise': remaining, 'status': remaining == 0 ? 'paid' : 'partial',
        'lastPaymentId': input.submissionId, 'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    final saved = await paymentRef.get();
    if (!saved.exists) throw StateError('Payment committed but could not be reloaded. Retry with the same submission ID.');
    return PropertyBillPaymentRecord(saved.id, saved.data()!);
  }

  Future<List<PropertyBillPaymentRecord>> listBillPayments(String workspaceId, String billId) async {
    _signedIn();
    final result = await _firestore.collection('propertyBillPayments').where('workspaceId', isEqualTo: workspaceId)
      .where('billId', isEqualTo: billId).orderBy('paymentDate').get();
    return result.docs.map((item) => PropertyBillPaymentRecord(item.id, item.data())).toList();
  }

  Stream<List<PropertyBillPaymentRecord>> watchBillPayments(String workspaceId, String billId) =>
    _firestore.collection('propertyBillPayments').where('workspaceId', isEqualTo: workspaceId)
      .where('billId', isEqualTo: billId).orderBy('paymentDate').snapshots()
      .map((result) => result.docs.map((item) => PropertyBillPaymentRecord(item.id, item.data())).toList());

  /// Read the stable UUID before retrying an uncertain network submission.
  Future<PropertyBillPaymentRecord?> getBillPayment(String workspaceId, String submissionId) async {
    _signedIn();
    final saved = await _firestore.collection('propertyBillPayments').doc(submissionId).get(const GetOptions(source: Source.server));
    return saved.exists && saved.data()?['workspaceId'] == workspaceId ? PropertyBillPaymentRecord(saved.id, saved.data()!) : null;
  }

  Future<PropertyBillRecord?> refreshOverdueState(String workspaceId, String billId) async {
    _signedIn();
    final reference = _firestore.collection('propertyBills').doc(billId);
    await _firestore.runTransaction((tx) async {
      final snapshot = await tx.get(reference);
      if (!snapshot.exists || snapshot.data()?['workspaceId'] != workspaceId) return;
      final current = snapshot.data()!; _assertTotals(current);
      if (current['status'] == 'pending' && current['totalPaidPaise'] == 0 && current['balancePaise'] > 0 &&
          _overdue(current['dueDate'] as Timestamp)) {
        tx.update(reference, {'status': 'overdue', 'updatedAt': FieldValue.serverTimestamp()});
      }
    });
    return getBill(workspaceId, billId);
  }
}
