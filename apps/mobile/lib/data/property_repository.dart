import 'package:cloud_firestore/cloud_firestore.dart';

enum PropertyType { independentHouse, apartmentBuilding, commercialBuilding, mixedUse, other }
enum UnitType { house, flat, portion, room, shop, office, other }
enum UnitStatus { vacant, occupied, maintenance, inactive }

class PropertyRecord { PropertyRecord(this.id, this.data); final String id; final Map<String, dynamic> data; }
class UnitRecord { UnitRecord(this.id, this.data); final String id; final Map<String, dynamic> data; }

class PropertyRepository {
  PropertyRepository(this._firestore); final FirebaseFirestore _firestore;
  Stream<List<PropertyRecord>> watchProperties(String workspaceId) => _firestore.collection('properties').where('workspaceId', isEqualTo: workspaceId).orderBy('name').snapshots().map((items) => items.docs.map((item) => PropertyRecord(item.id, item.data())).toList());
  Stream<List<UnitRecord>> watchUnits(String workspaceId, String propertyId) => _firestore.collection('units').where('workspaceId', isEqualTo: workspaceId).where('propertyId', isEqualTo: propertyId).orderBy('name').snapshots().map((items) => items.docs.map((item) => UnitRecord(item.id, item.data())).toList());
  Stream<List<UnitRecord>> watchAllUnits(String workspaceId) => _firestore.collection('units').where('workspaceId', isEqualTo: workspaceId).snapshots().map((items) => items.docs.map((item) => UnitRecord(item.id, item.data())).toList());
  Future<String> createProperty({required String workspaceId, required Map<String, dynamic> property, required List<Map<String, dynamic>> initialUnits}) async {
    final reference = _firestore.collection('properties').doc(); final code = (property['code'] as String? ?? '').trim().toUpperCase().isEmpty ? 'PROP-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}' : (property['code'] as String).trim().toUpperCase();
    await _firestore.runTransaction((transaction) async { final duplicate = await transaction.get(_firestore.collection('properties').where('workspaceId', isEqualTo: workspaceId).where('code', isEqualTo: code)); if (duplicate.docs.isNotEmpty) throw StateError('This property code is already in use.'); final audit = {'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()}; transaction.set(reference, {...property, 'workspaceId': workspaceId, 'code': code, 'status': 'active', ...audit}); for (final unit in initialUnits) { transaction.set(_firestore.collection('units').doc(), {...unit, 'workspaceId': workspaceId, 'propertyId': reference.id, 'status': 'vacant', ...audit}); } });
    return reference.id;
  }
  Future<void> updateProperty(String id, Map<String, dynamic> values) => _firestore.collection('properties').doc(id).update({...values, 'updatedAt': FieldValue.serverTimestamp()});
  Future<void> archiveProperty(String id) => updateProperty(id, {'status': 'inactive'});
  Future<void> createUnit(String workspaceId, String propertyId, Map<String, dynamic> unit) => _firestore.collection('units').add({...unit, 'workspaceId': workspaceId, 'propertyId': propertyId, 'status': 'vacant', 'createdAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()});
  Future<void> updateUnit(String id, Map<String, dynamic> values) => _firestore.collection('units').doc(id).update({...values, 'updatedAt': FieldValue.serverTimestamp()});
  Future<void> deactivateUnit(String id) => updateUnit(id, {'status': 'inactive'});
}
