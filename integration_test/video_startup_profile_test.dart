import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixturePath = String.fromEnvironment('KIKOFLU_TEST_VIDEO');

  testWidgets(
    'windows local video startup profile',
    (tester) async {
      MediaKit.ensureInitialized();
      final fixture = File(fixturePath);
      expect(await fixture.exists(), isTrue);
      SharedPreferences.setMockInitialValues({});
      final library = VideoLibrary(
        preferences: await SharedPreferences.getInstance(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType.binary;
        response.contentLength = await fixture.length();
        await response.addStream(fixture.openRead());
        await response.close();
      });

      final url = 'http://127.0.0.1:${server.port}/fixture.mp4';
      final samples = <int>[];
      try {
        for (var run = 0; run < 3; run++) {
          final player = Player();
          final session = MediaKitVideoPlaybackSession(player: player);
          final watch = Stopwatch()..start();
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              supportedLocales: S.supportedLocales,
              localizationsDelegates: S.localizationsDelegates,
              home: Scaffold(
                body: VideoPlaybackPanel(
                  key: ValueKey('startup-$run'),
                  videoId: 'startup-$run',
                  library: library,
                  streams: [VideoStream(label: 'Fixture', url: url)],
                  autoPlayOnStart: true,
                  initialVolume: 0,
                  sessionFactory: () => session,
                ),
              ),
            ),
          );
          await session.videoController.waitUntilFirstFrameRendered.timeout(
            const Duration(seconds: 20),
          );
          watch.stop();
          samples.add(watch.elapsedMilliseconds);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await session.dispose();
        }
      } finally {
        library.dispose();
      }

      final sorted = [...samples]..sort();
      final result = {
        'platform': Platform.operatingSystem,
        'fixture': fixture.path,
        'samplesMs': samples,
        'medianMs': sorted[sorted.length ~/ 2],
      };
      final output = File('build/diagnostics/video-startup/windows.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(jsonEncode(result));
      debugPrint('VIDEO_STARTUP_PROFILE ${jsonEncode(result)}');
    },
    skip: fixturePath.isEmpty || !Platform.isWindows,
  );
}
