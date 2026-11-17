import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_stream_prefetch.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  test('resolves a mirror HLS redirect and keeps the request headers', () async {
    final requests = <HttpRequest>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request);
      if (request.uri.path.contains('/jmpres/')) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/hls/master.m3u8',
        );
      } else {
        request.response.write('#EXTM3U\n#EXT-X-VERSION:3\n');
      }
      await request.response.close();
    });

    final resolved = await resolveMissavMirrorStreamStart(
      VideoStream(
        label: 'Source',
        url:
            'http://127.0.0.1:${server.port}/jmpres/media.example/hls/master.m3u8',
        headers: const {
          'User-Agent': 'Test agent',
          'Referer': 'https://mirror.example/cn/video',
          'Origin': 'https://mirror.example',
        },
        isHls: true,
      ),
    );

    expect(resolved.url, 'http://127.0.0.1:${server.port}/hls/master.m3u8');
    expect(resolved.headers['Referer'], 'https://mirror.example/cn/video');
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.headers.value('user-agent'), 'Test agent');
      expect(
        request.headers.value('referer'),
        'https://mirror.example/cn/video',
      );
      expect(request.headers.value('origin'), 'https://mirror.example');
    }
  });

  test(
    'keeps the original URL when the response is not an HLS playlist',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('<html>blocked</html>');
        await request.response.close();
      });
      final stream = VideoStream(
        label: 'Source',
        url:
            'http://127.0.0.1:${server.port}/jmpres/media.example/hls/master.m3u8',
        isHls: true,
      );

      expect(await resolveMissavMirrorStreamStart(stream), same(stream));
    },
  );

  test('keeps the original URL when resolution exceeds the deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await Future<void>.delayed(const Duration(seconds: 4));
      try {
        request.response.write('#EXTM3U\n');
        await request.response.close();
      } catch (_) {
        // The client closes the stalled request at its deadline.
      }
    });
    final stream = VideoStream(
      label: 'Source',
      url:
          'http://127.0.0.1:${server.port}/jmpres/media.example/hls/master.m3u8',
      isHls: true,
    );
    final watch = Stopwatch()..start();

    expect(await resolveMissavMirrorStreamStart(stream), same(stream));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('cancels a redirect whose body never finishes', () async {
    final started = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        '/hls/master.m3u8',
      );
      await request.response.flush();
      started.complete();
      await Future<void>.delayed(const Duration(seconds: 4));
      try {
        await request.response.close();
      } catch (_) {
        // The cancelled client no longer reads the response.
      }
    });
    final stream = VideoStream(
      label: 'Source',
      url:
          'http://127.0.0.1:${server.port}/jmpres/media.example/hls/master.m3u8',
      isHls: true,
    );
    final prefetch = MissavStreamPrefetch(stream);
    final resolving = prefetch.resolve();
    await started.future;

    final cancelWatch = Stopwatch()..start();
    prefetch.cancel();

    expect(await resolving.timeout(const Duration(seconds: 1)), same(stream));
    expect(cancelWatch.elapsed, lessThan(const Duration(milliseconds: 800)));
  });

  test('accepts an HLS prefix split across response chunks', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path.contains('/jmpres/')) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/hls/master.m3u8',
        );
        await request.response.close();
        return;
      }
      request.response.bufferOutput = false;
      request.response.write('#EX');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      request.response.write('TM3U\n#EXT-X-VERSION:3\n');
      await request.response.close();
    });
    final stream = VideoStream(
      label: 'Source',
      url:
          'http://127.0.0.1:${server.port}/jmpres/media.example/hls/master.m3u8',
      isHls: true,
    );

    expect(
      (await resolveMissavMirrorStreamStart(stream)).url,
      isNot(stream.url),
    );
  });

  test('ignores non-mirror and non-HLS streams', () async {
    const direct = VideoStream(
      label: 'Source',
      url: 'https://media.example/hls/master.m3u8',
      isHls: true,
    );
    const file = VideoStream(
      label: 'Source',
      url: 'https://mirror.example/jmpres/media.example/file.mp4',
    );

    expect(await resolveMissavMirrorStreamStart(direct), same(direct));
    expect(await resolveMissavMirrorStreamStart(file), same(file));
  });
}
