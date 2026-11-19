import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_providers.dart';

class VideoAccountScreen extends ConsumerStatefulWidget {
  const VideoAccountScreen({super.key, this.restoreError});

  final Object? restoreError;

  @override
  ConsumerState<VideoAccountScreen> createState() => _VideoAccountScreenState();
}

class _VideoAccountScreenState extends ConsumerState<VideoAccountScreen> {
  late final MissavClient _client;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _ready = false;
  bool _checkingAccount = false;
  bool _restoringAccount = false;
  bool _restoreFailed = false;
  late bool _wasLoggedIn;
  bool _obscurePassword = true;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  String? _pendingLoginHost;
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
      _pendingLoginHost = null;
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

  Future<Object?> _refreshAccount() async {
    if (!_client.hasRestorableSession) return null;
    final token = _accessCheckToken = CancelToken();
    setState(() => _checkingAccount = true);
    try {
      await _client.checkBrowserAccess(cancelToken: token);
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() {
          _setAccountError(error, S.of(context).videoSourceUnavailable);
        });
      }
      return error;
    } finally {
      if (mounted && identical(_accessCheckToken, token)) {
        _accessCheckToken = null;
        setState(() => _checkingAccount = false);
      }
    }
    return null;
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
        _pendingLoginHost = null;
        _showOpenSource = false;
      });
      return;
    }
    setState(() {});
  }

  Future<void> _verifyAccess() async {
    if (_loading) return;
    _cancelAccessCheck();
    setState(() {
      _loading = true;
      _checkingAccount = false;
    });
    var resumeLogin = false;
    try {
      final result = await ref.read(missavAccountVerifierProvider)(
        context,
        _client,
        sourceUrl: _verificationError?.sourceUrl ?? _client.homeUrl,
      );
      if (!mounted) return;
      if (result.verified) {
        final pendingLoginHost = _pendingLoginHost;
        setState(() {
          _error = null;
          _verificationError = null;
          _pendingLoginHost = null;
          _showOpenSource = false;
        });
        final refreshError = _client.isLoggedIn
            ? null
            : await _refreshAccount();
        if (!mounted) return;
        if (_client.isLoggedIn) {
          setState(() => _restoreFailed = false);
          _client.resumeContentBrowsing();
          _passwordController.clear();
        } else {
          resumeLogin =
              refreshError is! MissavRateLimitException &&
              !result.signedIn &&
              pendingLoginHost == _client.accountHostUrl;
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
    if (mounted && resumeLogin) await _nativeLogin(resuming: true);
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
    setState(() {
      _loading = true;
      _checkingAccount = false;
    });
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
          _pendingLoginHost = null;
          _showOpenSource = false;
        }
      });
    }
  }

  Future<void> _nativeLogin({bool resuming = false}) async {
    if (_loading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = S.of(context).loginFailed);
      return;
    }
    _cancelAccessCheck();
    setState(() {
      _loading = true;
      _checkingAccount = false;
      _error = null;
      _verificationError = null;
      _pendingLoginHost = null;
      _showOpenSource = false;
    });
    try {
      await _client.login(email: email, password: password);
      if (mounted && _client.isLoggedIn) {
        setState(() => _restoreFailed = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _setAccountError(error, S.of(context).loginFailed);
          if (_verificationError != null) {
            if (resuming) {
              _showOpenSource = true;
            } else if (email == _emailController.text.trim() &&
                password == _passwordController.text) {
              _pendingLoginHost = _client.accountHostUrl;
            }
          }
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
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final loggedIn = _client.isLoggedIn;
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(s.videoSourceAccount)),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    shrinkWrap: true,
                    children: [
                      Icon(
                        Icons.account_circle_outlined,
                        size: 56,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      if (_checkingAccount) ...[
                        const LinearProgressIndicator(
                          key: ValueKey('video-account-checking'),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_restoringAccount) ...[
                        Text(
                          s.videoAccountRestoring,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(
                          key: ValueKey('video-account-restoring'),
                        ),
                      ],
                      if (loggedIn &&
                          !_restoreFailed &&
                          !_restoringAccount) ...[
                        Text(
                          _client.accountName ?? s.videoAccountSignedIn,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _loading ? null : _logout,
                          icon: const Icon(Icons.logout),
                          label: Text(s.logout),
                        ),
                      ] else if (!_restoringAccount) ...[
                        Text(s.videoLoginRequired, textAlign: TextAlign.center),
                        if (_error != null || _restoreFailed) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error ?? s.videoAccountRestoreFailed,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: ValueKey(_client.accountHostUrl),
                          initialValue: _client.accountHostUrl,
                          decoration: InputDecoration(
                            labelText: s.videoAccountHost,
                          ),
                          items: [
                            for (final host in MissavClient.accountHosts)
                              DropdownMenuItem(
                                value: host,
                                child: Text(host.replaceFirst('https://', '')),
                              ),
                          ],
                          onChanged: _loading
                              ? null
                              : (host) {
                                  if (host != null &&
                                      host != _client.accountHostUrl) {
                                    setState(() {
                                      _error = null;
                                      _verificationError = null;
                                      _pendingLoginHost = null;
                                      _showOpenSource = false;
                                    });
                                    unawaited(_client.selectAccountHost(host));
                                  }
                                },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _emailController,
                          enabled: !_loading,
                          onChanged: (_) => _pendingLoginHost = null,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          decoration: InputDecoration(
                            labelText: s.videoAccountEmail,
                            prefixIcon: const Icon(Icons.email_outlined),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          enabled: !_loading,
                          onChanged: (_) => _pendingLoginHost = null,
                          obscureText: _obscurePassword,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) {
                            if (!_loading) unawaited(_nativeLogin());
                          },
                          decoration: InputDecoration(
                            labelText: s.password,
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: _loading
                                  ? null
                                  : () => setState(
                                      () =>
                                          _obscurePassword = !_obscurePassword,
                                    ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _loading ? null : _nativeLogin,
                          icon: _loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: Text(s.login),
                        ),
                        OutlinedButton.icon(
                          onPressed: _loading ? null : _verifyAccess,
                          icon: const Icon(Icons.verified_user_outlined),
                          label: Text(s.videoVerifyAccess),
                        ),
                        if (_showOpenSource)
                          OutlinedButton.icon(
                            onPressed: _loading ? null : _openSource,
                            icon: const Icon(Icons.open_in_new),
                            label: Text(s.videoOpenSource),
                          ),
                        if (_restoreFailed && _client.hasRestorableSession) ...[
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _loading ? null : _restoreAccount,
                            icon: const Icon(Icons.refresh),
                            label: Text(s.retry),
                          ),
                        ],
                        if (loggedIn) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _loading ? null : _logout,
                            icon: const Icon(Icons.logout),
                            label: Text(s.logout),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
