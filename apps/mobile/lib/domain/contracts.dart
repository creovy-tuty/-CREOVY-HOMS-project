/// Mirror the cross-client contract in packages/contracts without coupling the
/// Flutter client to JavaScript tooling. Firestore timestamps stay at adapters.
enum WorkspaceRole { owner, manager, accountant, viewer }

enum RentDueStatus { pending, partial, paid, overdue }

const businessCurrency = 'INR';
const businessTimezone = 'Asia/Kolkata';
const displayDateFormat = 'DD/MM/YYYY';

class RentPaymentDraft {
  const RentPaymentDraft({
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
  final String paymentMode;
  final String referenceNumber;
  final String notes;
}
