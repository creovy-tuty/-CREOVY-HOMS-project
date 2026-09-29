import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum PropertyExpenseCategory { maintenance, repair, plumbing, electrical, cleaning, painting, security, labour, commonArea, other }
extension PropertyExpenseCategoryValue on PropertyExpenseCategory {
  String get firestoreValue => this == PropertyExpenseCategory.commonArea ? 'common_area' : name;
}
enum PropertyExpensePaymentMode { cash, upi, bankTransfer, cheque, other }
extension PropertyExpensePaymentModeValue on PropertyExpensePaymentMode {
  String get firestoreValue => this == PropertyExpensePaymentMode.bankTransfer ? 'bank_transfer' : name;
}

class PropertyExpenseRecord {
  const PropertyExpenseRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
}
class PropertyExpenseSubmission {
  const PropertyExpenseSubmission({required this.workspaceId, required this.submissionId, required this.propertyId,
    required this.category, required this.title, required this.amountPaise, required this.expenseDate,
    required this.paymentMode, this.unitId, this.vendorName = '', this.referenceNumber = '', this.notes = ''});
  final String workspaceId, submissionId, propertyId, title, vendorName, referenceNumber, notes;
  final String? unitId;
  final PropertyExpenseCategory category;
  final int amountPaise;
  final DateTime expenseDate;
  final PropertyExpensePaymentMode paymentMode;
}
class SafePropertyExpenseMetadata {
  const SafePropertyExpenseMetadata({this.title, this.vendorName, this.notes});
  final String? title, vendorName, notes;
}
class PropertyExpenseFilters {
  const PropertyExpenseFilters({this.from, this.through, this.propertyId, this.unitId, this.category, this.paymentMode});
  final DateTime? from, through;
  final String? propertyId, unitId;
  final PropertyExpenseCategory? category;
  final PropertyExpensePaymentMode? paymentMode;
}

class PropertyExpenseRepository {
  PropertyExpenseRepository(this._firestore, this._auth);
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  static const _maxPaise = 9007199254740991;
  static const _indiaOffset = Duration(hours: 5, minutes: 30);
  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');

  /// Generate once per real expense and retain this UUID and financial payload across retries.
  static String newExpenseSubmissionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  String _userId() => _auth.currentUser?.uid ?? (throw StateError('Sign in to manage expenses.'));
  String _text(String value, int limit) {
    final clean = value.trim();
    if (clean.length > limit) throw ArgumentError('Text exceeds $limit characters.');
    return clean;
  }
  Timestamp _indiaMidnight(DateTime value) {
    final india = value.toUtc().add(_indiaOffset);
    return Timestamp.fromDate(DateTime.utc(india.year, india.month, india.day).subtract(_indiaOffset));
  }
  PropertyExpenseRecord _record(DocumentSnapshot<Map<String, dynamic>> saved) => PropertyExpenseRecord(saved.id, saved.data()!);

