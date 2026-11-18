import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/transfer_state_machine.dart';

void main() {
  group('TransferStateMachine', () {
    test('allows a successful receiver-approved transfer', () {
      final machine = TransferStateMachine();

      machine.transitionTo(TransferPhase.listening);
      machine.transitionTo(TransferPhase.awaitingSender);
      machine.transitionTo(TransferPhase.awaitingApproval);
      machine.transitionTo(TransferPhase.transferring);
      machine.transitionTo(TransferPhase.completed);

      expect(machine.phase, TransferPhase.completed);
      expect(machine.isTerminal, isTrue);
    });

    test('allows receiver rejection before file bytes are transferred', () {
      final machine = TransferStateMachine();

      machine.transitionTo(TransferPhase.listening);
      machine.transitionTo(TransferPhase.awaitingSender);
      machine.transitionTo(TransferPhase.awaitingApproval);
      machine.transitionTo(TransferPhase.rejected);

      expect(machine.phase, TransferPhase.rejected);
      expect(machine.isTerminal, isTrue);
    });

    test('rejects transfer before receiver approval', () {
      final machine = TransferStateMachine();

      machine.transitionTo(TransferPhase.listening);
      machine.transitionTo(TransferPhase.awaitingSender);
      machine.transitionTo(TransferPhase.awaitingApproval);

      expect(
        () => machine.transitionTo(TransferPhase.completed),
        throwsStateError,
      );
      expect(machine.phase, TransferPhase.awaitingApproval);
    });

    test('terminal state can be reset for a new session', () {
      final machine = TransferStateMachine();

      machine.transitionTo(TransferPhase.listening);
      machine.transitionTo(TransferPhase.cancelled);
      machine.transitionTo(TransferPhase.idle);

      expect(machine.phase, TransferPhase.idle);
      expect(machine.isTerminal, isFalse);
    });

    test('cancels during transfer and only resets after terminal cleanup', () {
      final machine = TransferStateMachine();

      machine.transitionTo(TransferPhase.listening);
      machine.transitionTo(TransferPhase.awaitingSender);
      machine.transitionTo(TransferPhase.awaitingApproval);
      machine.transitionTo(TransferPhase.transferring);
      machine.transitionTo(TransferPhase.cancelled);

      expect(machine.isTerminal, isTrue);
      expect(
        () => machine.transitionTo(TransferPhase.transferring),
        throwsStateError,
      );

      machine.transitionTo(TransferPhase.idle);
      expect(machine.phase, TransferPhase.idle);
    });

    test('does not allow skipping session setup', () {
      final machine = TransferStateMachine();

      expect(
        () => machine.transitionTo(TransferPhase.transferring),
        throwsStateError,
      );
    });
  });
}
