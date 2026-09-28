import 'package:cloud_firestore/cloud_firestore.dart';

class InactiveAccountException implements Exception {
  const InactiveAccountException();
}

class AccountContext {
  const AccountContext({required this.workspaceId, required this.workspaceName, required this.role, required this.ownerName});
  final String workspaceId;
  final String workspaceName;
  final String role;
  final String ownerName;
}

class AccountResolver {
  AccountResolver(this._firestore);
  final FirebaseFirestore _firestore;

  Future<AccountContext?> resolve(String uid) async {
    final profile = await _firestore.collection('users').doc(uid).get();
    if (!profile.exists) return null;
    if (profile.data()?['status'] != 'active') throw const InactiveAccountException();
    final memberships = await _firestore.collection('workspaceMembers').where('userId', isEqualTo: uid).where('status', isEqualTo: 'active').limit(20).get();
    if (memberships.docs.isEmpty) return null;
    final preferred = profile.data()?['activeWorkspaceId'];
    final membership = memberships.docs.firstWhere((entry) => entry.data()['workspaceId'] == preferred, orElse: () => memberships.docs.first);
    final workspace = await _firestore.collection('workspaces').doc(membership.data()['workspaceId'] as String).get();
    if (!workspace.exists || workspace.data()?['status'] != 'active') return null;
    return AccountContext(workspaceId: workspace.id, workspaceName: workspace.data()?['name'] as String? ?? 'CREOVY Workspace', role: membership.data()['role'] as String? ?? 'viewer', ownerName: profile.data()?['displayName'] as String? ?? '');
  }
}
