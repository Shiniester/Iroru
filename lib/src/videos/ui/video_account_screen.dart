import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_providers.dart';
import 'video_source_account_page.dart';

class VideoAccountScreen extends ConsumerStatefulWidget {
  const VideoAccountScreen({super.key, this.restoreError});

  final Object? restoreError;

  @override
  ConsumerState<VideoAccountScreen> createState() => _VideoAccountScreenState();
}

class _VideoAccountScreenState extends ConsumerState<VideoAccountScreen> {
  late final MissavClient _client;
  bool _loading = false;
  bool _ready = false;
  bool _restoringAccount = false;
  bool _restoreFailed = false;
  late bool _wasLoggedIn;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  bool _showOpenSource = false;
  CancelToken? _accessCheckToken;
  int _restoreGeneration = 0;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider)..addListener(_accountChanged);
    _wasLoggedIn = _client.isLoggedIn;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _client.initialize();
    } catch (error) {
      if (mounted) {
        setState(() {
          _ready = true;
          _restoreFailed = _client.hasRestorableSession;
          _setAccountError(error, S.of(context).videoSourceUnavailable);
        });
      }
      return;
    }
    if (!mounted) return;
    final restoreError = widget.restoreError;
    setState(() {
      _ready = true;
      if (restoreError != null) {
        _restoreFailed = true;
        _setAccountError(restoreError, S.of(context).videoAccountRestoreFailed);
      }
    });
    if (restoreError == null) await _restoreAccount();
  }

  Future<void> _restoreAccount() async {
    if (!_client.hasRestorableSession && !_client.isLoggedIn) return;
    final generation = ++_restoreGeneration;
    setState(() {
      _restoringAccount = true;
      _restoreFailed = false;
      _error = null;
      _verificationError = null;
      _showOpenSource = false;
    });
    try {
      final restored = await _client.restoreAccount(recheck: true);
      if (!mounted || generation != _restoreGeneration) return;
      if (restored || _client.isLoggedIn) return;
      setState(() {
        _restoreFailed = true;
        _error = S.of(context).videoAccountRestoreFailed;
      });
    } catch (error) {
      if (!mounted || generation != _restoreGeneration) return;
      setState(() {
        _setAccountError(error, S.of(context).videoAccountRestoreFailed);
        _restoreFailed = true;
      });
    } finally {
      if (mounted && generation == _restoreGeneration) {
        setState(() => _restoringAccount = false);
      }
    }
  }

  Future<void> _refreshAccount() async {
    if (!_client.hasRestorableSession) return;
    final token = _accessCheckToken = CancelToken();
    try {
      await _client.checkBrowserAccess(cancelToken: token);
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() {
          _setAccountError(error, S.of(context).videoSourceUnavailable);
          _restoreFailed = _client.hasRestorableSession;
        });
      }
    } finally {
      if (mounted && identical(_accessCheckToken, token)) {
        _accessCheckToken = null;
      }
    }
  }

  void _cancelAccessCheck() {
    _restoreGeneration++;
    _restoringAccount = false;
    final token = _accessCheckToken;
    _accessCheckToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('Account action started.');
    }
  }

  void _accountChanged() {
    if (!mounted) return;
    final justSignedIn = _client.isLoggedIn && !_wasLoggedIn;
    _wasLoggedIn = _client.isLoggedIn;
    if (justSignedIn) {
      _restoreGeneration++;
      setState(() {
        _restoringAccount = false;
        _restoreFailed = false;
        _error = null;
        _verificationError = null;
        _showOpenSource = false;
      });
      return;
    }
    setState(() {});
  }

  Future<void> _verifyAccess() async {
    if (_loading) return;
    _cancelAccessCheck();
    setState(() => _loading = true);
    try {
      final result = await ref.read(missavAccountVerifierProvider)(
        context,
        _client,
        sourceUrl: _verificationError?.sourceUrl ?? _client.homeUrl,
      );
      if (!mounted) return;
      if (result.verified) {
        setState(() {
          _error = null;
          _verificationError = null;
          _showOpenSource = false;
        });
        if (!_client.isLoggedIn) await _refreshAccount();
        if (!mounted) return;
        if (_client.isLoggedIn) {
          setState(() => _restoreFailed = false);
        }
      } else {
        setState(() => _showOpenSource = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = S.of(context).videoVerificationFailed;
          _showOpenSource = true;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSource() async {
    try {
      final opened = await launchUrl(
        Uri.parse(_client.originHomeUrl),
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;
    } catch (_) {}
    if (mounted) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
  }

  Future<void> _logout() async {
    final clearBrowserSession = ref.read(videoBrowserSessionCleanupProvider);
    _cancelAccessCheck();
    setState(() => _loading = true);
    Object? logoutError;
    var loggedOut = false;
    try {
      await _client.logout();
      loggedOut = !_client.isLoggedIn;
    } catch (error) {
      logoutError = error;
    }
    try {
      await clearBrowserSession();
    } catch (error) {
      logoutError ??= error;
    }
    if (logoutError != null && mounted) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
    if (mounted) {
      setState(() {
        _loading = false;
        if (loggedOut) {
          _restoreFailed = false;
          _error = null;
          _verificationError = null;
          _showOpenSource = false;
        }
      });
    }
  }

  Future<void> _login() async {
    if (_loading) return;
    _cancelAccessCheck();
    setState(() => _loading = true);
    try {
      final signedIn = await ref.read(missavAccountLoginProvider)(
        context,
        _client,
      );
      if (mounted && signedIn) {
        setState(() {
          _restoreFailed = false;
          _error = null;
          _verificationError = null;
          _showOpenSource = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _setAccountError(error, S.of(context).loginFailed);
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setAccountError(Object error, String fallback) {
    final l10n = S.of(context);
    _verificationError = error is MissavVerificationRequiredException
        ? error
        : null;
    _showOpenSource = error is MissavAccessDeniedException;
    _error = switch (error) {
      MissavVerificationRequiredException() => l10n.videoVerificationRequired,
      MissavAccessDeniedException() => l10n.videoAccessDenied,
      MissavRateLimitException(:final retryAt) =>
        retryAt != null && retryAt.isAfter(DateTime.now())
            ? l10n.videoRateLimitedUntil(
                DateFormat.yMMMd(
                  l10n.localeName,
                ).add_jm().format(retryAt.toLocal()),
              )
            : l10n.videoRateLimited,
      _ => fallback,
    };
  }

  @override
  void dispose() {
    final token = _accessCheckToken;
    _accessCheckToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('Account page closed.');
    }
    _client.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final restoring = !_ready || _restoringAccount;
    final signedIn = _client.isLoggedIn;
    final hasSession = _client.hasRestorableSession;
    return VideoSourceAccountPage(
      title: s.videoSourceAccount,
      status: restoring
          ? s.videoAccountRestoring
          : signedIn
          ? _client.accountName ?? s.videoAccountSignedIn
          : hasSession
          ? null
          : s.videoLoginRequired,
      signedIn: signedIn,
      busy: restoring || _loading,
      onAccountAction: restoring
          ? null
          : signedIn
          ? _logout
          : !hasSession
          ? _login
          : null,
      error: restoring
          ? null
          : _error ?? (_restoreFailed ? s.videoAccountRestoreFailed : null),
      recoveryActions: restoring
          ? const []
          : [
              if (_restoreFailed && hasSession)
                TextButton(
                  onPressed: _loading ? null : _restoreAccount,
                  child: Text(s.retry),
                ),
              if (_verificationError != null)
                OutlinedButton(
                  onPressed: _loading ? null : _verifyAccess,
                  child: Text(s.videoVerifyAccess),
                ),
              if (_showOpenSource)
                OutlinedButton(
                  onPressed: _loading ? null : _openSource,
                  child: Text(s.videoOpenSource),
                ),
            ],
    );
  }
}
