/// Platform-neutral state machine for one receive/send batch.
///
/// This class deliberately has no Flutter or dart:io dependency so the same
/// transition rules can be used by Android, Windows, and iOS clients.
enum TransferPhase {
  idle,
  listening,
  awaitingSender,
  awaitingApproval,
  transferring,
  completed,
  rejected,
  cancelled,
  failed,
}

class TransferStateMachine {
  TransferStateMachine() : _phase = TransferPhase.idle;

  TransferPhase _phase;

  TransferPhase get phase => _phase;

  bool get isTerminal => switch (_phase) {
        TransferPhase.completed ||
        TransferPhase.rejected ||
        TransferPhase.cancelled ||
        TransferPhase.failed =>
          true,
        _ => false,
      };

  void transitionTo(TransferPhase next) {
    if (!_allowedTransitions[_phase]!.contains(next)) {
      throw StateError('Invalid transfer transition: ${_phase.name} -> ${next.name}');
    }
    _phase = next;
  }

  static const Map<TransferPhase, Set<TransferPhase>> _allowedTransitions = {
    TransferPhase.idle: {TransferPhase.listening},
    TransferPhase.listening: {
      TransferPhase.awaitingSender,
      TransferPhase.cancelled,
      TransferPhase.failed,
    },
    TransferPhase.awaitingSender: {
      TransferPhase.awaitingApproval,
      TransferPhase.cancelled,
      TransferPhase.failed,
    },
    TransferPhase.awaitingApproval: {
      TransferPhase.transferring,
      TransferPhase.rejected,
      TransferPhase.cancelled,
      TransferPhase.failed,
    },
    TransferPhase.transferring: {
      TransferPhase.completed,
      TransferPhase.cancelled,
      TransferPhase.failed,
    },
    TransferPhase.completed: {TransferPhase.idle},
    TransferPhase.rejected: {TransferPhase.idle},
    TransferPhase.cancelled: {TransferPhase.idle},
    TransferPhase.failed: {TransferPhase.idle},
  };
}
