import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../jable_client.dart';
import '../jable_verification.dart';
import '../video_models.dart';
import '../video_providers.dart';
import 'video_source_account_page.dart';

class JableAccountScreen extends ConsumerStatefulWidget {
  const JableAccountScreen({super.key});

  @override
  ConsumerState<JableAccountScreen> createState() => _JableAccountScreenState();
}

class _JableAccountScreenState extends ConsumerState<JableAccountScreen> {
  late final JableClient _client;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _client = ref.read(jableVideoClientProvider);
    unawaited(_run(_check));
  }

  Future<void> _check() async {
    await _client.account.checkLogin();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBrowser({required bool login}) async {
    final checked = await verifyJableAccess(
      context,
      _client,
      sourceUrl: login ? '${JableClient.origin}/login/' : _client.homeUrl,
      requireLogin: login,
    );
    if (checked && !login) await _check();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final account = _client.account;
    final verificationRequired = _error is VideoVerificationRequired;
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => VideoSourceAccountPage(
        title: s.videoJableAccount,
        status: account.isLoggedIn
            ? s.videoJableSignedIn
            : s.videoJableLoginRequired,
        signedIn: account.isLoggedIn,
        busy: _busy,
        onAccountAction: () => _run(
          account.isLoggedIn ? account.logout : () => _openBrowser(login: true),
        ),
        error: _error == null
            ? null
            : verificationRequired
            ? s.videoVerificationRequired
            : s.videoSourceUnavailable,
        recoveryActions: [
          if (_error != null) ...[
            TextButton(
              onPressed: _busy ? null : () => _run(_check),
              child: Text(s.retry),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => _openBrowser(login: false)),
              child: Text(
                verificationRequired ? s.videoVerifyAccess : s.videoOpenSource,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
