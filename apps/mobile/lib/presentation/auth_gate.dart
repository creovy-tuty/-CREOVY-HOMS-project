import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../data/account_resolver.dart';
import '../data/workspace_repository.dart';
import 'app_shell.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const _Loading('Restoring your secure session…');
          return snapshot.hasData ? _AccountResolution(user: snapshot.data!) : const AuthScreen();
        },
      );
}

class _AccountResolution extends StatefulWidget {
  const _AccountResolution({required this.user});
  final User user;
  @override
  State<_AccountResolution> createState() => _AccountResolutionState();
}

class _AccountResolutionState extends State<_AccountResolution> {
  late Future<AccountContext?> _account;
  @override void initState() { super.initState(); _account = AccountResolver(FirebaseFirestore.instance).resolve(widget.user.uid); }
  @override
  Widget build(BuildContext context) => FutureBuilder<AccountContext?>(future: _account, builder: (context, snapshot) {
    if (snapshot.connectionState != ConnectionState.done) return const _Loading('Opening your workspace…');
    if (snapshot.hasError && snapshot.error is InactiveAccountException) return const _InactiveAccount();
    if (snapshot.hasError) return _Problem(title: 'We couldn’t open your workspace', action: 'Try again', onPressed: () => setState(() => _account = AccountResolver(FirebaseFirestore.instance).resolve(widget.user.uid)));
    return snapshot.data == null ? WorkspaceSetupScreen(user: widget.user) : PremiumDashboardShell(account: snapshot.data!);
  });
}

class AuthScreen extends StatefulWidget { const AuthScreen({super.key}); @override State<AuthScreen> createState() => _AuthScreenState(); }
class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _mobile = TextEditingController(), _email = TextEditingController(), _password = TextEditingController(), _confirm = TextEditingController();
  bool _signup = false, _hidden = true, _busy = false; String? _error;
  @override void dispose() { _name.dispose(); _mobile.dispose(); _email.dispose(); _password.dispose(); _confirm.dispose(); super.dispose(); }
  String? _required(String? value, String label) => value == null || value.trim().isEmpty ? 'Enter $label' : null;
  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_signup && (!RegExp(r'^\+?[0-9\s-]{8,15}$').hasMatch(_mobile.text.trim()) || _password.text != _confirm.text)) { setState(() => _error = 'Use a valid mobile number and matching passwords.'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      if (_signup) { final result = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: _email.text.trim(), password: _password.text); await result.user?.updateDisplayName(_name.text.trim()); }
      else { await FirebaseAuth.instance.signInWithEmailAndPassword(email: _email.text.trim(), password: _password.text); }
    } on FirebaseAuthException catch (error) { setState(() => _error = _message(error.code)); } finally { if (mounted) setState(() => _busy = false); }
  }
  String _message(String code) { if (code == 'email-already-in-use') return 'An account already exists with this email. Sign in instead.'; if (code == 'invalid-credential' || code == 'wrong-password') return 'The email or password is incorrect.'; if (code == 'too-many-requests') return 'Too many attempts. Please wait a moment.'; return 'We could not complete that request. Please try again.'; }
  Future<void> _reset() async { final email = TextEditingController(text: _email.text); await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Reset password'), content: TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email address')), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')), FilledButton(onPressed: () async { try { await FirebaseAuth.instance.sendPasswordResetEmail(email: email.text.trim()); } catch (_) {} if (dialogContext.mounted) Navigator.pop(dialogContext); }, child: const Text('Send link'))])); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('If an account exists, reset instructions are on their way.'))); }
  @override
  Widget build(BuildContext context) => _AuthFrame(child: Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const _Brand(), const SizedBox(height: 20), Text(_signup ? 'Create your owner account' : 'Welcome back', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)), const SizedBox(height: 8), Text(_signup ? 'Set up your portfolio in a few thoughtful steps.' : 'Sign in to your property workspace.', style: const TextStyle(color: Color(0xFF64748B))), const SizedBox(height: 28), if (_signup) ...[_input(_name, 'Full name', TextInputType.name, (v) => _required(v, 'your full name')), const SizedBox(height: 14), _input(_mobile, 'Mobile number', TextInputType.phone, (v) => _required(v, 'your mobile number')), const SizedBox(height: 14)], _input(_email, 'Email address', TextInputType.emailAddress, (v) => v == null || !v.contains('@') ? 'Enter a valid email address' : null), const SizedBox(height: 14), TextFormField(controller: _password, obscureText: _hidden, validator: (v) => v == null || v.length < 8 ? 'Use at least 8 characters' : null, decoration: InputDecoration(labelText: 'Password', suffixIcon: IconButton(onPressed: () => setState(() => _hidden = !_hidden), icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined)))), if (_signup) ...[const SizedBox(height: 14), TextFormField(controller: _confirm, obscureText: _hidden, decoration: const InputDecoration(labelText: 'Confirm password'))], if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318)))), const SizedBox(height: 22), FilledButton(onPressed: _busy ? null : _submit, style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)), child: Text(_busy ? 'Please wait…' : _signup ? 'Create account' : 'Sign in')), Row(children: [if (!_signup) TextButton(onPressed: _reset, child: const Text('Forgot password?')), const Spacer(), TextButton(onPressed: _busy ? null : () => setState(() { _signup = !_signup; _error = null; }), child: Text(_signup ? 'Back to sign in' : 'Create account'))])])));
  Widget _input(TextEditingController controller, String label, TextInputType type, String? Function(String?) validator) => TextFormField(controller: controller, keyboardType: type, validator: validator, decoration: InputDecoration(labelText: label));
}

