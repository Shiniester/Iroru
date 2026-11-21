class VideoSourceLoading {
  Future<bool>? _accountCheck;
  bool _restoreOnBrowse = false;

  Future<bool>? get pendingAccountCheck => _accountCheck;

  void reset({bool restoreOnBrowse = false}) {
    _accountCheck = null;
    _restoreOnBrowse = restoreOnBrowse;
  }

  Future<void> prepareContent(
    Future<void> Function() initialize,
    Future<bool> Function() restoreAccount,
  ) async {
    await initialize();
    if (_restoreOnBrowse) checkAccount(restoreAccount).ignore();
  }

  Future<bool> checkAccount(Future<bool> Function() check) {
    if (_accountCheck case final pending?) return pending;
    final retryOnBrowse = _restoreOnBrowse;
    _restoreOnBrowse = false;
    late final Future<bool> pending;
    pending = Future<bool>.microtask(check).then(
      (confirmed) {
        if (identical(_accountCheck, pending)) _accountCheck = null;
        return confirmed;
      },
      onError: (Object error, StackTrace trace) {
        if (identical(_accountCheck, pending)) {
          _accountCheck = null;
          _restoreOnBrowse = retryOnBrowse;
        }
        Error.throwWithStackTrace(error, trace);
      },
    );
    return _accountCheck = pending;
  }
}