  Future<PropertyExpenseRecord> createExpense(PropertyExpenseSubmission input) async {
    final userId = _userId();
    if (input.workspaceId.isEmpty || input.propertyId.isEmpty || !_uuid.hasMatch(input.submissionId) ||
        input.amountPaise <= 0 || input.amountPaise > _maxPaise) throw ArgumentError('Invalid expense submission.');
    final title = _text(input.title, 200);
    if (title.isEmpty) throw ArgumentError('Expense title is required.');
    final vendorName = _text(input.vendorName, 200);
    final referenceNumber = _text(input.referenceNumber, 200);
    final notes = _text(input.notes, 2000);
    final unitId = input.unitId == null || input.unitId!.isEmpty ? null : input.unitId;
    final expenseDate = _indiaMidnight(input.expenseDate);
    final ref = _firestore.collection('propertyExpenses').doc(input.submissionId);
    await _firestore.runTransaction((tx) async {
      final workspace = await tx.get(_firestore.collection('workspaces').doc(input.workspaceId));
      final membership = await tx.get(_firestore.collection('workspaceMembers').doc('${input.workspaceId}_$userId'));
      final prior = await tx.get(ref);
      final member = membership.data();
      if (!workspace.exists || workspace.data()?['status'] != 'active' || !membership.exists ||
          member?['workspaceId'] != input.workspaceId || member?['userId'] != userId ||
          member?['status'] != 'active' || !['owner', 'manager', 'accountant'].contains(member?['role'])) {
        throw StateError('Active financial access to this workspace is required.');
      }
      if (prior.exists) {
        final saved = prior.data()!;
        if (saved['workspaceId'] != input.workspaceId || saved['submissionId'] != input.submissionId ||
            saved['propertyId'] != input.propertyId || saved['unitId'] != unitId ||
            saved['category'] != input.category.firestoreValue || saved['amountPaise'] != input.amountPaise ||
            saved['expenseDate'] is! Timestamp || (saved['expenseDate'] as Timestamp).millisecondsSinceEpoch != expenseDate.millisecondsSinceEpoch ||
            saved['paymentMode'] != input.paymentMode.firestoreValue || saved['referenceNumber'] != referenceNumber ||
            saved['createdBy'] != userId) throw StateError('Submission ID already belongs to a different expense.');
        return;
      }
      final property = await tx.get(_firestore.collection('properties').doc(input.propertyId));
      final unit = unitId == null ? null : await tx.get(_firestore.collection('units').doc(unitId));
      if (!property.exists || property.data()?['workspaceId'] != input.workspaceId ||
          unit != null && (!unit.exists || unit.data()?['workspaceId'] != input.workspaceId || unit.data()?['propertyId'] != input.propertyId)) {
        throw StateError('Property or unit does not belong to this workspace.');
      }
      tx.set(ref, {'workspaceId': input.workspaceId, 'submissionId': input.submissionId,
        'propertyId': input.propertyId, 'unitId': unitId, 'category': input.category.firestoreValue,
        'title': title, 'vendorName': vendorName, 'amountPaise': input.amountPaise, 'expenseDate': expenseDate,
        'paymentMode': input.paymentMode.firestoreValue, 'referenceNumber': referenceNumber, 'notes': notes,
        'createdBy': userId, 'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()});
    });
    final saved = await ref.get(const GetOptions(source: Source.server));
    if (!saved.exists) throw StateError('Expense could not be reloaded.');
    return _record(saved);
  }

  Future<PropertyExpenseRecord?> getExpense(String workspaceId, String expenseId) async {
    _userId();
    final saved = await _firestore.collection('propertyExpenses').doc(expenseId).get(const GetOptions(source: Source.server));
    return saved.exists && saved.data()?['workspaceId'] == workspaceId ? _record(saved) : null;
  }

  /// Date bounds and one indexed dimension execute on Firestore; other filters remain workspace-scoped.
  Future<List<PropertyExpenseRecord>> listExpenses(String workspaceId, {PropertyExpenseFilters filters = const PropertyExpenseFilters()}) async {
    _userId();
    if (workspaceId.isEmpty) throw ArgumentError('Workspace is required.');
    Query<Map<String, dynamic>> query = _firestore.collection('propertyExpenses').where('workspaceId', isEqualTo: workspaceId);
    if (filters.unitId != null) {
      query = query.where('unitId', isEqualTo: filters.unitId);
    } else if (filters.propertyId != null) {
      query = query.where('propertyId', isEqualTo: filters.propertyId);
    } else if (filters.category != null) {
      query = query.where('category', isEqualTo: filters.category!.firestoreValue);
    } else if (filters.paymentMode != null) {
      query = query.where('paymentMode', isEqualTo: filters.paymentMode!.firestoreValue);
    }
    if (filters.from != null) query = query.where('expenseDate', isGreaterThanOrEqualTo: _indiaMidnight(filters.from!));
    if (filters.through != null) query = query.where('expenseDate', isLessThanOrEqualTo: _indiaMidnight(filters.through!));
    final result = await query.orderBy('expenseDate', descending: true).get(const GetOptions(source: Source.server));
    return result.docs.where((saved) {
      final data = saved.data();
      return (filters.propertyId == null || data['propertyId'] == filters.propertyId) &&
        (filters.unitId == null || data['unitId'] == filters.unitId) &&
        (filters.category == null || data['category'] == filters.category!.firestoreValue) &&
        (filters.paymentMode == null || data['paymentMode'] == filters.paymentMode!.firestoreValue);
    }).map(_record).toList();
  }
  Future<List<PropertyExpenseRecord>> listExpensesForProperty(String workspaceId, String propertyId, {PropertyExpenseFilters filters = const PropertyExpenseFilters()}) =>
    listExpenses(workspaceId, filters: PropertyExpenseFilters(from: filters.from, through: filters.through, propertyId: propertyId,
      category: filters.category, paymentMode: filters.paymentMode));
  Future<List<PropertyExpenseRecord>> listExpensesForUnit(String workspaceId, String propertyId, String unitId, {PropertyExpenseFilters filters = const PropertyExpenseFilters()}) =>
    listExpenses(workspaceId, filters: PropertyExpenseFilters(from: filters.from, through: filters.through, propertyId: propertyId,
      unitId: unitId, category: filters.category, paymentMode: filters.paymentMode));

  Future<PropertyExpenseRecord> updateSafeExpenseMetadata(String workspaceId, String expenseId, SafePropertyExpenseMetadata changes) async {
    _userId();
    final ref = _firestore.collection('propertyExpenses').doc(expenseId);
    await _firestore.runTransaction((tx) async {
      final saved = await tx.get(ref);
      if (!saved.exists || saved.data()?['workspaceId'] != workspaceId) throw StateError('Expense not found in workspace.');
      final current = saved.data()!;
      final title = changes.title == null ? current['title'] as String : _text(changes.title!, 200);
      if (title.isEmpty) throw ArgumentError('Expense title is required.');
      tx.update(ref, {'title': title,
        'vendorName': changes.vendorName == null ? current['vendorName'] : _text(changes.vendorName!, 200),
        'notes': changes.notes == null ? current['notes'] : _text(changes.notes!, 2000),
        'updatedAt': FieldValue.serverTimestamp()});
    });
    final saved = await ref.get(const GetOptions(source: Source.server));
    if (!saved.exists) throw StateError('Expense could not be reloaded.');
    return _record(saved);
  }
}
