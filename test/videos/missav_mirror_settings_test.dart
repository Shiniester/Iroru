import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/videos/jable_client.dart';
import 'package:iroru/src/videos/jable_mirrors.dart';
import 'package:iroru/src/videos/missav_mirrors.dart';
import 'package:iroru/src/videos/ui/missav_mirror_settings_screen.dart';
import 'package:iroru/src/videos/video_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Prober extends MissavMirrorProber {
  _Prober({this.unavailableHost, this.fastestHost = 'www.missav.watch'});

  final String? unavailableHost;
  final String fastestHost;

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
                    : mirror.host == fastestHost
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
    expect(find.text(s.videoMirrorCurrent('www.missav.watch')), findsOneWidget);

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

  testWidgets(
    'Jable shows the actual content host and keeps the manual choice',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        missavMirrorBaseUrlKey: missavMirrors.first.baseUrl,
      });
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const catalog =
          '<div id="site-content"><div id="list_videos_catalog"></div></div>';
      var mirrorAvailable = false;
      final officialDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: catalog),
            ),
          ),
        );
      final mirrorDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: mirrorAvailable ? catalog : '<title>Unavailable</title>',
              ),
            ),
          ),
        );
      final jableClient = JableClient(dio: officialDio, mirrorDio: mirrorDio);
      addTearDown(() {
        jableClient.dispose();
        officialDio.close(force: true);
        mirrorDio.close(force: true);
      });
      final container = ProviderContainer(
        overrides: [jableVideoClientProvider.overrideWithValue(jableClient)],
      );
      addTearDown(container.dispose);
      final jableHost = jableMirrors.first.host;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            theme: ThemeData(useMaterial3: true),
            home: MissavMirrorSettingsScreen.jable(
              prober: _Prober(fastestHost: jableHost),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final s = S.of(tester.element(find.byType(MissavMirrorSettingsScreen)));
      expect(find.text(s.videoJableMirrorSettings), findsWidgets);
      expect(find.text(jableHost), findsOneWidget);
      expect(find.text(missavMirrors.first.host), findsNothing);

      await tester.tap(find.text(jableHost));
      await tester.pumpAndSettle();

      final client = container.read(jableVideoClientProvider);
      expect(client.activeMirrorHost, jableHost);
      expect(client.usesAutomaticMirror, isFalse);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString(jableMirrorBaseUrlKey),
        jableMirrors.first.baseUrl,
      );
      expect(find.text(s.videoMirrorCurrent(jableHost)), findsNothing);

      await tester.runAsync(() => client.browse(client.homeUrl));
      await tester.pumpAndSettle();
      expect(find.text(s.videoMirrorCurrent('jable.tv')), findsOneWidget);
      expect(find.text(s.videoMirrorSelected), findsOneWidget);
      expect(
        preferences.getString(jableMirrorBaseUrlKey),
        jableMirrors.first.baseUrl,
      );

      mirrorAvailable = true;
      await tester.runAsync(() => client.browse(client.homeUrl));
      await tester.pumpAndSettle();
      expect(find.text(s.videoMirrorCurrent(jableHost)), findsOneWidget);

      await tester.tap(find.text(s.videoMirrorAutomatic));
      await tester.pumpAndSettle();

      expect(client.usesAutomaticMirror, isTrue);
    },
  );
}
