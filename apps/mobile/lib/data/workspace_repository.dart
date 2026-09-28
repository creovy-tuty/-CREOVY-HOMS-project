import 'package:cloud_firestore/cloud_firestore.dart';

class WorkspaceRepository {
  WorkspaceRepository(this._firestore);
  final FirebaseFirestore _firestore;

  /// Stable ID + atomic batch makes owner-onboarding safe to retry.
  Future<String> bootstrapOwnerWorkspace({required String uid, required String name, required String fullName, required String mobile, required String email}) async {
    final workspace = _firestore.collection('workspaces').doc('owner_$uid');
    final membership = _firestore.collection('workspaceMembers').doc('${workspace.id}_$uid');
    final profile = _firestore.collection('users').doc(uid);
    final batch = _firestore.batch();
    final now = FieldValue.serverTimestamp();
    batch.set(profile, {'uid': uid, 'displayName': fullName, 'mobile': mobile, 'email': email, 'status': 'active', 'activeWorkspaceId': workspace.id, 'createdAt': now, 'updatedAt': now}, SetOptions(merge: true));
    batch.set(workspace, {'name': name, 'ownerId': uid, 'status': 'active', 'currency': 'INR', 'timezone': 'Asia/Kolkata', 'createdAt': now, 'updatedAt': now}, SetOptions(merge: true));
    batch.set(membership, {'workspaceId': workspace.id, 'userId': uid, 'role': 'owner', 'status': 'active', 'createdAt': now, 'updatedAt': now}, SetOptions(merge: true));
    await batch.commit();
    return workspace.id;
  }
}
