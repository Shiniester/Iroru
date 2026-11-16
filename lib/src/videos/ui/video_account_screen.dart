import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_providers.dart';

class VideoAccountScreen extends ConsumerStatefulWidget {
  const VideoAccountScreen({super.key});

  @override
  ConsumerState<VideoAccountScreen> createState() => _VideoAccountScreenState();
}

class _VideoAccountScreenState extends ConsumerState<VideoAccountScreen> {
  late final MissavClient _client;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _ready = false;
  bool _obscurePassword = true;
  String? _error;
  MissavVerificationRequiredException? _verificationError;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider)..addListener(_accountChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _client.initialize();
      await _client.checkBrowserAccess();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _ready = true;
          _verificationError = error is MissavVerificationRequiredException
              ? error
              : null;
          _error = _verificationError == null
              ? S.of(context).videoSourceUnavailable
              : S.of(context).videoVerificationRequired;
        });
      }
    }
  }

  void _accountChanged() {
    if (mounted) setState(() {});
  }

  Future<bool> _openBrowser() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final verified = await ref.read(missavAccessVerifierProvider)(
        context,
        _client,
        sourceUrl: _verificationError?.sourceUrl ?? _client.homeUrl,
      );
      if (mounted && verified) {
        setState(() {
          _error = null;
          _verificationError = null;
        });
      }
      return verified;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    final clearBrowserSession = ref.read(videoBrowserSessionCleanupProvider);
    setState(() => _loading = true);
    Object? logoutError;
    try {
      await _client.logout();
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
      setState(() => _loading = false);
    }
  }

  Future<void> _nativeLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = S.of(context).loginFailed);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      try {
        await _client.login(email: email, password: password);
      } on MissavException catch (error) {
        final needsVerification = error is! MissavAuthenticationException;
        if (!needsVerification) rethrow;
        if (!await _openBrowser()) rethrow;
        await _client.login(email: email, password: password);
      }
      if (mounted) {
        setState(() {
          _error = null;
          _verificationError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = S.of(context).loginFailed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyAccess() async {
    await _openBrowser();
  }

  @override
  void dispose() {
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
                      if (loggedIn) ...[
                        Text(
                          _client.accountName ?? s.videoSourceAccount,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _loading ? null : _logout,
                          icon: const Icon(Icons.logout),
                          label: Text(s.logout),
                        ),
                      ] else ...[
                        Text(s.videoLoginRequired, textAlign: TextAlign.center),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextField(
                          controller: _emailController,
                          enabled: !_loading,
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
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
