import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

import '../../integration_test/audio_effects_native_hls.dart';
import '../../integration_test/native_tls_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['KIKOFLU_AUDIO_LIBMPV'];
  setUpAll(() {
    if (library != null) MediaKit.ensureInitialized(libmpv: library);
  });
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  for (final host in ['127.0.0.1', 'localhost']) {
    test(
      'Android native HTTPS ${host == '127.0.0.1' ? 'trusts system certificates' : 'rejects a mismatched hostname'}',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final directory = await Directory.systemTemp.createTemp(
          'kiko-video-tls-',
        );
        final caFile = File.fromUri(directory.uri.resolve('ca.pem'));
        await caFile.writeAsString(nativeTlsCertificate);
        const channel = MethodChannel('com.meteor.kikoeruflutter/native_audio');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getCaFile');
          return caFile.path;
        });
        final context = SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(nativeTlsCertificate))
          ..usePrivateKeyBytes(utf8.encode(nativeTlsKey));
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        final requests = <String>[];
        server.listen((request) async {
          requests.add(request.uri.path);
          request.response.add(
            base64Decode(audioEffectsHlsFiles[request.uri.path]!),
          );
          await request.response.close();
        }, onError: (Object _) {});
        final player = Player();
        final session = MediaKitVideoPlaybackSession(player: player);
        final native = player.platform as NativePlayer;
        native.isVideoControllerAttached = false;
        final errors = <String>[];
        final failed = Completer<void>();
        final subscription = player.stream.error.listen((error) {
          errors.add(error);
          if (!failed.isCompleted) failed.complete();
        });
        try {
          final completed = player.stream.completed.firstWhere((done) => done);
          await session.loadStream(
            VideoStream(
              label: 'Source',
              url: 'https://$host:${server.port}/hls/index.m3u8',
              isHls: true,
            ),
            position: Duration.zero,
            volume: 0,
          );
          await session.play();
          await Future.any([
            completed,
            failed.future,
          ]).timeout(const Duration(seconds: 5));
          if (host == '127.0.0.1') {
            expect(errors, isEmpty);
            expect(session.snapshot.value.error, isNull);
            expect(requests, contains('/hls/segment00.ts'));
          } else {
            expect(errors, isNotEmpty);
            expect(session.snapshot.value.error, isNotNull);
            expect(requests, isEmpty);
          }
          expect(await native.getProperty('tls-verify'), 'yes');
          expect(await native.getProperty('tls-ca-file'), caFile.path);
        } finally {
          await subscription.cancel();
          await session.dispose();
          await server.close(force: true);
          messenger.setMockMethodCallHandler(channel, null);
          expect(
            await directory.parent.resolveSymbolicLinks(),
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          await directory.delete(recursive: true);
        }
      },
      skip: library == null
          ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native playback.'
          : false,
    );
  }

  test(
    'MissAV-style HLS segments decode through the native video session',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/master.m3u8') {
          request.response.headers.contentType = ContentType(
            'audio',
            'x-mpegurl',
          );
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=128000\n'
            'http://127.0.0.1:${server.port}/hls/index.m3u8\n',
          );
          await request.response.close();
          return;
        }
        final path = request.uri.path.replaceAll('.jpeg', '.ts');
        final bytes = base64Decode(audioEffectsHlsFiles[path]!);
        request.response.add(
          path.endsWith('.m3u8')
              ? utf8.encode(utf8.decode(bytes).replaceAll('.ts', '.jpeg'))
              : bytes,
        );
        await request.response.close();
      });
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      final native = player.platform as NativePlayer;
      native.isVideoControllerAttached = false;
      final errors = <String>[];
      final failed = Completer<void>();
      final errorSubscription = player.stream.error.listen((error) {
        errors.add(error);
        if (!failed.isCompleted) failed.complete();
      });
      try {
        await native.setProperty('demuxer', 'lavf');
        final completed = player.stream.completed.firstWhere((done) => done);
        await session.loadStream(
          VideoStream(
            label: 'Source',
            url: 'http://127.0.0.1:${server.port}/master.m3u8',
            isHls: true,
          ),
          position: Duration.zero,
          volume: 0,
        );
        await session.play();
        await Future.any([
          completed,
          failed.future,
        ]).timeout(const Duration(seconds: 5));
        expect(errors, isEmpty);
        expect(session.snapshot.value.error, isNull);
        expect(player.state.duration, greaterThan(Duration.zero));
        expect(requests, contains('/hls/index.m3u8'));
        expect(requests, contains('/hls/segment00.jpeg'));
      } finally {
        await errorSubscription.cancel();
        await session.dispose();
        await server.close(force: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real headless native playback.'
        : false,
  );
}
