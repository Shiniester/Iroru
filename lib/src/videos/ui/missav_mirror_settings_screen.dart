import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/settings_section.dart';
import '../jable_mirrors.dart';
import '../missav_mirrors.dart';
import '../video_providers.dart';

enum _MirrorSource { missav, jable }

class MissavMirrorSettingsScreen extends ConsumerStatefulWidget {
  const MissavMirrorSettingsScreen({super.key, this.prober})
    : _source = _MirrorSource.missav;

  const MissavMirrorSettingsScreen.jable({super.key, this.prober})
    : _source = _MirrorSource.jable;

  final MissavMirrorProber? prober;
  final _MirrorSource _source;

  @override
  ConsumerState<MissavMirrorSettingsScreen> createState() =>
      _MissavMirrorSettingsScreenState();
}

class _MissavMirrorSettingsScreenState
    extends ConsumerState<MissavMirrorSettingsScreen> {
  bool get _isJable => widget._source == _MirrorSource.jable;
  late final List<MissavMirror> _mirrors = _isJable
      ? jableMirrors
      : missavMirrors;
  late final String _preferenceKey = _isJable
      ? jableMirrorBaseUrlKey
      : missavMirrorBaseUrlKey;
  late final MissavMirrorProber _prober =
      widget.prober ??
      (_isJable ? createJableMirrorProber() : MissavMirrorProber());
  final Map<String, MissavMirrorLatency> _results = {};
  CancelToken? _cancelToken;
  String? _preferredBaseUrl;
  bool _testing = false;
  int _probeRun = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = videoMirrorForBaseUrl(
      _mirrors,
      preferences.getString(_preferenceKey),
    );
    if (!mounted) return;
    setState(() => _preferredBaseUrl = saved?.baseUrl);
    await _startProbe();
  }

  Future<void> _startProbe() async {
    if (!mounted) return;
    final run = ++_probeRun;
    _cancelToken?.cancel();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    setState(() {
      _testing = true;
      _results
        ..clear()
        ..addEntries(
          _mirrors.map(
            (mirror) =>
                MapEntry(mirror.host, MissavMirrorLatency(mirror: mirror)),
          ),
        );
    });
    try {
      final results = await _prober.probeAll(
        _mirrors,
        cancelToken: cancelToken,
        onResult: (result) {
          if (!mounted || run != _probeRun) return;
          setState(() => _results[result.mirror.host] = result);
        },
      );
      if (!mounted || run != _probeRun) return;
      setState(() {
        _testing = false;
        _results.addEntries(
          results.map((result) => MapEntry(result.mirror.host, result)),
        );
      });
    } on DioException {
      // A replaced or closed screen cancels its pending probes.
    } finally {
      if (mounted && run == _probeRun) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _select(MissavMirror? mirror) async {
    final baseUrl = mirror?.baseUrl;
    if (_isJable) {
      await ref.read(jableVideoClientProvider).selectMirror(baseUrl);
    } else {
      ref.read(videoClientProvider).selectMirror(baseUrl);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_preferenceKey, baseUrl ?? '');
    }
    if (!mounted) return;
    setState(() => _preferredBaseUrl = baseUrl);
  }

  void _useFastest() {
    final available = _results.values
        .where((result) => result.isAvailable)
        .toList();
    if (available.isEmpty) return;
    available.sort((left, right) => left.millis!.compareTo(right.millis!));
    unawaited(_select(available.first.mirror));
  }

  String _latencyLabel(S s, MissavMirrorLatency? result) {
    if (result == null) return s.videoMirrorTesting;
    if (result.isAvailable) return '${result.millis} ms';
    if (result.error == null) return s.videoMirrorTesting;
    if (result.error == 'timeout') return s.videoMirrorTimeout;
    return '${s.videoMirrorUnavailable} (${result.error})';
  }

  Color? _latencyColor(BuildContext context, MissavMirrorLatency? result) {
    if (result == null || !result.isAvailable) {
      return result?.error == null
          ? Theme.of(context).colorScheme.onSurfaceVariant
          : Theme.of(context).colorScheme.error;
    }
    if (result.millis! < 100) return const Color(0xFF4CAF50);
    if (result.millis! <= 500) return const Color(0xFFFFC107);
    return Theme.of(context).colorScheme.error;
  }

  @override
  void dispose() {
    _probeRun++;
    _cancelToken?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isJable) {
      final client = ref.watch(jableVideoClientProvider);
      return ListenableBuilder(
        listenable: client.account,
        builder: (context, _) => _buildPage(
          context,
          usesAutomaticMirror: client.usesAutomaticMirror,
          activeMirrorHost: client.activeMirrorHost,
        ),
      );
    }
    final client = ref.watch(videoClientProvider);
    return _buildPage(
      context,
      usesAutomaticMirror: client.usesAutomaticMirror,
      activeMirrorHost: client.activeMirrorHost,
    );
  }

  Widget _buildPage(
    BuildContext context, {
    required bool usesAutomaticMirror,
    required String activeMirrorHost,
  }) {
    final s = S.of(context);
    final selectedBaseUrl = _preferredBaseUrl;
    final title = _isJable ? s.videoJableMirrorSettings : s.videoMirrorSettings;
    return SettingsSubpageScaffold(
      title: title,
      actions: [
        TextButton.icon(
          onPressed: _testing ? null : () => unawaited(_startProbe()),
          icon: const Icon(Icons.speed, size: 18),
          label: Text(s.videoMirrorRetest),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SettingsInfoCard(
            icon: Icons.language_outlined,
            title: title,
            child: Text(
              _isJable
                  ? s.videoJableMirrorDescription
                  : s.videoMirrorDescription,
            ),
          ),
          if (_testing) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                _testing || !_results.values.any((result) => result.isAvailable)
                ? null
                : _useFastest,
            icon: const Icon(Icons.speed),
            label: Text(s.videoMirrorUseFastest),
          ),
          const SizedBox(height: 16),
          SettingsSectionList(
            children: [
              SettingsListTile(
                icon: Icons.auto_mode,
                title: s.videoMirrorAutomatic,
                subtitle: usesAutomaticMirror
                    ? s.videoMirrorCurrent(activeMirrorHost)
                    : null,
                trailing: selectedBaseUrl == null
                    ? Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => unawaited(_select(null)),
              ),
              for (final mirror in _mirrors)
                SettingsListTile(
                  icon: Icons.dns_outlined,
                  title: mirror.host,
                  subtitle: _latencyLabel(s, _results[mirror.host]),
                  subtitleStyle: TextStyle(
                    color: _latencyColor(context, _results[mirror.host]),
                  ),
                  trailing: selectedBaseUrl == mirror.baseUrl
                      ? Text(s.videoMirrorInUse)
                      : TextButton(
                          onPressed:
                              !_testing &&
                                  (_results[mirror.host]?.isAvailable ?? false)
                              ? () => unawaited(_select(mirror))
                              : null,
                          child: Text(s.videoMirrorSelect),
                        ),
                  onTap:
                      !_testing && (_results[mirror.host]?.isAvailable ?? false)
                      ? () => unawaited(_select(mirror))
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
