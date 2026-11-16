import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/missav_mirrors.dart';
import 'package:kikoeru_flutter/src/videos/ui/missav_mirror_settings_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Prober extends MissavMirrorProber {
  _Prober({this.unavailableHost});

  final String? unavailableHost;

  @override
  Future<List<MissavMirrorLatency>> probeAll(
    Iterable<MissavMirror> mirrors, {
    MissavMirrorProbeCallback? onResult,
    CancelToken? cancelToken,
    int concurrency = 6,
  }) async {
    final results =
        mirrors
            .map(
              (mirror) => MissavMirrorLatency(
                mirror: mirror,
                millis: mirror.host == unavailableHost
                    ? null
                    : mirror.host == 'www.missav.watch'
                    ? 20
                    : 300,
                error: mirror.host == unavailableHost ? 'HTTP 503' : null,
              ),
            )
            .toList()
          ..sort(
            (left, right) =>
                (left.millis ?? 1 << 30).compareTo(right.millis ?? 1 << 30),
          );
    for (final result in results) {
      onResult?.call(result);
    }
    return results;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows latency and saves the selected mirror', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          theme: ThemeData(useMaterial3: true),
          home: MissavMirrorSettingsScreen(prober: _Prober()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final s = S.of(tester.element(find.byType(MissavMirrorSettingsScreen)));
    expect(find.text('www.missav.watch'), findsOneWidget);
    expect(find.text('20 ms'), findsOneWidget);

    await tester.tap(find.text('www.missav.watch'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(missavMirrorBaseUrlKey),
      'https://www.missav.watch',
    );
    final client = container.read(videoClientProvider);
    expect(client.activeMirrorHost, 'www.missav.watch');
    expect(client.usesAutomaticMirror, isFalse);

    await tester.tap(find.text(s.videoMirrorAutomatic).first);
    await tester.pumpAndSettle();

    expect(preferences.getString(missavMirrorBaseUrlKey), '');
    expect(client.usesAutomaticMirror, isTrue);
  });

  testWidgets('does not select an unavailable mirror', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          theme: ThemeData(useMaterial3: true),
          home: MissavMirrorSettingsScreen(
            prober: _Prober(unavailableHost: 'www.missav.watch'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final s = S.of(tester.element(find.byType(MissavMirrorSettingsScreen)));
    expect(find.text('${s.videoMirrorUnavailable} (HTTP 503)'), findsOneWidget);

    await tester.tap(find.text('www.missav.watch'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(missavMirrorBaseUrlKey), isNull);
    expect(container.read(videoClientProvider).usesAutomaticMirror, isTrue);
  });
}
