/// Synchronous cancellation signal for one transfer session.
///
/// Binding it to a TCP connection destroys that socket immediately. The
/// receiver then observes EOF and removes its active partial file.
class TransferCancellation {
  bool _isCancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _isCancelled;

  bool cancel() {
    if (_isCancelled) return false;
    _isCancelled = true;
    _onCancel?.call();
    return true;
  }

  void bind(void Function() onCancel) {
    _onCancel = onCancel;
    if (_isCancelled) onCancel();
  }

  void unbind() {
    _onCancel = null;
  }
}