class WorkspaceSetupScreen extends StatefulWidget { const WorkspaceSetupScreen({super.key, required this.user}); final User user; @override State<WorkspaceSetupScreen> createState() => _WorkspaceSetupScreenState(); }
class _WorkspaceSetupScreenState extends State<WorkspaceSetupScreen> {
  final _form = GlobalKey<FormState>(); final _portfolio = TextEditingController(), _mobile = TextEditingController(); late final _name = TextEditingController(text: widget.user.displayName ?? ''); late final _email = TextEditingController(text: widget.user.email ?? ''); bool _busy = false; String? _error;
  @override void dispose() { _portfolio.dispose(); _mobile.dispose(); _name.dispose(); _email.dispose(); super.dispose(); }
  Future<void> _create() async { if (!(_form.currentState?.validate() ?? false)) return; setState(() { _busy = true; _error = null; }); try { await WorkspaceRepository(FirebaseFirestore.instance).bootstrapOwnerWorkspace(uid: widget.user.uid, name: _portfolio.text.trim(), fullName: _name.text.trim(), mobile: _mobile.text.trim(), email: _email.text.trim()); } catch (_) { if (mounted) setState(() => _error = 'We could not create your workspace. Please try again.'); } finally { if (mounted) setState(() => _busy = false); } }
  @override Widget build(BuildContext context) => _AuthFrame(child: Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const _Brand(label: 'ONE LAST STEP'), const SizedBox(height: 20), Text('Name your property portfolio.', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)), const SizedBox(height: 8), const Text('This creates your secure CREOVY workspace.', style: TextStyle(color: Color(0xFF64748B))), const SizedBox(height: 28), _field(_portfolio, 'Property portfolio name'), const SizedBox(height: 14), _field(_name, 'Owner full name'), const SizedBox(height: 14), _field(_mobile, 'Mobile number', type: TextInputType.phone), const SizedBox(height: 14), TextFormField(controller: _email, readOnly: true, decoration: const InputDecoration(labelText: 'Email address')), if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318)))), const SizedBox(height: 22), FilledButton(onPressed: _busy ? null : _create, style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)), child: Text(_busy ? 'Creating secure workspace…' : 'Create workspace'))])));
  Widget _field(TextEditingController c, String label, {TextInputType type = TextInputType.text}) => TextFormField(controller: c, keyboardType: type, validator: (v) => v == null || v.trim().length < 2 ? 'Enter $label' : null, decoration: InputDecoration(labelText: label));
}

class DashboardShell extends StatelessWidget { const DashboardShell({super.key, required this.account}); final AccountContext account; @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('CREOVY House Owner'), actions: [TextButton(onPressed: () => FirebaseAuth.instance.signOut(), child: const Text('Log out'))]), body: Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(account.workspaceName, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)), const SizedBox(height: 8), const Text('Your secure workspace is connected.'), const SizedBox(height: 28), Card(child: ListTile(title: Text(account.ownerName.isEmpty ? 'Owner' : account.ownerName), subtitle: Text('Role: ${account.role}')))])); }
class _AuthFrame extends StatelessWidget { const _AuthFrame({required this.child}); final Widget child; @override Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 430), child: Card(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: const BorderSide(color: Color(0xFFE2E8F0))), child: Padding(padding: const EdgeInsets.all(28), child: child)))))); }
class _Brand extends StatelessWidget { const _Brand({this.label = 'CREOVY HOUSE OWNER'}); final String label; @override Widget build(BuildContext context) => Text(label, style: const TextStyle(color: Color(0xFF5635D9), fontWeight: FontWeight.w700, letterSpacing: 1.6)); }
class _Loading extends StatelessWidget { const _Loading(this.label); final String label; @override Widget build(BuildContext context) => Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 18), Text(label)]))); }
class _Problem extends StatelessWidget { const _Problem({required this.title, required this.action, required this.onPressed}); final String title, action; final VoidCallback onPressed; @override Widget build(BuildContext context) => Scaffold(body: Center(child: FilledButton(onPressed: onPressed, child: Text('$title — $action')))); }
class _InactiveAccount extends StatelessWidget { const _InactiveAccount(); @override Widget build(BuildContext context) => Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('Account unavailable', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)), const SizedBox(height: 10), const Text('This CREOVY account is currently inactive. Please contact support.', textAlign: TextAlign.center), const SizedBox(height: 20), TextButton(onPressed: () => FirebaseAuth.instance.signOut(), child: const Text('Return to sign in'))]))); }
