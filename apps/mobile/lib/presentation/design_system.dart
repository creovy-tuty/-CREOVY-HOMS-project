import 'package:flutter/material.dart';

class CreovyColors {
  static const brand = Color(0xFF5635D9);
  static const accent = Color(0xFF008B8B);
  static const canvas = Color(0xFFF6F7FB);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF172033);
  static const secondary = Color(0xFF526174);
  static const muted = Color(0xFF8390A2);
  static const border = Color(0xFFE5E9F0);
  static const success = Color(0xFF16794A);
  static const warning = Color(0xFFA86600);
  static const danger = Color(0xFFC2352B);
  static const info = Color(0xFF2463B8);
}

String formatInr(int? paise) {
  if (paise == null) return '—';
  final absolute = paise.abs();
  final sign = paise < 0 ? '−' : '';
  final digits = (absolute ~/ 100).toString();
  final minor = absolute % 100;
  final fraction = minor == 0 ? '' : '.${minor.toString().padLeft(2, '0')}';
  if (digits.length <= 3) return '$sign₹$digits$fraction';
  final tail = digits.substring(digits.length - 3);
  var head = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (head.length > 2) { groups.insert(0, head.substring(head.length - 2)); head = head.substring(0, head.length - 2); }
  if (head.isNotEmpty) groups.insert(0, head);
  return '$sign₹${groups.join(',')},$tail$fraction';
}

class CreovyButton extends StatelessWidget {
  const CreovyButton({super.key, required this.label, this.icon, this.onPressed, this.loading = false, this.variant = CreovyButtonVariant.primary});
  final String label; final IconData? icon; final VoidCallback? onPressed; final bool loading; final CreovyButtonVariant variant;
  @override
  Widget build(BuildContext context) {
    final primary = variant == CreovyButtonVariant.primary;
    return SizedBox(height: 46, child: primary ? FilledButton.icon(onPressed: loading ? null : onPressed, icon: loading ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(icon), label: Text(label), style: FilledButton.styleFrom(backgroundColor: CreovyColors.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))) : OutlinedButton.icon(onPressed: loading ? null : onPressed, icon: Icon(icon), label: Text(label), style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
  }
}
enum CreovyButtonVariant { primary, outline }

class CreovyTextField extends StatelessWidget {
  const CreovyTextField({super.key, required this.label, this.controller, this.keyboardType, this.obscureText = false, this.errorText, this.enabled = true});
  final String label; final TextEditingController? controller; final TextInputType? keyboardType; final bool obscureText, enabled; final String? errorText;
  @override Widget build(BuildContext context) => TextField(controller: controller, keyboardType: keyboardType, obscureText: obscureText, enabled: enabled, decoration: InputDecoration(labelText: label, errorText: errorText));
}
class FeedbackAlert extends StatelessWidget { const FeedbackAlert({super.key, required this.message, this.tone = CreovyColors.info}); final String message; final Color tone; @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: tone.withValues(alpha: .09), borderRadius: BorderRadius.circular(12)), child: Text(message, style: TextStyle(color: tone, fontSize: 13))); }
Future<bool> showCreovyConfirmation(BuildContext context, {required String title, required String body, required String confirmLabel}) async => await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: Text(title), content: Text(body), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirmLabel))])) ?? false;

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label}); final String label;
  @override Widget build(BuildContext context) { final tone = switch (label) { 'Paid' || 'Active' || 'Received' => CreovyColors.success, 'Partial' || 'Refunded' => CreovyColors.info, 'Pending' => CreovyColors.warning, 'Overdue' => CreovyColors.danger, 'Occupied' => CreovyColors.brand, _ => CreovyColors.secondary }; return Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: tone.withValues(alpha: .10), borderRadius: BorderRadius.circular(20)), child: Text(label, style: TextStyle(color: tone, fontSize: 12, fontWeight: FontWeight.w700))); }
}

class SurfaceCard extends StatelessWidget { const SurfaceCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)}); final Widget child; final EdgeInsets padding; @override Widget build(BuildContext context) => Container(padding: padding, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: CreovyColors.border)), child: child); }
class Skeleton extends StatelessWidget { const Skeleton({super.key, this.width = double.infinity, this.height = 16}); final double width, height; @override Widget build(BuildContext context) => Container(width: width, height: height, decoration: BoxDecoration(color: const Color(0xFFEFF2F6), borderRadius: BorderRadius.circular(8))); }
class EmptyState extends StatelessWidget { const EmptyState({super.key, required this.title, required this.body}); final String title, body; @override Widget build(BuildContext context) => Container(width: double.infinity, padding: const EdgeInsets.all(24), decoration: BoxDecoration(border: Border.all(color: CreovyColors.border), borderRadius: BorderRadius.circular(16)), child: Column(children: [const Icon(Icons.inbox_outlined, color: CreovyColors.muted), const SizedBox(height: 10), Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: CreovyColors.ink)), const SizedBox(height: 5), Text(body, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: CreovyColors.secondary))])); }
