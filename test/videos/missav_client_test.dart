import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/videos/missav_client.dart';
import 'package:iroru/src/services/proxy_config.dart';
import 'package:iroru/src/services/remote_asset_cache.dart';
import 'package:iroru/src/videos/missav_browser_adapter.dart';
import 'package:iroru/src/videos/missav_mirrors.dart';
import 'package:iroru/src/videos/video_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  int closeCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {
    closeCalls++;
  }
}

Dio _emptyMetadataDio() => Dio()
  ..httpClientAdapter = _Adapter(
    (_) => ResponseBody.fromString(
      '{"recomms":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );

ResponseBody _metadataResponse(Object body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _CancelAwareAdapter extends _Adapter {
  _CancelAwareAdapter(super.respond);

  int cancelledFetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cancelError = options.cancelToken?.cancelError;
    if (cancelError != null) {
      cancelledFetches++;
      throw cancelError;
    }
    requests.add(options);
    return respond(options);
  }
}

class _BlockingRequestTransformer implements Transformer {
  _BlockingRequestTransformer(this.started, this.release);

  final Completer<void> started;
  final Future<void> release;
  final FusedTransformer _delegate = FusedTransformer.sync();

  @override
  Future<String> transformRequest(RequestOptions options) async {
    if (!started.isCompleted) started.complete();
    await release;
    return _delegate.transformRequest(options);
  }

  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) => _delegate.transformResponse(options, responseBody);
}

class _MemorySecureStorage implements FlutterSecureStorage {
  static const cookieKey = 'iroru.missav_session_cookie';

  final values = <String, String>{};
  Future<void> Function()? beforeWrite;

  String? get cookie => values[cookieKey];

  set cookie(String? value) {
    if (value == null) {
      values.remove(cookieKey);
    } else {
      values[cookieKey] = value;
    }
  }

  Future<void> _write(String key, String? value) async {
    await beforeWrite?.call();
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.memberName;
    if (key == #read) {
      return Future<String?>.value(
        values[invocation.namedArguments[#key] as String],
      );
    }
    if (key == #write) {
      return _write(
        invocation.namedArguments[#key] as String,
        invocation.namedArguments[#value] as String?,
      );
    }
    if (key == #delete) {
      values.remove(invocation.namedArguments[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

_MemorySecureStorage _storedBrowserSession() {
  final storage = _MemorySecureStorage()..cookie = 'session=saved';
  storage.values['iroru.missav_verified_session'] = jsonEncode({
    'cookie': 'session=saved',
    'userAgent': 'Saved Browser UA',
  });
  return storage;
}

void _selectOriginAccountHost() => SharedPreferences.setMockInitialValues({
  missavAccountBaseUrlKey: MissavClient.origin,
});

ResponseBody _response(
  String body, {
  int statusCode = HttpStatus.ok,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  statusCode,
  headers: {
    'content-type': ['text/html; charset=utf-8'],
    ...headers,
  },
);

String _cookieHeader(RequestOptions options) {
  final values = options.headers.entries
      .where((entry) => entry.key.toLowerCase() == 'cookie')
      .map((entry) => '${entry.value}')
      .toList();
  return values.isEmpty ? '' : values.first;
}

String? _headerValue(RequestOptions options, String name) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return '${entry.value}';
    }
  }
  return null;
}

bool _hasHeader(Iterable<String> names, String name) =>
    names.any((candidate) => candidate.toLowerCase() == name.toLowerCase());

bool _isMirrorProbe(RequestOptions request) =>
    request.uri.path == '/status.html' ||
    request.uri.queryParameters.containsKey('ts');

String _searchCatalogHtml(List<String> ids, {String? nextUrl}) =>
    '''
<main>
${ids.map((id) => '<div class="relative aspect-w-16 aspect-h-9"><a href="/cn/$id"><img alt="Video $id" src="https://media.example/$id.jpg"></a></div>').join()}
${nextUrl == null ? '' : '<a href="$nextUrl" rel="next">Next</a>'}
</main>
''';

const _homeHtml = '''
<main>
  <h1>Home</h1>
  <div class="relative aspect-w-16 aspect-h-9">
    <a href="/cn/home-video"><img alt="Home video" src="https://media.example/home.jpg"></a>
  </div>
</main>
''';

Future<String> _detailHtml() =>
    File('test/fixtures/missav/detail.html').readAsString();

bool _isPageRequest(RequestOptions request) =>
    !request.uri.path.contains('/api/') &&
    !request.uri.host.contains('recombee.com') &&
    request.uri.path != '/status.html' &&
    !request.uri.queryParameters.containsKey('ts');

void _flushFakeAsync(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(Duration.zero);
  async.flushMicrotasks();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('MissAV content recovery', () {
    testWidgets('cancels slow lines and stops at the full page deadline', (
      tester,
    ) async {
      final hosts = [
        for (final mirror in missavMirrors.take(4)) mirror.baseUrl,
      ];
      final lateResponse = Completer<ResponseBody>();
      final adapter = _Adapter((_) => lateResponse.future);
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: hosts,
      );
      addTearDown(client.dispose);
      await client.initialize();
      final result = expectLater(
        client.browse('https://missav.ai/cn/release'),
        throwsA(
          isA<MissavException>().having(
            (error) => error.message,
            'message',
            contains('content loading timed out'),
          ),
        ),
      );
      await tester.pump(Duration.zero);
      expect(adapter.requests.single.uri.origin, hosts.first);
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.pump(const Duration(seconds: 4));
      }
      await result;
      expect(
        adapter.requests.map((request) => request.uri.origin),
        hosts.take(3),
      );
      expect(
        adapter.requests.every((request) => request.cancelToken!.isCancelled),
        isTrue,
      );
      lateResponse.complete(_response(_searchCatalogHtml(['late'])));
      await tester.pump(Duration.zero);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(missavLastGoodHostKey), isNull);
    });

    testWidgets('a deadline preserves an earlier official challenge', (
      tester,
    ) async {
      final slowResponse = Completer<ResponseBody>();
      final adapter = _Adapter((request) {
        if (request.uri.host == 'missav.live') {
          return _response(
            'Challenge',
            statusCode: HttpStatus.serviceUnavailable,
            headers: {
              'cf-mitigated': ['challenge'],
            },
          );
        }
        return slowResponse.future;
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: [
          'https://missav.live',
          missavMirrors.first.baseUrl,
          'https://missav.ws',
          'https://missav.ai',
        ],
      );
      addTearDown(client.dispose);
      final result = expectLater(
        client.browse('https://missav.ai/cn/release'),
        throwsA(isA<MissavVerificationRequiredException>()),
      );
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(seconds: 12));
      await result;
      slowResponse.complete(_response(_searchCatalogHtml(['late'])));
      await tester.pump(Duration.zero);
    });

    group('hedged detail mirrors', () {
      const item = VideoItem(
        id: 'open-sample-001',
        title: 'Sample',
        pageUrl: 'https://missav.ai/cn/open-sample-001',
      );
      late String detail;
      late List<String> hosts;
      late Map<String, Completer<ResponseBody>> responses;
      late _Adapter adapter;
      late MissavClient client;
      late Future<VideoDetails> pending;

      setUpAll(() async {
        detail = await _detailHtml();
      });

      Future<void> begin(
        WidgetTester tester, {
        CancelToken? cancelToken,
        String? selected,
      }) async {
        hosts = [for (final mirror in missavMirrors.take(4)) mirror.baseUrl];
        responses = {for (final host in hosts) host: Completer<ResponseBody>()};
        adapter = _Adapter((request) => responses[request.uri.origin]!.future);
        client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: hosts,
        );
        addTearDown(client.dispose);
        await client.initialize();
        if (selected != null) client.selectMirror(selected);
        pending = client.details(item, cancelToken: cancelToken);
        await tester.pump(Duration.zero);
      }

      List<String> requested() =>
          adapter.requests.map((request) => request.uri.origin).toList();

      testWidgets('waits 1500 ms before trying only the second mirror', (
        tester,
      ) async {
        await begin(tester);
        expect(client.isLoggedIn, isFalse);
        expect(requested(), [hosts[0]]);
        await tester.pump(const Duration(milliseconds: 1499));
        expect(requested(), [hosts[0]]);
        await tester.pump(const Duration(milliseconds: 1));
        expect(requested(), hosts.take(2));

        responses[hosts[1]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        expect(Uri.parse(details.video.pageUrl).host, Uri.parse(hosts[1]).host);
        expect(details.streams, hasLength(2));
        expect(adapter.requests.first.cancelToken!.isCancelled, isTrue);

        responses[hosts[0]]!.complete(
          _response(
            detail.replaceFirst(
              '<h1>Sample detail</h1>',
              '<h1>Late first mirror</h1>',
            ),
          ),
        );
        await tester.pump(Duration.zero);
        expect(requested(), hosts.take(2));
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), hosts[1]);
      });

      testWidgets('quick first result skips the backup mirror', (tester) async {
        await begin(tester);
        responses[hosts[0]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        await tester.pump(const Duration(seconds: 2));

        expect(requested(), [hosts[0]]);
        expect(Uri.parse(details.video.pageUrl).host, Uri.parse(hosts[0]).host);
        expect(details.streams, hasLength(2));
      });

      testWidgets('fast metadata-only detail tries the backup mirror', (
        tester,
      ) async {
        await begin(tester);
        responses[hosts[0]]!.complete(
          _response('<main><h1>Metadata only</h1></main>'),
        );
        await tester.pump(Duration.zero);
        expect(requested(), hosts.take(2));

        responses[hosts[1]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        expect(Uri.parse(details.video.pageUrl).origin, hosts[1]);
        expect(details.streams, isNotEmpty);
      });

      testWidgets('a fast rate-limited primary starts the backup immediately', (
        tester,
      ) async {
        await begin(tester);
        pending.ignore();
        expect(requested(), [hosts[0]]);

        responses[hosts[0]]!.complete(
          _response('', statusCode: HttpStatus.tooManyRequests),
        );
        await tester.pump(Duration.zero);
        expect(requested(), hosts.take(2));

        responses[hosts[1]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        expect(Uri.parse(details.video.pageUrl).origin, hosts[1]);
        expect(details.streams, hasLength(2));
      });

      testWidgets('a rate-limited primary leaves the active backup running', (
        tester,
      ) async {
        await begin(tester);
        pending.ignore();
        await tester.pump(const Duration(milliseconds: 1500));
        expect(requested(), hosts.take(2));

        responses[hosts[0]]!.complete(
          _response('', statusCode: HttpStatus.tooManyRequests),
        );
        await tester.pump(Duration.zero);
        expect(adapter.requests.last.cancelToken!.isCancelled, isFalse);

        responses[hosts[1]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        expect(Uri.parse(details.video.pageUrl).origin, hosts[1]);
        expect(details.streams, isNotEmpty);
      });

      for (final firstSucceeds in [true, false]) {
        testWidgets('backup is rate-limited (first succeeds=$firstSucceeds)', (
          tester,
        ) async {
          await begin(tester);
          pending.ignore();
          await tester.pump(const Duration(milliseconds: 1500));
          expect(requested(), hosts.take(2));

          responses[hosts[1]]!.complete(
            _response('', statusCode: HttpStatus.tooManyRequests),
          );
          await tester.pump(Duration.zero);
          expect(adapter.requests.first.cancelToken!.isCancelled, isFalse);

          if (firstSucceeds) {
            responses[hosts[0]]!.complete(_response(detail));
            await tester.pump(Duration.zero);
            final details = await pending;
            expect(Uri.parse(details.video.pageUrl).origin, hosts[0]);
            expect(details.streams, isNotEmpty);
          } else {
            final limited = expectLater(
              pending,
              throwsA(isA<MissavRateLimitException>()),
            );
            responses[hosts[0]]!.complete(
              _response('', statusCode: HttpStatus.badGateway),
            );
            await tester.pump(Duration.zero);
            await limited;
          }
          expect(requested(), hosts.take(2));
        });
      }

      testWidgets('playable backup beats a metadata-only first mirror', (
        tester,
      ) async {
        await begin(tester);
        await tester.pump(const Duration(milliseconds: 1500));
        expect(requested(), hosts.take(2));
        var completed = false;
        final result = pending.then((value) {
          completed = true;
          return value;
        });

        responses[hosts[0]]!.complete(
          _response('<main><h1>Metadata only</h1></main>'),
        );
        await tester.pump(Duration.zero);
        expect(completed, isFalse);

        responses[hosts[1]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await result;
        expect(completed, isTrue);
        expect(Uri.parse(details.video.pageUrl).host, Uri.parse(hosts[1]).host);
        expect(details.streams, hasLength(2));
      });

      testWidgets('remaining mirrors stay serial after both failures', (
        tester,
      ) async {
        await begin(tester);
        await tester.pump(const Duration(milliseconds: 1500));
        expect(requested(), hosts.take(2));

        responses[hosts[1]]!.complete(
          _response('', statusCode: HttpStatus.badGateway),
        );
        await tester.pump(Duration.zero);
        expect(requested(), hosts.take(2));

        responses[hosts[0]]!.complete(
          _response('', statusCode: HttpStatus.badGateway),
        );
        await tester.pump(Duration.zero);
        expect(requested(), hosts.take(3));
        await tester.pump(const Duration(seconds: 1));
        expect(requested(), hosts.take(3));

        responses[hosts[2]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        expect(Uri.parse(details.video.pageUrl).host, Uri.parse(hosts[2]).host);
        expect(details.streams, hasLength(2));
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), hosts[2]);
      });

      testWidgets('caller cancellation cancels both pending mirrors', (
        tester,
      ) async {
        final cancelToken = CancelToken();
        await begin(tester, cancelToken: cancelToken);
        final cancelled = expectLater(
          pending,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 1500));
        expect(requested(), hosts.take(2));

        cancelToken.cancel('Leave the detail page.');
        await tester.pump(Duration.zero);
        await cancelled;
        expect(
          adapter.requests.every((request) => request.cancelToken!.isCancelled),
          isTrue,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(requested(), hosts.take(2));
      });

      testWidgets('manual mirror selection stays serial', (tester) async {
        await begin(tester, selected: hosts[0]);
        await tester.pump(const Duration(seconds: 2));
        expect(requested(), [hosts[0]]);

        responses[hosts[0]]!.complete(
          _response('', statusCode: HttpStatus.badGateway),
        );
        await tester.pump(Duration.zero);
        expect(requested(), hosts.take(2));

        responses[hosts[1]]!.complete(_response(detail));
        await tester.pump(Duration.zero);
        final details = await pending;
        expect(Uri.parse(details.video.pageUrl).host, Uri.parse(hosts[1]).host);
        expect(details.streams, hasLength(2));
      });
    });

    test('a missing detail keeps the last good content line', () async {
      final mirror = missavMirrors.first.baseUrl;
      SharedPreferences.setMockInitialValues({missavLastGoodHostKey: mirror});
      final adapter = _Adapter((_) => _response('', statusCode: 404));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: [mirror],
      );
      addTearDown(client.dispose);

      await expectLater(
        client.details(
          const VideoItem(
            id: 'missing',
            title: 'Missing detail',
            pageUrl: 'https://missav.ws/cn/missing',
          ),
          includeAccountState: false,
        ),
        throwsA(isA<MissavException>()),
      );
      expect(adapter.requests.first.uri.origin, mirror);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(missavLastGoodHostKey), mirror);
    });

    test(
      'detail skips an invalid page and a timeout before saving a working line',
      () async {
        final invalid = missavMirrors[0].baseUrl;
        final timeout = missavMirrors[1].baseUrl;
        final good = missavMirrors[2].baseUrl;
        final detail = await _detailHtml();
        final adapter = _Adapter((request) {
          if (request.uri.origin == invalid) return _response('<main></main>');
          if (request.uri.origin == timeout) {
            throw DioException.receiveTimeout(
              timeout: const Duration(seconds: 1),
              requestOptions: request,
            );
          }
          if (!request.uri.path.startsWith('/dm42/')) {
            return _response(
              '',
              statusCode: HttpStatus.found,
              headers: {
                HttpHeaders.locationHeader: ['/dm42${request.uri.path}'],
              },
            );
          }
          return _response(detail);
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [invalid, timeout, good],
        );
        addTearDown(client.dispose);
        client.setLocale('ja');

        final details = await client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/ja/open-sample-001',
          ),
        );

        final pages = adapter.requests.where(_isPageRequest).toList();
        expect(pages.map((request) => request.uri.toString()), [
          '$invalid/ja/open-sample-001',
          '$timeout/ja/open-sample-001',
          '$good/ja/open-sample-001',
          '$good/dm42/ja/open-sample-001',
        ]);
        expect(_headerValue(pages.last, 'Referer'), '$good/');
        expect(details.video.title, 'Sample detail');
        expect(details.streams.map((stream) => stream.url), [
          '$good/jmpres/media.example/hls/master.m3u8',
          '$good/jmpres/media.example/file/clip.mp4',
        ]);
        for (final stream in details.streams) {
          expect(
            stream.headers[HttpHeaders.refererHeader],
            '$good/dm42/ja/open-sample-001',
          );
          expect(stream.headers['Origin'], good);
        }
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), good);
      },
    );

    test(
      'keeps a mirror catalog with video cards but no main element',
      () async {
        final first = missavMirrors[0].baseUrl;
        final fallback = missavMirrors[1].baseUrl;
        final adapter = _Adapter(
          (request) => _response(
            request.uri.origin == first
                ? _searchCatalogHtml([
                    'first-video',
                  ]).replaceAll('<main>', '').replaceAll('</main>', '')
                : _searchCatalogHtml(['fallback-video']),
          ),
        );
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [first, fallback],
        );
        addTearDown(client.dispose);

        final page = await client.browse('https://missav.ai/cn/release');

        expect(page.videos.single.id, 'first-video');
        expect(adapter.requests, hasLength(1));
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), first);
      },
    );

    for (final hasTitle in [true, false]) {
      test(
        'opens anonymous mirror details without main ${hasTitle ? 'with' : 'without'} a title',
        () async {
          final mirror = missavMirrors[0].baseUrl;
          final fallback = missavMirrors[1].baseUrl;
          var detail = (await _detailHtml())
              .replaceAll('<main', '<div')
              .replaceAll('</main>', '</div>');
          if (!hasTitle) {
            detail = detail.replaceAll('<h1>Sample detail</h1>', '<h1> </h1>');
          }
          final catalog = _searchCatalogHtml([
            'open-sample-001',
          ]).replaceAll('<main>', '<div>').replaceAll('</main>', '</div>');
          final adapter = _Adapter((request) {
            if (request.uri.origin != mirror) {
              throw StateError('Unexpected fallback request.');
            }
            return _response(
              request.uri.path.endsWith('/release') ? catalog : detail,
            );
          });
          final client = MissavClient(
            dio: Dio()..httpClientAdapter = adapter,
            metadataDio: _emptyMetadataDio(),
            secureStorage: _MemorySecureStorage(),
            contentHosts: [mirror, fallback],
          );
          addTearDown(client.dispose);

          final page = await client.browse('https://missav.ai/cn/release');
          final updates = <VideoDetails>[];
          final details = await client.details(
            page.videos.single,
            onReady: updates.add,
          );

          expect(client.isLoggedIn, isFalse);
          expect(
            details.video.title,
            hasTitle ? 'Sample detail' : page.videos.single.title,
          );
          expect(updates.first.streams, hasLength(2));
          expect(details.streams.map((stream) => stream.url), [
            '$mirror/jmpres/media.example/hls/master.m3u8',
            '$mirror/jmpres/media.example/file/clip.mp4',
          ]);
          expect(adapter.requests.map((request) => request.uri.toString()), [
            '$mirror/cn/release',
            '$mirror/cn/open-sample-001',
          ]);
          expect(
            adapter.requests.every((request) => _cookieHeader(request).isEmpty),
            isTrue,
          );
          final preferences = await SharedPreferences.getInstance();
          expect(preferences.getString(missavLastGoodHostKey), mirror);
        },
      );
    }

    for (final hasErrorTitle in [false, true]) {
      test(
        'rejects a detail placeholder without main ${hasErrorTitle ? 'with an error title' : 'with only cards'}',
        () async {
          final invalid = missavMirrors[0].baseUrl;
          final good = missavMirrors[1].baseUrl;
          final detail = await _detailHtml();
          final placeholder = hasErrorTitle
              ? '<h1>Service temporarily unavailable</h1>'
              : _searchCatalogHtml(
                  ['placeholder-video'],
                ).replaceAll('<main>', '<div>').replaceAll('</main>', '</div>');
          final adapter = _Adapter(
            (request) =>
                _response(request.uri.origin == invalid ? placeholder : detail),
          );
          final client = MissavClient(
            dio: Dio()..httpClientAdapter = adapter,
            metadataDio: _emptyMetadataDio(),
            secureStorage: _MemorySecureStorage(),
            contentHosts: [invalid, good],
          );
          addTearDown(client.dispose);

          final details = await client.details(
            const VideoItem(
              id: 'open-sample-001',
              title: 'Sample',
              pageUrl: 'https://missav.ai/cn/open-sample-001',
            ),
          );

          expect(adapter.requests.map((request) => request.uri.origin), [
            invalid,
            good,
          ]);
          expect(details.video.pageUrl, '$good/cn/open-sample-001');
          expect(details.streams, hasLength(2));
          final preferences = await SharedPreferences.getInstance();
          expect(preferences.getString(missavLastGoodHostKey), good);
        },
      );
    }

    test(
      'does not accept a self-link placeholder as a video catalog',
      () async {
        final first = missavMirrors[0].baseUrl;
        final fallback = missavMirrors[1].baseUrl;
        final adapter = _Adapter(
          (request) => _response(
            request.uri.origin == first
                ? '''
<div class="relative aspect-w-16 aspect-h-9">
  <a href="#"><img alt="Loading video"></a>
</div>
'''
                : _searchCatalogHtml(['fallback-video']),
          ),
        );
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [first, fallback],
        );
        addTearDown(client.dispose);

        final page = await client.browse('https://missav.ai/cn/release');

        expect(page.videos.single.id, 'fallback-video');
        expect(adapter.requests, hasLength(2));
      },
    );

    test(
      'browse falls back from an invalid 200 page and accepts an empty main',
      () async {
        final invalid = missavMirrors[0].baseUrl;
        final good = missavMirrors[1].baseUrl;
        final adapter = _Adapter((request) {
          if (request.uri.host == Uri.parse(invalid).host) {
            return _response('<div>Placeholder page</div>');
          }
          if (request.uri.path.endsWith('/empty')) {
            return _response('<main></main>');
          }
          return _response(_searchCatalogHtml(['valid-page']));
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [invalid, good],
        );
        addTearDown(client.dispose);

        final page = await client.browse('https://missav.ai/cn/release');
        final empty = await client.browse('https://missav.ai/cn/empty');

        expect(page.videos.single.id, 'valid-page');
        expect(empty.videos, isEmpty);
        expect(empty.title, '');
        expect(adapter.requests.map((request) => request.uri.host), [
          Uri.parse(invalid).host,
          Uri.parse(good).host,
          Uri.parse(good).host,
        ]);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), good);
      },
    );

    for (final status in [401, 404, 410, 419]) {
      test('stops on HTTP $status without changing the cached line', () async {
        final selected = missavMirrors[0].baseUrl;
        final next = missavMirrors[1].baseUrl;
        SharedPreferences.setMockInitialValues({
          missavMirrorBaseUrlKey: selected,
          missavLastGoodHostKey: selected,
        });
        final adapter = _Adapter((request) {
          return request.uri.host == Uri.parse(selected).host
              ? _response('', statusCode: status)
              : _response(_searchCatalogHtml(['unexpected-line']));
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [selected, next],
        );
        addTearDown(client.dispose);
        await client.initialize();
        client.selectMirror(selected);

        await expectLater(
          client.browse('https://missav.ai/cn/release'),
          throwsA(isA<MissavException>()),
        );

        expect(adapter.requests.map((request) => request.uri.host), [
          Uri.parse(selected).host,
        ]);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), selected);
        expect(preferences.getString(missavMirrorBaseUrlKey), selected);
      });
    }

    test('detail tries its own content host before a selected line', () async {
      final source = missavMirrors[0].baseUrl;
      final selected = missavMirrors[1].baseUrl;
      final detail = await _detailHtml();
      final adapter = _Adapter(
        (request) => request.uri.origin == source
            ? _response(detail)
            : _response('', statusCode: HttpStatus.notFound),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: [selected, source, MissavClient.origin],
      );
      addTearDown(client.dispose);
      client.selectMirror(selected);

      final details = await client.details(
        VideoItem(
          id: 'open-sample-001',
          title: 'Sample',
          pageUrl: '$source/dm42/cn/open-sample-001',
        ),
      );

      expect(adapter.requests.map((request) => request.uri.origin), [source]);
      expect(details.video.pageUrl, '$source/dm42/cn/open-sample-001');
      expect(details.streams, hasLength(2));
    });

    test(
      'detail falls back to the account line after content hosts return 404',
      () async {
        final selected = missavMirrors[0].baseUrl;
        final next = missavMirrors[1].baseUrl;
        final detail = await _detailHtml();
        final adapter = _Adapter(
          (request) => request.uri.origin == MissavClient.origin
              ? _response(detail)
              : _response('', statusCode: HttpStatus.notFound),
        );
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [selected, next],
        );
        addTearDown(client.dispose);
        await client.selectAccountHost(MissavClient.origin);
        client.selectMirror(selected);

        final details = await client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
          includeAccountState: false,
        );

        expect(adapter.requests.map((request) => request.uri.origin), [
          selected,
          next,
          MissavClient.origin,
        ]);
        expect(details.video.title, 'Sample detail');
        expect(details.streams, hasLength(2));
      },
    );

    test(
      'redirect failure keeps official requests behind every mirror',
      () async {
        final looping = missavMirrors[0].baseUrl;
        final redirecting = missavMirrors[1].baseUrl;
        final working = missavMirrors[2].baseUrl;
        final adapter = _Adapter((request) {
          if (request.uri.origin == looping ||
              request.uri.origin == redirecting) {
            return _response(
              '',
              statusCode: HttpStatus.found,
              headers: {
                HttpHeaders.locationHeader: [
                  if (request.uri.origin == looping)
                    request.uri.path
                  else
                    '${MissavClient.origin}${request.uri.path}',
                ],
              },
            );
          }
          return _response(_searchCatalogHtml(['valid-page']));
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [MissavClient.origin, looping, redirecting, working],
        );
        addTearDown(client.dispose);

        final page = await client.browse('https://missav.ai/cn/release');

        expect(page.url, '$working/cn/release');
        expect(
          adapter.requests.map((request) => request.uri.origin).toSet(),
          orderedEquals([looping, redirecting, working]),
        );
      },
    );

    test(
      'detail reads account state from its own line while browse switches hosts',
      () async {
        final mirror = missavMirrors[0].baseUrl;
        const official = MissavClient.origin;
        final detail = await _detailHtml();
        final adapter = _Adapter((request) {
          if (request.uri.path.contains('/api/')) {
            throw StateError('Unexpected account API request.');
          }
          if (request.uri.path.endsWith('/release')) {
            return request.uri.host == Uri.parse(mirror).host
                ? _response('', statusCode: HttpStatus.badGateway)
                : _response(_searchCatalogHtml(['browse-official']));
          }
          return _response(detail);
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [mirror, official],
        );
        addTearDown(client.dispose);
        var browsed = false;

        final details = await client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
          onReady: (value) async {
            if (browsed) return;
            browsed = true;
            await client.browse('https://missav.ai/cn/release');
          },
        );

        expect(browsed, isTrue);
        expect(
          adapter.requests
              .where(_isPageRequest)
              .map((request) => '${request.uri.host}${request.uri.path}'),
          [
            '${Uri.parse(mirror).host}/cn/open-sample-001',
            '${Uri.parse(mirror).host}/cn/release',
            '${Uri.parse(official).host}/cn/release',
          ],
        );
        expect(
          details.streams.map((stream) => Uri.parse(stream.url).host).toSet(),
          {Uri.parse(mirror).host},
        );
      },
    );

    test('does not reload content after an onReady supplement error', () async {
      final detail = await _detailHtml();
      final adapter = _Adapter((request) {
        if (request.uri.path.contains('/api/')) {
          return _response('', statusCode: HttpStatus.serviceUnavailable);
        }
        if (request.uri.host == Uri.parse(MissavClient.origin).host) {
          return _response(detail);
        }
        return _response(_searchCatalogHtml(['unexpected-line']));
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: [MissavClient.origin],
      );
      addTearDown(client.dispose);
      final updates = <VideoDetails>[];

      await expectLater(
        client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
          onReady: updates.add,
        ),
        throwsA(isA<MissavException>()),
      );

      expect(updates, hasLength(2));
      expect(
        adapter.requests
            .where(_isPageRequest)
            .map((request) => request.uri.host),
        [Uri.parse(MissavClient.origin).host],
      );
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(missavLastGoodHostKey), isNull);
    });

    test('playlist cover recovers through the next content line', () async {
      final invalid = missavMirrors[0].baseUrl;
      final good = missavMirrors[1].baseUrl;
      final adapter = _Adapter((request) {
        return request.uri.host == Uri.parse(invalid).host
            ? _response('<div>Placeholder page</div>')
            : _response(_searchCatalogHtml(['first-cover']));
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: [invalid, good],
      );
      addTearDown(client.dispose);

      final cover = await client.loadPlaylistCover(
        'https://missav.ai/cn/playlists/sample',
      );

      expect(cover, 'https://media.example/first-cover.jpg');
      expect(adapter.requests.map((request) => request.uri.host), [
        Uri.parse(invalid).host,
        Uri.parse(good).host,
      ]);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(missavLastGoodHostKey), good);
    });

    test(
      'first recommendations page recovers through the next content line',
      () async {
        final invalid = missavMirrors[0].baseUrl;
        final good = missavMirrors[1].baseUrl;
        final source = _Adapter((request) {
          return request.uri.host == Uri.parse(invalid).host
              ? _response('<div>Placeholder page</div>')
              : _response(_homeHtml);
        });
        final metadata = _Adapter(
          (_) => _metadataResponse({
            'recommId': 'home-cursor',
            'recomms': [
              {'id': 'home-video', 'values': <String, Object?>{}},
            ],
          }),
        );
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = source,
          metadataDio: Dio()..httpClientAdapter = metadata,
          secureStorage: _MemorySecureStorage(),
          contentHosts: [invalid, good],
        );
        addTearDown(client.dispose);

        final page = await client.loadRecommendations(count: 40);

        expect(page.videos.single.id, 'home-video');
        expect(source.requests.map((request) => request.uri.host), [
          Uri.parse(invalid).host,
          Uri.parse(good).host,
        ]);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(missavLastGoodHostKey), good);
      },
    );
  });

  group('VideoItem', () {
    test('round-trips its stable fields', () {
      const item = VideoItem(
        id: 'sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/sample-001',
        cover: 'https://media.example/cover.jpg',
        durationSeconds: 90,
        releaseDate: '2024-03-02',
        actors: [
          VideoLink(
            label: 'Sample actor',
            url: 'https://missav.ai/cn/actresses/sample',
            kind: VideoLinkKind.actor,
          ),
        ],
        tags: [
          VideoLink(
            label: 'Drama',
            url: 'https://missav.ai/cn/genres/drama',
            kind: VideoLinkKind.category,
          ),
        ],
        hasSubtitles: true,
        isUncensored: true,
        makers: ['Studio A'],
        labels: ['Label A'],
        series: ['Series A'],
        directors: ['Director A'],
      );

      expect(VideoItem.fromJson(item.toJson()).toJson(), item.toJson());
    });

    test('uses empty cover and nullable duration defaults', () {
      const item = VideoItem(
        id: 'sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/sample-001',
      );

      expect(item.cover, '');
      expect(item.durationSeconds, isNull);
      final restored = VideoItem.fromJson({
        'id': item.id,
        'title': item.title,
        'pageUrl': item.pageUrl,
      });
      expect(restored.releaseDate, isNull);
      expect(restored.actors, isEmpty);
      expect(restored.tags, isEmpty);
      expect(restored.makers, isEmpty);
      expect(restored.labels, isEmpty);
      expect(restored.series, isEmpty);
      expect(restored.directors, isEmpty);
      expect(restored.hasSubtitles, isFalse);
      expect(restored.isUncensored, isFalse);
    });

    test(
      'separates optional directories in legacy tags without losing links',
      () {
        final item = VideoItem.fromJson({
          'id': 'legacy',
          'title': 'Legacy video',
          'pageUrl': 'https://missav.ai/cn/legacy',
          'makers': ['Studio A'],
          'tags': [
            for (final (route, label) in [
              ('genres/drama', 'Drama'),
              ('genres/labels', 'Labels genre'),
              ('dm691/cn/makers/studio-a', 'Studio A'),
              ('cn/studios/studio-b', 'Studio B'),
              ('labels/label-a', 'Label A'),
              ('series/series-a', 'Series A'),
              ('directors/director-a', 'Director A'),
            ])
              VideoLink(
                label: label,
                url: 'https://missav.ai/$route',
                kind: VideoLinkKind.category,
              ).toJson(),
          ],
        });

        expect(item.cardTags.map((tag) => tag.label), [
          'Drama',
          'Labels genre',
        ]);
        expect(item.cardMakers, ['Studio A', 'Studio B']);
        expect(item.cardLabels, ['Label A']);
        expect(item.cardSeries, ['Series A']);
        expect(item.cardDirectors, ['Director A']);
        expect(item.tags, hasLength(7));
        expect(
          item.toJson()['tags'][2]['url'],
          'https://missav.ai/dm691/cn/makers/studio-a',
        );
      },
    );
  });

  test('unknown video link kinds remain readable as other', () {
    final link = VideoLink.fromJson({
      'label': 'Sample link',
      'url': 'https://missav.ai/sample',
      'kind': 'future-kind',
    });

    expect(link.kind, VideoLinkKind.other);
    expect(link.toJson()['kind'], 'other');
    expect(link.sourceKey, isNull);
    expect(link.isAdded, isNull);
  });

  test(
    'parses the source card structure and leaves media URLs untouched',
    () async {
      _selectOriginAccountHost();
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final adapter = _Adapter((_) => _response(fixture));
      final storage = _MemorySecureStorage()..cookie = 'session=source-only';
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      client.setLocale('ja');
      final page = await client.browse('https://missav.ai/dm285/ja');

      expect(page.title, 'Newest videos');
      expect(page.videos, hasLength(2));
      expect(page.videos.first.id, 'open-sample-001');
      expect(page.videos.first.pageUrl, 'https://missav.ai/ja/open-sample-001');
      expect(
        page.videos.first.cover,
        'https://fourhoi.com/sample-001/cover-t.jpg',
      );
      expect(page.videos.first.durationSeconds, 83);
      expect(page.videos.last.durationSeconds, 3723);
      expect(page.navigation.map((link) => link.label), ['Home', 'Actors']);
      expect(page.links.map((link) => link.label), [
        'Sample category',
        'Sample actor',
      ]);
      expect(page.links.first.kind, VideoLinkKind.category);
      expect(page.links.last.kind, VideoLinkKind.actor);
      expect(
        page.links.last.cover,
        'https://fourhoi.com/actor/987654321-t.jpg',
      );
      expect(client.homeUrl, 'https://missav.ai/dm285/ja');
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.host, 'missav.ai');
      expect(_cookieHeader(adapter.requests.single), 'session=source-only');
      expect(client.isLoggedIn, isFalse);
      expect(storage.cookie, 'session=source-only');
    },
  );

  test('parses mirror cards without sending the canonical session', () async {
    final adapter = _Adapter(
      (_) => _response('''
<main>
<div class="relative aspect-w-16 aspect-h-9">
  <a href="https://www.missav9.net/en/mirror-sample"><img alt="Mirror sample" src="https://media.example/mirror.jpg"></a>
</div>
</main>
'''),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _storedBrowserSession(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://www.missav9.net/en/release');

    expect(page.videos.single.id, 'mirror-sample');
    expect(
      page.videos.single.pageUrl,
      'https://www.missav9.net/en/mirror-sample',
    );
    expect(_cookieHeader(adapter.requests.single), '');
  });

  test('maps legacy mirror page URLs to the active line', () async {
    final adapter = _Adapter(
      (_) => _response(_searchCatalogHtml(['legacy-mirror'])),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    await client.initialize();
    client.selectMirror('https://www.missav9.net');

    final page = await client.browse('https://www.thisav66.com/en/release');

    expect(page.videos.single.id, 'legacy-mirror');
    expect(adapter.requests.single.uri.host, 'www.missav9.net');
  });

  test('maps legacy mirror page URLs to the origin fallback', () async {
    final adapter = _Adapter(
      (_) => _response(_searchCatalogHtml(['legacy-origin'])),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://www.thisav66.com/en/release');

    expect(page.videos.single.id, 'legacy-origin');
    expect(adapter.requests.single.uri.host, 'missav.ai');
  });

  test('loads the first playlist cover from its first page', () async {
    final source = _Adapter(
      (_) => _response(_searchCatalogHtml(['first', 'second'])),
    );
    final metadata = _Adapter(
      (_) => throw StateError('Unexpected metadata request.'),
    );
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()..httpClientAdapter = metadata,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final cover = await client.loadPlaylistCover(
      'https://missav.ai/cn/playlists/sample?page=4&sort=views&tag=a&tag=b',
    );
    await client.loadPlaylistCover(
      'https://missav.ai/cn/playlists/sample?page=9',
    );

    expect(cover, 'https://media.example/first.jpg');
    expect(source.requests, hasLength(2));
    expect(source.requests.first.uri.queryParametersAll, {
      'sort': ['views'],
      'tag': ['a', 'b'],
    });
    expect(source.requests.last.uri.hasQuery, isFalse);
    expect(
      source.requests.last.uri.toString(),
      'https://missav.ai/cn/playlists/sample',
    );
    expect(metadata.requests, isEmpty);
  });

  test(
    'returns null for an empty playlist or a video without a cover',
    () async {
      final source = _Adapter(
        (request) => _response(
          request.uri.path.endsWith('/empty')
              ? '<main></main>'
              : '''
<main>
<div class="relative aspect-w-16 aspect-h-9">
  <a href="/cn/no-cover"><img alt="No cover"></a>
</div>
</main>
''',
        ),
      );
      final metadata = _Adapter(
        (_) => throw StateError('Unexpected metadata request.'),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      expect(
        await client.loadPlaylistCover('https://missav.ai/cn/playlists/empty'),
        isNull,
      );
      expect(
        await client.loadPlaylistCover(
          'https://missav.ai/cn/playlists/no-cover',
        ),
        isNull,
      );
      expect(source.requests, hasLength(2));
      expect(metadata.requests, isEmpty);
    },
  );

  test(
    'propagates cancellation instead of returning a playlist cover',
    () async {
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final source = _Adapter((_) {
        started.complete();
        return response.future;
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final cancelToken = CancelToken();

      final loading = client.loadPlaylistCover(
        'https://missav.ai/cn/playlists/sample',
        cancelToken: cancelToken,
      );
      final cancelled = expectLater(
        loading,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      cancelToken.cancel('Playlist preview was cancelled.');
      response.complete(_response(_searchCatalogHtml(['first'])));
      await cancelled;
    },
  );

  test(
    'session changes cancel and reject an in-flight playlist cover',
    () async {
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final source = _Adapter((_) {
        started.complete();
        return response.future;
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final cancelToken = CancelToken();

      final loading = client.loadPlaylistCover(
        'https://missav.ai/cn/playlists/sample',
        cancelToken: cancelToken,
      );
      final rejected = expectLater(loading, throwsA(isA<MissavException>()));
      await started.future;
      await client.logout();

      expect(cancelToken.isCancelled, isTrue);
      response.complete(_response(_searchCatalogHtml(['stale'])));
      await rejected;
    },
  );

  test('keeps an actor cover when its image has no alt text', () async {
    const html = '''
      <!doctype html>
      <html lang="en">
        <head><title>My actress collection</title></head>
        <body x-data="{user: null}">
          <main>
            <a href="/en/actresses/sample-actor">
              <span>Sample actor</span>
              <img src="data:image/svg+xml,placeholder"
                   data-src="https://fourhoi.com/actor/sample-t.jpg">
            </a>
          </main>
        </body>
      </html>
    ''';
    final adapter = _Adapter((_) => _response(html));
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/en/saved/actresses');

    expect(page.links, hasLength(1));
    expect(page.links.single.label, 'Sample actor');
    expect(page.links.single.kind, VideoLinkKind.actor);
    expect(page.links.single.cover, 'https://fourhoi.com/actor/sample-t.jpg');
  });

  for (final (collection, path, kind) in [
    ('actorFavorites', '/cn/actresses/sample-actor', VideoLinkKind.actor),
    ('playlists', '/cn/playlists/sample-list', VideoLinkKind.playlist),
  ]) {
    test('$collection opens cards outside a main container', () async {
      final adapter = _Adapter(
        (_) => _response('''
<div class="relative aspect-w-16 aspect-h-9">
  <a href="$path"><img alt="Saved entry" src="https://media.example/cover.jpg"></a>
</div>
'''),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
        contentHosts: [missavMirrors.first.baseUrl, MissavClient.origin],
      );
      addTearDown(client.dispose);
      await client.selectAccountHost(MissavClient.origin);

      final page = await client.browse(client.collectionUrl(collection));

      expect(page.videos, isEmpty);
      expect(page.links.single.kind, kind);
      expect(page.links.single.label, 'Saved entry');
      expect(page.links.single.url, '${MissavClient.origin}$path');
      expect(adapter.requests.single.uri.origin, MissavClient.origin);
    });
  }

  test(
    'homepage recommendations preserve source order and continue by cursor',
    () async {
      final fixture = await File(
        'test/fixtures/missav/home_recommendations.html',
      ).readAsString();
      final source = _Adapter((_) => _response(fixture));
      var nextRequests = 0;
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/users/anonymous/')) {
          return _metadataResponse({'recomms': []});
        }
        if (request.uri.path.contains('/next/')) {
          nextRequests++;
          return _metadataResponse({
            'recommId': 'first-cursor',
            'recomms': nextRequests == 1
                ? [
                    {
                      'id': 'sample-003',
                      'values': {'title_cn': 'Next item'},
                    },
                  ]
                : [],
          });
        }
        return _metadataResponse({
          'recommId': 'first-cursor',
          'recomms': [
            {
              'id': 'sample-002-chinese-subtitle',
              'values': {
                'title_cn': 'First item',
                'duration': 83,
                'has_chinese_subtitle': true,
                'dm': 691,
                'actresses': ['Actor A'],
                'genres': ['Tag A'],
              },
            },
            {
              'id': 'sample-001',
              'values': {'title_cn': 'Second item'},
            },
          ],
        });
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage()..cookie = 'session=source-only',
      );
      addTearDown(client.dispose);
      final first = await client.loadRecommendations(count: 40);
      expect(first.videos.map((video) => video.id), [
        'sample-002-chinese-subtitle',
        'sample-001',
      ]);
      expect(first.videos.first.title, 'SAMPLE-002 First item');
      expect(first.videos.first.durationSeconds, 83);
      expect(first.videos.first.hasSubtitles, isTrue);
      expect(first.videos.first.actors.single.label, 'Actor A');
      expect(first.videos.first.tags.single.label, 'Tag A');
      expect(metadata.requests, hasLength(1));
      expect(
        first.videos.first.pageUrl,
        contains(
          '/dm691/cn/sample-002-chinese-subtitle#first-cursor_desktop-home-recommended',
        ),
      );
      expect(
        first.videos.first.cover,
        'https://fourhoi.com/sample-002-chinese-subtitle/cover-t.jpg',
      );
      expect(first.cursor, 'first-cursor');
      final request = metadata.requests.first;
      expect(
        request.uri.path,
        '/missav-default/recomms/users/source-visitor/items/',
      );
      expect(request.uri.queryParameters['frontend_sign'], isNotEmpty);
      expect(request.data, containsPair('count', 40));
      expect(
        request.data,
        containsPair('scenario', 'desktop-home-recommended'),
      );
      expect(
        request.data,
        containsPair('logic', {
          'name': 'missav:personal',
          'settings': {'spotlightVideoIds': <String>[]},
        }),
      );
      expect(
        metadata.requests.every((request) => _cookieHeader(request).isEmpty),
        isTrue,
      );
      final next = await client.loadRecommendations(
        cursor: first.cursor,
        count: 40,
      );
      expect(next.videos.single.id, 'sample-003');
      expect(next.cursor, 'first-cursor');
      final nextRequest = metadata.requests.firstWhere(
        (request) => request.uri.path.contains('/next/'),
      );
      expect(
        nextRequest.uri.path,
        '/missav-default/recomms/next/items/first-cursor',
      );
      expect(nextRequest.data, {'count': 40, 'cascadeCreate': true});
      final end = await client.loadRecommendations(
        cursor: next.cursor,
        count: 40,
      );
      expect(end.videos, isEmpty);
      expect(source.requests, hasLength(1));
    },
  );

  test(
    'home recommendations use an anonymous identity and reject invalid responses',
    () async {
      final fixture = await File(
        'test/fixtures/missav/home_recommendations.html',
      ).readAsString();
      for (final withContext in [false, true]) {
        final source = _Adapter(
          (_) =>
              _response(withContext ? fixture : '<main><h1>Home</h1></main>'),
        );
        final metadata = _Adapter(
          (_) => _metadataResponse(
            withContext
                ? {'notRecommendations': []}
                : {
                    'recommId': 'anonymous-cursor',
                    'recomms': [
                      {
                        'id': 'sample',
                        'values': {'title_en': 'Anonymous sample'},
                      },
                    ],
                  },
          ),
        );
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = source,
          metadataDio: Dio()..httpClientAdapter = metadata,
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        if (withContext) {
          await expectLater(
            client.loadRecommendations(count: 40),
            throwsA(
              allOf(
                isA<MissavException>(),
                isNot(isA<MissavVerificationRequiredException>()),
              ),
            ),
          );
        } else {
          final page = await client.loadRecommendations(count: 40);
          expect(page.videos.single.id, 'sample');
          expect(
            metadata.requests.single.uri.path,
            '/missav-default/recomms/users/anonymous/items/',
          );
        }
        expect(metadata.requests, hasLength(1));
      }
    },
  );

  for (final changeSession in [true, false]) {
    test(
      'stale recommendations are discarded after ${changeSession ? 'session' : 'language'} changes',
      () async {
        final fixture = await File(
          'test/fixtures/missav/home_recommendations.html',
        ).readAsString();
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        final metadata = _Adapter((_) {
          started.complete();
          return response.future;
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = _Adapter((_) => _response(fixture)),
          metadataDio: Dio()..httpClientAdapter = metadata,
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final pending = client.loadRecommendations(count: 40);
        final rejected = expectLater(
          pending,
          throwsA(anyOf(isA<MissavException>(), isA<DioException>())),
        );
        await started.future;
        if (changeSession) {
          client.restoreNativeTransport();
        } else {
          client.setLocale('ja');
        }
        response.complete(
          _metadataResponse({'recommId': 'old-cursor', 'recomms': []}),
        );
        await rejected;
      },
    );
  }

  test(
    'enriches a catalog in one exact-ID batch without account headers',
    () async {
      _selectOriginAccountHost();
      final source = _Adapter(
        (_) => _response(
          _searchCatalogHtml(['alpha', 'beta', 'alpha-uncensored-leak']),
        ),
      );
      final metadata = _Adapter(
        (_) => _metadataResponse({
          'recomms': [
            {
              'id': 'beta',
              'values': {
                'actors': ['Male performer'],
                'actresses': null,
                'genres': [],
                'duration': 120,
                'type': 'heyzo',
              },
            },
            {
              'id': 'alpha',
              'values': {
                'actresses': [' Actress A ', 'Actress A'],
                'actors': ['Male performer'],
                'genres': ['Tag A', 'Tag B', 'Tag A'],
                'duration': 3723,
                'released_at': 1709337600,
                'has_chinese_subtitle': true,
                'markers': ['Studio A', ' Studio A ', null, 12],
                'labels': ['Label A'],
                'series': ['Series A'],
                'directors': ['Director A'],
              },
            },
            {
              'id': 'unrequested',
              'values': {
                'actresses': ['Wrong actress'],
                'genres': ['Wrong tag'],
              },
            },
          ],
        }),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage()..cookie = 'session=private',
      );
      addTearDown(client.dispose);
      final page = await client.browse('https://missav.ai/cn');

      expect(page.videos.map((video) => video.id), [
        'alpha',
        'beta',
        'alpha-uncensored-leak',
      ]);
      expect(page.videos.first.title, 'Video alpha');
      expect(page.videos.first.cover, 'https://media.example/alpha.jpg');
      expect(page.videos.first.actors.single.label, 'Actress A');
      expect(
        page.videos.first.actors.single.url,
        'https://missav.ai/cn/actresses/Actress%20A',
      );
      expect(page.videos.first.tags.map((tag) => tag.label), [
        'Tag A',
        'Tag B',
      ]);
      expect(page.videos.first.tags.map((tag) => Uri.parse(tag.url).path), [
        '/ja/genres/Tag%20A',
        '/ja/genres/Tag%20B',
      ]);
      expect(page.videos.first.durationSeconds, 3723);
      expect(page.videos.first.releaseDate, '2024-03-02');
      expect(page.videos.first.hasSubtitles, isTrue);
      expect(page.videos.first.makers, ['Studio A']);
      expect(page.videos.first.labels, ['Label A']);
      expect(page.videos.first.series, ['Series A']);
      expect(page.videos.first.directors, ['Director A']);
      expect(page.videos[1].actors, isEmpty);
      expect(page.videos[1].isUncensored, isTrue);
      expect(page.videos.last.actors, isEmpty);
      expect(page.videos.last.tags, isEmpty);
      expect(source.requests, hasLength(1));
      expect(metadata.requests, hasLength(1));
      final request = metadata.requests.single;
      expect(request.uri.host, 'client-rapi-missav.recombee.com');
      expect(
        request.uri.path,
        '/missav-default/recomms/users/anonymous/items/',
      );
      expect(request.data['returnProperties'], isTrue);
      expect(request.data['count'], 3);
      expect(
        request.data['filter'],
        '\'itemId\' in {"alpha","beta","alpha-uncensored-leak"}',
      );
      expect(
        request.uri.queryParameters['frontend_sign'],
        matches(RegExp(r'^[a-f0-9]{40}$')),
      );
      expect(_cookieHeader(request), isEmpty);
      expect(_headerValue(request, 'Authorization'), isNull);
      expect(_cookieHeader(source.requests.single), 'session=private');
      client.dispose();
      expect(source.closeCalls, 1);
      expect(metadata.closeCalls, 1);
    },
  );

  test('reports parsed covers before the complete metadata result', () async {
    final metadataStarted = Completer<void>();
    final metadataResponse = Completer<ResponseBody>();
    final parsed = Completer<VideoCatalogPage>();
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _response(_searchCatalogHtml(['alpha'])),
        ),
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          metadataStarted.complete();
          return metadataResponse.future;
        }),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    var finished = false;
    final loading = client
        .browse('https://missav.ai/cn', onParsed: parsed.complete)
        .then((page) {
          finished = true;
          return page;
        });
    final preview = await parsed.future;
    await metadataStarted.future;
    expect(preview.videos.single.cover, 'https://media.example/alpha.jpg');
    expect(preview.videos.single.actors, isEmpty);
    expect(finished, isFalse);

    metadataResponse.complete(
      _metadataResponse({
        'recomms': [
          {
            'id': 'alpha',
            'values': {
              'actresses': ['Actress A'],
              'duration': 120,
            },
          },
        ],
      }),
    );
    final page = await loading;
    expect(page.videos.single.actors.single.label, 'Actress A');
    expect(page.videos.single.durationSeconds, 120);
  });

  for (final cancelMetadata in [false, true]) {
    test(
      'cancels a directory during ${cancelMetadata ? 'metadata' : 'HTML'} loading',
      () async {
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        final sourcePage = _response(_searchCatalogHtml(['alpha']));
        final client = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              if (cancelMetadata) return sourcePage;
              started.complete();
              return response.future;
            }),
          metadataDio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              started.complete();
              return response.future;
            }),
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final cancelToken = CancelToken();
        var parsedCount = 0;
        final loading = client.browse(
          'https://missav.ai/cn',
          cancelToken: cancelToken,
          onParsed: (_) => parsedCount++,
        );
        final cancelled = expectLater(
          loading,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await started.future;
        cancelToken.cancel('A newer directory was selected.');
        response.complete(
          cancelMetadata ? _metadataResponse({'recomms': []}) : sourcePage,
        );
        await cancelled;
        expect(parsedCount, cancelMetadata ? 1 : 0);
      },
    );
  }

  test(
    'metadata failure preserves source cards and empty catalogs make no metadata call',
    () async {
      final metadata = _Adapter(
        (_) => _metadataResponse({'error': 'unavailable'}, statusCode: 503),
      );
      final source = _Adapter(
        (options) => _response(
          options.uri.path.endsWith('/empty')
              ? '<main></main>'
              : _searchCatalogHtml(['alpha']),
        ),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final page = await client.browse('https://missav.ai/cn');
      expect(page.videos.single.title, 'Video alpha');
      expect(page.videos.single.actors, isEmpty);
      expect(metadata.requests, hasLength(1));
      final empty = await client.browse('https://missav.ai/cn/empty');
      expect(empty.videos, isEmpty);
      expect(metadata.requests, hasLength(1));
    },
  );

  test(
    'Recombee search loads pages without contacting a content host',
    () async {
      final source = _Adapter(
        (_) => _response('', statusCode: HttpStatus.serviceUnavailable),
      );
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/next/')) {
          return _metadataResponse({
            'recommId': 'next-cursor',
            'recomms': [
              {
                'id': 'next-video',
                'values': {'dm': 45, 'title_en': 'Next sample'},
              },
            ],
          });
        }
        if (request.uri.path.contains('/search/')) {
          return _metadataResponse({
            'recommId': 'search-cursor',
            'recomms': [
              {
                'id': 'ssis-001',
                'values': {'dm': 44, 'title_en': 'Mirror sample'},
              },
            ],
          });
        }
        return _metadataResponse({'recomms': []});
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.search('ssis-001');

      expect(page.videos.single.id, 'ssis-001');
      expect(page.videos.single.pageUrl, 'https://missav.ai/dm44/cn/ssis-001');
      expect(page.nextUrl, 'https://missav.ai/cn/search/ssis-001?page=2');
      final searchRequest = metadata.requests.firstWhere(
        (request) => request.uri.path.contains('/search/'),
      );
      expect(
        searchRequest.uri.path,
        '/missav-default/search/users/anonymous/items/',
      );
      expect((searchRequest.data as Map)['searchQuery'], 'ssis-001');

      final next = await client.browse(page.nextUrl!);

      expect(next.videos.single.id, 'next-video');
      expect(next.currentPage, 2);
      expect(next.previousUrl, 'https://missav.ai/cn/search/ssis-001?page=1');
      final nextRequest = metadata.requests.firstWhere(
        (request) => request.uri.path.contains('/next/'),
      );
      expect(
        nextRequest.uri.path,
        '/missav-default/recomms/next/items/search-cursor',
      );
      expect(source.requests, isEmpty);
    },
  );

  test(
    'Recombee search keeps empty results without reading mirror cards',
    () async {
      final source = _Adapter(
        (_) => _response(_searchCatalogHtml(['unrelated'])),
      );
      final metadata = _Adapter(
        (_) => _metadataResponse({'recommId': 'empty-cursor', 'recomms': []}),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.search('no matches');

      expect(page.videos, isEmpty);
      expect(page.nextUrl, isNull);
      expect(source.requests, isEmpty);
    },
  );

  for (final invalidResponse in [
    <String, Object?>{'error': 'unavailable'},
    <String, Object?>{
      'recommId': 'invalid-cursor',
      'recomms': [
        {'id': 'missing-values'},
      ],
    },
  ]) {
    test(
      'Recombee search falls back after an invalid response $invalidResponse',
      () async {
        final source = _Adapter(
          (_) => _response(_searchCatalogHtml(['mirror-result'])),
        );
        final metadata = _Adapter(
          (request) => _metadataResponse(
            request.uri.path.contains('/search/')
                ? invalidResponse
                : {'recomms': []},
          ),
        );
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = source,
          metadataDio: Dio()..httpClientAdapter = metadata,
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);

        final page = await client.search('needle');

        expect(page.videos.single.id, 'mirror-result');
        expect(source.requests, hasLength(1));
      },
    );
  }

  test(
    'Recombee search uses mirror pagination after a failed search',
    () async {
      final requests = <String>[];
      final first = missavMirrors.first.baseUrl;
      final source = _Adapter((request) {
        final page = request.uri.queryParameters['page'] ?? '1';
        requests.add('mirror page $page');
        return _response(
          _searchCatalogHtml([
                'mirror-$page',
              ], nextUrl: page == '1' ? '/cn/search/needle?page=2' : null) +
              (page == '2'
                  ? '<a href="/cn/search/needle" rel="prev">Previous</a>'
                  : ''),
        );
      });
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/search/')) {
          requests.add('search failed');
          return _metadataResponse(
            {},
            statusCode: HttpStatus.serviceUnavailable,
          );
        }
        return _metadataResponse({'recomms': []});
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
        contentHosts: [first],
      );
      addTearDown(client.dispose);

      final page = await client.search('needle');
      final next = await client.browse(page.nextUrl!);
      final previous = await client.browse(next.previousUrl!);

      expect(page.videos.single.id, 'mirror-1');
      expect(page.nextUrl, '$first/cn/search/needle?page=2');
      expect(next.videos.single.id, 'mirror-2');
      expect(next.currentPage, 2);
      expect(previous.videos.single.id, 'mirror-1');
      expect(requests, [
        'search failed',
        'mirror page 1',
        'mirror page 2',
        'mirror page 1',
      ]);
    },
  );

  test('Recombee search cancellation stops before a mirror request', () async {
    final started = Completer<void>();
    final response = Completer<ResponseBody>();
    final source = _Adapter((_) => _response('<main></main>'));
    final metadata = _Adapter((_) {
      started.complete();
      return response.future;
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()..httpClientAdapter = metadata,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    final cancelToken = CancelToken();
    final request = client.browse(
      'https://missav.ai/cn/search/needle',
      cancelToken: cancelToken,
      onParsed: (_) => fail('A cancelled search must not publish results.'),
    );
    final cancelled = expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;

    cancelToken.cancel();
    response.complete(
      _metadataResponse({}, statusCode: HttpStatus.serviceUnavailable),
    );
    await cancelled;

    expect(metadata.requests.single.cancelToken, same(cancelToken));
    expect(source.requests, isEmpty);
  });

  test(
    'Recombee search shares concurrent requests for the same next page',
    () async {
      var nextCalls = 0;
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/search/')) {
          return _metadataResponse({
            'recommId': 'first-cursor',
            'recomms': [
              {'id': 'first', 'values': <String, Object?>{}},
            ],
          });
        }
        if (request.uri.path.contains('/next/')) {
          nextCalls++;
          return _metadataResponse({
            'recommId': 'cursor-$nextCalls',
            'recomms': [
              {'id': 'next-$nextCalls', 'values': <String, Object?>{}},
            ],
          });
        }
        return _metadataResponse({'recomms': []});
      });
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((_) => _response('<main></main>')),
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final first = await client.search('needle');
      final pages = await Future.wait([
        client.browse(first.nextUrl!),
        client.browse(first.nextUrl!),
      ]);

      expect(nextCalls, 1);
      expect(pages.map((page) => page.videos.single.id), ['next-1', 'next-1']);
    },
  );

  testWidgets('cancelling one search waiter preserves its shared next page', (
    tester,
  ) async {
    final continuation = Completer<ResponseBody>();
    final source = _Adapter((_) => _response('<main></main>'));
    final metadata = _Adapter((request) {
      if (request.uri.path.contains('/next/')) return continuation.future;
      if (request.uri.path.contains('/search/')) {
        return _metadataResponse({
          'recommId': 'first-cursor',
          'recomms': [
            {'id': 'first', 'values': <String, Object?>{}},
          ],
        });
      }
      return _metadataResponse({'recomms': []});
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()..httpClientAdapter = metadata,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final search = client.search('needle');
    await tester.pump(Duration.zero);
    final first = await search;
    final cancelToken = CancelToken();
    final cancelled = expectLater(
      client.browse(first.nextUrl!, cancelToken: cancelToken),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await tester.pump(Duration.zero);
    final live = client.browse(first.nextUrl!);
    await tester.pump(Duration.zero);

    cancelToken.cancel();
    await tester.pump(Duration.zero);
    await cancelled;
    continuation.complete(
      _metadataResponse({
        'recommId': 'next-cursor',
        'recomms': [
          {'id': 'second', 'values': <String, Object?>{}},
        ],
      }),
    );
    await tester.pump(Duration.zero);

    expect((await live).videos.map((video) => video.id), ['second']);
    expect(
      metadata.requests.where((request) => request.uri.path.contains('/next/')),
      hasLength(1),
    );
    expect(source.requests, isEmpty);
  });

  test('Recombee search does not reuse a cancelled continuation', () async {
    final started = Completer<void>();
    final response = Completer<ResponseBody>();
    var nextCalls = 0;
    final source = _Adapter((_) => _response(_searchCatalogHtml(['mirror-2'])));
    final metadata = _Adapter((request) {
      if (request.uri.path.contains('/search/')) {
        return _metadataResponse({
          'recommId': 'first-cursor',
          'recomms': [
            {'id': 'first', 'values': <String, Object?>{}},
          ],
        });
      }
      if (request.uri.path.contains('/next/')) {
        nextCalls++;
        started.complete();
        return response.future;
      }
      return _metadataResponse({'recomms': []});
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()..httpClientAdapter = metadata,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    final first = await client.search('needle');
    final cancelToken = CancelToken();
    final pending = client.browse(first.nextUrl!, cancelToken: cancelToken);
    final cancelled = expectLater(
      pending,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;

    cancelToken.cancel();
    response.complete(_metadataResponse({'recommId': 'unused', 'recomms': []}));
    await cancelled;
    expect(source.requests, isEmpty);
    expect(
      metadata.requests
          .singleWhere((request) => request.uri.path.contains('/next/'))
          .cancelToken!
          .isCancelled,
      isTrue,
    );

    final retry = await client.browse(first.nextUrl!);
    expect(retry.videos.single.id, 'mirror-2');
    expect(nextCalls, 1);
  });

  test('Recombee search revisits pages without advancing the cursor', () async {
    final source = _Adapter(
      (_) => _response('', statusCode: HttpStatus.serviceUnavailable),
    );
    var nextCalls = 0;
    final metadata = _Adapter((request) {
      if (!request.uri.path.contains('/search/') &&
          !request.uri.path.contains('/next/')) {
        return _metadataResponse({'recomms': []});
      }
      final pageNumber = request.uri.path.contains('/search/')
          ? 1
          : ++nextCalls + 1;
      return _metadataResponse({
        'recommId': 'cursor-$pageNumber',
        'recomms': [
          {'id': 'page-$pageNumber', 'values': <String, Object?>{}},
        ],
      });
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()..httpClientAdapter = metadata,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final first = await client.search('needle');
    final second = await client.browse(first.nextUrl!);
    final third = await client.browse(second.nextUrl!);
    final previous = await client.browse(third.previousUrl!);
    final backToFirst = await client.browse(previous.previousUrl!);
    final revisited = await client.browse(backToFirst.nextUrl!);

    expect(previous.videos.single.id, 'page-2');
    expect(backToFirst.videos.single.id, 'page-1');
    expect(revisited.videos.single.id, 'page-2');
    expect(nextCalls, 2);
    expect(source.requests, isEmpty);
  });

  test(
    'Recombee search keeps mirror continuation after a failed next page',
    () async {
      final requests = <String>[];
      final source = _Adapter((request) {
        final page = request.uri.queryParameters['page'];
        requests.add('mirror page $page');
        return _response(
          _searchCatalogHtml([
            'mirror-$page',
          ], nextUrl: page == '2' ? '/cn/search/needle?page=3' : null),
        );
      });
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/search/')) {
          return _metadataResponse({
            'recommId': 'first-cursor',
            'recomms': [
              {'id': 'first', 'values': <String, Object?>{}},
            ],
          });
        }
        if (request.uri.path.contains('/next/')) {
          requests.add('next failed');
          return _metadataResponse(
            {},
            statusCode: HttpStatus.serviceUnavailable,
          );
        }
        return _metadataResponse({'recomms': []});
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final first = await client.search('needle');
      final second = await client.browse(first.nextUrl!);
      final third = await client.browse(second.nextUrl!);

      expect(third.videos.single.id, 'mirror-3');
      expect(requests, ['next failed', 'mirror page 2', 'mirror page 3']);
    },
  );

  for (final changeSession in [false, true]) {
    test(
      'Recombee search rejects a stale ${changeSession ? 'session' : 'language'}',
      () async {
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        final source = _Adapter((_) => _response('<main></main>'));
        final metadata = _Adapter((_) {
          started.complete();
          return response.future;
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = source,
          metadataDio: Dio()..httpClientAdapter = metadata,
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final pending = client.search('needle');
        final stale = expectLater(pending, throwsA(isA<MissavException>()));
        await started.future;

        if (changeSession) {
          await client.logout();
        } else {
          client.setLocale('en');
        }
        response.complete(
          _metadataResponse({}, statusCode: HttpStatus.serviceUnavailable),
        );
        await stale;

        expect(source.requests, isEmpty);
      },
    );
  }

  test(
    'Recombee search accepts an empty last page without mirror fallback',
    () async {
      final source = _Adapter(
        (_) => _response(_searchCatalogHtml(['unrelated'])),
      );
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/search/')) {
          return _metadataResponse({
            'recommId': 'first-cursor',
            'recomms': [
              {'id': 'first', 'values': <String, Object?>{}},
            ],
          });
        }
        return _metadataResponse({'recommId': 'empty-cursor', 'recomms': []});
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final first = await client.search('needle');
      final last = await client.browse(first.nextUrl!);

      expect(last.videos, isEmpty);
      expect(last.currentPage, 2);
      expect(last.nextUrl, isNull);
      expect(last.previousUrl, 'https://missav.ai/cn/search/needle?page=1');
      expect(source.requests, isEmpty);
    },
  );

  test(
    'Recombee search ignores a late cursor from a replaced search',
    () async {
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final source = _Adapter((_) => _response('<main></main>'));
      var firstCalls = 0;
      String? usedCursor;
      final metadata = _Adapter((request) {
        if (request.uri.path.contains('/search/')) {
          if (++firstCalls == 1) {
            started.complete();
            return response.future;
          }
          return _metadataResponse({
            'recommId': 'current-cursor',
            'recomms': [
              {'id': 'current', 'values': <String, Object?>{}},
            ],
          });
        }
        if (request.uri.path.contains('/next/')) {
          usedCursor = request.uri.pathSegments.last;
          return _metadataResponse({'recommId': 'last-cursor', 'recomms': []});
        }
        return _metadataResponse({'recomms': []});
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final oldSearch = client.search('needle');
      final stale = expectLater(oldSearch, throwsA(isA<MissavException>()));
      await started.future;
      final current = await client.search('needle');

      response.complete(
        _metadataResponse({
          'recommId': 'stale-cursor',
          'recomms': [
            {'id': 'stale', 'values': <String, Object?>{}},
          ],
        }),
      );
      await stale;
      await client.browse(current.nextUrl!);

      expect(usedCursor, 'current-cursor');
      expect(source.requests, isEmpty);
    },
  );

  test(
    'account changes cancel pending metadata before publishing a catalog',
    () async {
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final metadata = _Adapter((_) {
        started.complete();
        return response.future;
      });
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => _response(_searchCatalogHtml(['alpha'])),
          ),
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final browsing = client.browse('https://missav.ai/cn');
      final stale = expectLater(browsing, throwsA(isA<MissavException>()));
      await started.future;
      await client.logout();
      expect(metadata.requests.single.cancelToken!.isCancelled, isTrue);
      response.complete(_metadataResponse({'recomms': []}));
      await stale;
    },
  );

  test(
    'session changes cancel remaining browses sharing a request token',
    () async {
      final slowStarted = Completer<void>();
      final slowResponse = Completer<ResponseBody>();
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((request) {
            if (request.uri.path.endsWith('/slow')) {
              slowStarted.complete();
              return slowResponse.future;
            }
            return _response('<main></main>');
          }),
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final cancelToken = CancelToken();
      final slow = client.browse(
        'https://missav.ai/cn/slow',
        cancelToken: cancelToken,
      );
      final rejected = expectLater(slow, throwsA(isA<MissavException>()));
      await slowStarted.future;
      await client.browse(
        'https://missav.ai/cn/fast',
        cancelToken: cancelToken,
      );
      expect(cancelToken.isCancelled, isFalse);

      await client.logout();
      expect(cancelToken.isCancelled, isTrue);
      slowResponse.complete(_response('<main></main>'));
      await rejected;
    },
  );

  test(
    'language changes discard both catalog and detail metadata responses',
    () async {
      for (final details in [false, true]) {
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        final client = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter(
              (_) => _response(
                details
                    ? '<main><h1>Alpha</h1></main>'
                    : _searchCatalogHtml(['alpha']),
              ),
            ),
          metadataDio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              started.complete();
              return response.future;
            }),
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final request = details
            ? client.details(
                const VideoItem(
                  id: 'alpha',
                  title: 'Alpha',
                  pageUrl: 'https://missav.ai/cn/alpha',
                ),
              )
            : client.browse('https://missav.ai/cn');
        final stale = expectLater(request, throwsA(isA<MissavException>()));
        await started.future;
        client.setLocale('en');
        response.complete(_metadataResponse({'recomms': []}));
        await stale;
      }
    },
  );

  test(
    'publishes playable details before account and metadata requests finish',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final account = Completer<ResponseBody>();
      final metadata = Completer<ResponseBody>();
      final accountStarted = Completer<void>();
      final metadataStarted = Completer<void>();
      final ready = Completer<VideoDetails>();
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((request) {
            if (request.uri.path.contains('/api/')) {
              accountStarted.complete();
              return account.future;
            }
            return _response(fixture);
          }),
        metadataDio: Dio()
          ..httpClientAdapter = _Adapter((_) {
            metadataStarted.complete();
            return metadata.future;
          }),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      var finished = false;
      final loading = client
          .details(
            const VideoItem(
              id: 'open-sample-001',
              title: 'Sample',
              pageUrl: 'https://missav.ai/cn/open-sample-001',
            ),
            onReady: ready.complete,
          )
          .then((value) {
            finished = true;
            return value;
          });
      final initial = await ready.future;
      expect(initial.streams, hasLength(2));
      expect(initial.isFavorite, isNull);
      await Future.wait([accountStarted.future, metadataStarted.future]);
      expect(finished, isFalse);
      account.complete(
        _metadataResponse({
          'saved': true,
          'user': {'name': 'Saved account'},
        }),
      );
      metadata.complete(
        _metadataResponse({
          'recomms': [
            {
              'id': 'open-sample-001',
              'values': {
                'genres': ['API tag'],
              },
            },
          ],
        }),
      );
      final completed = await loading;
      expect(client.isLoggedIn, isTrue);
      expect(completed.isFavorite, isTrue);
      expect(completed.video.tags.any((tag) => tag.label == 'API tag'), isTrue);
      expect(identical(completed.streams, initial.streams), isTrue);
    },
  );

  test(
    'access checks validate the document without catalog metadata',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final source = _Adapter((_) => _response(fixture));
      final metadata = _Adapter(
        (_) => throw StateError('Unexpected metadata request'),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await client.checkBrowserAccess();
      expect(source.requests, hasLength(1));
      expect(metadata.requests, isEmpty);
    },
  );

  test('account checks use the login page account as a fallback', () async {
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _response('<html><body x-data="{user: null}"></body></html>'),
        ),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.checkBrowserAccess(
      browserUser: {'username': 'Login page viewer'},
    );

    expect(client.isLoggedIn, isTrue);
    expect(client.accountName, 'Login page viewer');
  });

  test('account checks prefer the current homepage account', () async {
    final pages = [
      '''
<body x-data="{user: null}">
  <header x-data='{"user":{"username":"Homepage viewer"}}'></header>
</body>
''',
      '<html><body x-data="{user: null}"></body></html>',
    ];
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((_) => _response(pages.removeAt(0))),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.checkBrowserAccess(
      browserUser: {'username': 'Login page viewer'},
    );

    expect(client.isLoggedIn, isTrue);
    expect(client.accountName, 'Homepage viewer');

    await client.checkBrowserAccess();

    expect(client.isLoggedIn, isTrue);
    expect(client.accountName, 'Homepage viewer');
  });

  test('account checks accept a user object without a display name', () async {
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _response('<body x-data="{user: {id: 42}}"></body>'),
        ),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.checkBrowserAccess();

    expect(client.isLoggedIn, isTrue);
    expect(client.accountName, isNull);
  });

  test(
    'account checks reject fallback after HTTP and challenge failures',
    () async {
      for (final failure in [
        (
          status: HttpStatus.unauthorized,
          body: '<html><body>Sign in</body></html>',
          expected: isA<MissavAuthenticationException>(),
        ),
        (
          status: HttpStatus.forbidden,
          body: '<title>Attention Required! | Cloudflare</title>',
          expected: isA<MissavVerificationRequiredException>(),
        ),
      ]) {
        final client = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter(
              (_) => _response(failure.body, statusCode: failure.status),
            ),
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);

        await expectLater(
          client.checkBrowserAccess(
            browserUser: {'username': 'Login page viewer'},
          ),
          throwsA(failure.expected),
        );
        expect(client.isLoggedIn, isFalse);
        expect(client.accountName, isNull);
      }
    },
  );

  test(
    'account checks prefer native access before restoring a saved browser session',
    () async {
      final native = _Adapter(
        (_) => _response(
          '<html><body x-data="{user: {name: \'Native viewer\'}}"></body></html>',
        ),
      );
      final browser = _Adapter(
        (_) => throw StateError('Native access should be used first.'),
      );
      final storage = _storedBrowserSession();
      var restoreCalls = 0;
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = native,
        metadataDio: _emptyMetadataDio(),
        secureStorage: storage,
        restoreSavedSession: (client, expectedGeneration) async {
          restoreCalls++;
          await client.importVerifiedSession(
            cookieHeader: 'session=saved',
            userAgent: 'Saved Browser UA',
            expectedGeneration: expectedGeneration,
          );
          client.useVerifiedBrowserTransport(browser);
        },
      );
      addTearDown(client.dispose);

      await client.checkBrowserAccess();

      expect(restoreCalls, 0);
      final contentRequests = native.requests
          .where((request) => !_isMirrorProbe(request))
          .toList();
      expect(contentRequests, hasLength(1));
      expect(browser.requests, isEmpty);
      final contentRequest = contentRequests.single;
      expect(_cookieHeader(contentRequest), 'session=saved');
      expect(_headerValue(contentRequest, 'User-Agent'), 'Saved Browser UA');
      expect(contentRequest.uri.path, '/cn');
      expect(client.accountName, 'Native viewer');
      expect(client.isLoggedIn, isTrue);
    },
  );

  test(
    'account request failure still publishes enriched playable details',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final updates = <VideoDetails>[];
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (request) => request.uri.path.contains('/api/')
                ? _metadataResponse({}, statusCode: 503)
                : _response(fixture),
          ),
        metadataDio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => _metadataResponse({
              'recomms': [
                {
                  'id': 'open-sample-001',
                  'values': {
                    'genres': ['API tag'],
                  },
                },
              ],
            }),
          ),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
          onReady: updates.add,
        ),
        throwsA(isA<MissavException>()),
      );
      expect(updates, hasLength(2));
      expect(
        updates.last.video.tags.any((tag) => tag.label == 'API tag'),
        isTrue,
      );
      expect(updates.last.isFavorite, isNull);
      expect(identical(updates.first.streams, updates.last.streams), isTrue);
    },
  );

  test('account verification does not fail playable details', () async {
    final fixture = await File(
      'test/fixtures/missav/detail.html',
    ).readAsString();
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (request) => request.uri.path.contains('/api/')
              ? _response(
                  '<title>Just a moment...</title>',
                  statusCode: HttpStatus.forbidden,
                )
              : _response(fixture),
        ),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final details = await client.details(
      const VideoItem(
        id: 'open-sample-001',
        title: 'Sample',
        pageUrl: 'https://missav.ai/cn/open-sample-001',
      ),
    );

    expect(details.streams, isNotEmpty);
    expect(details.isFavorite, isNull);
  });

  for (final changeSession in [false, true]) {
    test(
      'details without account state reject stale ${changeSession ? 'sessions' : 'languages'}',
      () async {
        final fixture = await File(
          'test/fixtures/missav/detail.html',
        ).readAsString();
        final metadataStarted = Completer<void>();
        final metadata = Completer<ResponseBody>();
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = _Adapter((_) => _response(fixture)),
          metadataDio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              metadataStarted.complete();
              return metadata.future;
            }),
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final loading = client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
          includeAccountState: false,
        );
        final stale = expectLater(loading, throwsA(isA<MissavException>()));
        await metadataStarted.future;
        if (changeSession) {
          await client.logout();
        } else {
          client.setLocale('en');
        }
        metadata.complete(_metadataResponse({'recomms': []}));
        await stale;
      },
    );
  }

  test('details without account state propagate source cancellation', () async {
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (request) => throw DioException(
            requestOptions: request,
            type: DioExceptionType.cancel,
          ),
        ),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    await expectLater(
      client.details(
        const VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/sample',
        ),
        includeAccountState: false,
      ),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
  });

  test('supplement retry reuses the document and playback streams', () async {
    final fixture = await File(
      'test/fixtures/missav/detail.html',
    ).readAsString();
    var accountReads = 0;
    var metadataReads = 0;
    final source = _Adapter((request) {
      if (!request.uri.path.contains('/api/')) return _response(fixture);
      accountReads++;
      return _metadataResponse({
        'saved': true,
        'user': {'name': 'Saved account'},
      }, statusCode: accountReads == 1 ? 503 : 200);
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          metadataReads++;
          return _metadataResponse({
            'recomms': [
              {
                'id': 'open-sample-001',
                'values': {
                  'genres': ['API tag $metadataReads'],
                },
              },
            ],
          });
        }),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    final updates = <VideoDetails>[];
    await expectLater(
      client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/open-sample-001',
        ),
        onReady: updates.add,
      ),
      throwsA(isA<MissavException>()),
    );
    final initial = updates.last;
    final updated = await client.supplementDetails(initial);
    expect(
      source.requests.where((request) => !request.uri.path.contains('/api/')),
      hasLength(1),
    );
    expect(accountReads, 2);
    expect(metadataReads, 2);
    expect(identical(updated.streams, initial.streams), isTrue);
    expect(updated.description, initial.description);
    expect(updated.metadata, initial.metadata);
    expect(updated.video.tags.any((tag) => tag.label == 'API tag 2'), isTrue);
    expect(updated.isFavorite, isTrue);
    expect(client.isLoggedIn, isTrue);
  });

  test('account changes discard an in-flight supplement retry', () async {
    final accountStarted = Completer<void>();
    final metadataStarted = Completer<void>();
    final account = Completer<ResponseBody>();
    final metadata = Completer<ResponseBody>();
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          accountStarted.complete();
          return account.future;
        }),
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          metadataStarted.complete();
          return metadata.future;
        }),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    final updates = <VideoDetails>[];
    final loading = client.supplementDetails(
      const VideoDetails(
        video: VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/sample',
        ),
        sourceId: 'source-id',
      ),
      onReady: updates.add,
    );
    final stale = expectLater(loading, throwsA(isA<MissavException>()));
    await Future.wait([accountStarted.future, metadataStarted.future]);
    await client.logout();
    account.complete(
      _metadataResponse({
        'saved': true,
        'user': {'name': 'Stale account'},
      }),
    );
    metadata.complete(_metadataResponse({'recomms': []}));
    await stale;
    expect(updates, isEmpty);
    expect(client.isLoggedIn, isFalse);
    expect(client.accountName, isNull);
  });

  test(
    'current video and related metadata share one batch and stay separate',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final metadata = _Adapter(
        (_) => _metadataResponse({
          'recomms': [
            {
              'id': 'open-sample-001',
              'values': {
                'actresses': ['Sample actor'],
                'genres': ['Sample genre', 'API tag'],
                'markers': ['API studio'],
              },
            },
            {
              'id': 'open-related-002',
              'values': {
                'actresses': ['Related actress'],
                'genres': ['Related tag'],
                'markers': ['Related studio'],
              },
            },
          ],
        }),
      );
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (options) => options.uri.path.contains('/api/')
                ? _response('{"saved":false}')
                : _response(fixture),
          ),
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Main',
          pageUrl: 'https://missav.ai/cn/open-sample-001',
          series: ['Cached series'],
        ),
      );
      expect(details.video.actors.single.label, 'Sample actor');
      expect(
        details.video.actors.single.url,
        'https://missav.ai/dm288/ja/actresses/sample-actor',
      );
      expect(
        details.video.tags.where((tag) => tag.label == 'Sample genre'),
        hasLength(1),
      );
      expect(
        details.video.tags.firstWhere((tag) => tag.label == 'Sample genre').url,
        'https://missav.ai/dm349/ja/genres/sample-genre',
      );
      expect(details.video.tags.any((tag) => tag.label == 'API tag'), isTrue);
      expect(details.related.single.actors.single.label, 'Related actress');
      expect(details.related.single.tags.single.label, 'Related tag');
      expect(details.video.cardMakers, ['API studio', 'Sample maker']);
      expect(details.video.cardLabels, ['Sample label']);
      expect(details.video.cardDirectors, ['Sample director']);
      expect(details.video.series, ['Cached series']);
      expect(details.related.single.makers, ['Related studio']);
      expect(metadata.requests, hasLength(1));
    },
  );

  test(
    'live Recombee catalog batch supplies actresses and genres',
    () async {
      final source = _Adapter(
        (_) =>
            _response(_searchCatalogHtml(['miab-596', 'waaa-578', 'miab-636'])),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final page = await client.browse('https://missav.ai/cn');
      expect(page.videos.map((video) => video.id), [
        'miab-596',
        'waaa-578',
        'miab-636',
      ]);
      for (final video in page.videos) {
        expect(video.actors, isNotEmpty, reason: video.id);
        expect(video.tags, isNotEmpty, reason: video.id);
        for (final tag in video.tags) {
          expect(Uri.parse(tag.url).pathSegments, ['ja', 'genres', tag.label]);
        }
        expect(video.durationSeconds, greaterThan(0));
        expect(video.releaseDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(video.makers, isNotEmpty, reason: video.id);
        expect(video.labels, isNotEmpty, reason: video.id);
        expect(video.directors, isNotEmpty, reason: video.id);
      }
      expect(page.videos[1].series, isNotEmpty);
      expect(source.requests, hasLength(1));
    },
    skip: !const bool.fromEnvironment('KIKOFLU_LIVE_MISSAV_METADATA'),
  );

  test('category navigation does not replace the home route', () async {
    final adapter = _Adapter(
      (_) => _response('''
<nav><a href="/dm278/cn/chinese-subtitle">Category</a></nav>
<main></main>
'''),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.browse('https://missav.ai/cn');

    expect(client.homeUrl, 'https://missav.ai/cn');
  });

  test(
    'reads metadata only from its source card without detail requests',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<main>
  <div class="space-y-2">
    <div class="relative aspect-w-16 aspect-h-9">
      <a href="/cn/sample"><img alt="Sample" src="/cover.jpg"></a>
      <span class="bottom-1 right-1">1:23</span>
      <span class="bottom-1 left-1"><span title="中文字幕"></span><span aria-label="无码"></span></span>
    </div>
    <time datetime="2024-03-02">2024-03-02</time>
    <a href="/cn/actresses/sample">Sample actor</a>
    <a href="/cn/genres/drama">Drama</a>
  </div>
  <div class="space-y-2">
    <div class="relative aspect-w-16 aspect-h-9">
      <a href="/cn/second"><img alt="Second" src="/second.jpg"></a>
    </div>
  </div>
</main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.browse('https://missav.ai/cn');
      final first = page.videos.first;
      expect(first.releaseDate, '2024-03-02');
      expect(first.actors.single.label, 'Sample actor');
      expect(first.tags.single.label, 'Drama');
      expect(first.hasSubtitles, isTrue);
      expect(first.isUncensored, isTrue);
      final second = page.videos.last;
      expect(second.releaseDate, isNull);
      expect(second.actors, isEmpty);
      expect(second.tags, isEmpty);
      expect(second.hasSubtitles, isFalse);
      expect(second.isUncensored, isFalse);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'keeps pagination, languages and excluded entries out of directories',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<nav>
  <a href="/cn">Home</a>
  <a href="/cn/actresses">Actors</a>
  <a href="/cn/genres">Categories</a>
  <a href="/cn/vip">升级 VIP</a>
  <a href="/cn/actresses/ranking">女优排行 NOV 2026</a>
  <a href="/">繁體中文</a>
  <a href="/en" hreflang="en">English</a>
  <a href="/ja" x-bind:href="localizedUrl('ja')">日本語</a>
</nav>
<nav aria-label="Pagination">
  <a href="/cn/new?page=1">1</a>
  <a href="/cn/new?page=2" rel="next">Next</a>
  <a href="/cn/new?page=80">80</a>
</nav>
<main>
<a href="/cn/new?page=2">2</a>
<a href="/cn/vip">Upgrade VIP</a>
<a href="/cn/actresses/ranking">Ranking</a>
<a href="/cn/new" hreflang="zh-CN">简体中文</a>
<a href="/cn/genres/sample">Sample category</a>
</main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.browse('https://missav.ai/cn/new');

      expect(page.navigation.map((link) => link.label), [
        'Home',
        'Actors',
        'Categories',
      ]);
      expect(page.links.map((link) => link.label), ['Sample category']);
      expect(page.nextUrl, 'https://missav.ai/cn/new?page=2');
      expect(page.currentPage, 1);
      expect(page.jumpMaxPage, 80);
      expect(page.pageUrl(37), 'https://missav.ai/cn/new?page=37');
    },
  );

  test('source service links stay out of navigation and directories', () async {
    const serviceLinks = '''
<a href="/cn/ads">广告查询</a>
<a href="/dm123/ja/contact?from=footer">お問い合わせ</a>
<a href="/terms">使用條款</a>
<a href="/en/upload/">Upload</a>
''';
    const contentLinks = '''
<a href="/cn/new">最近更新</a>
<a href="/cn/release">新作上市</a>
<a href="/cn/chinese-subtitle">中文字幕</a>
<a href="/cn/weekly-hot">本周热门</a>
<a href="/cn/actresses">演员</a>
<a href="/cn/genres">分类</a>
<a href="/cn/makers">厂商</a>
<a href="/cn/series/sample">专题</a>
<a href="/cn/genres/contact">Contact category</a>
''';
    final adapter = _Adapter(
      (_) => _response(
        '<nav>$serviceLinks$contentLinks</nav><main>$serviceLinks$contentLinks</main>',
      ),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/cn');

    const labels = [
      '最近更新',
      '新作上市',
      '中文字幕',
      '本周热门',
      '演员',
      '分类',
      '厂商',
      '专题',
      'Contact category',
    ];
    expect(page.navigation.map((link) => link.label), labels);
    expect(page.links.map((link) => link.label), labels);
  });

  for (final entry in {
    'zh': 'cn',
    'zh-Hant': '',
    'zh-TW': '',
    'en': 'en',
    'ja': 'ja',
  }.entries) {
    test(
      'follows app locale ${entry.key} across old-locale routes and search',
      () async {
        final adapter = _Adapter((_) => _response('<main></main>'));
        final client = MissavClient(
          metadataDio: _emptyMetadataDio(),
          dio: Dio()..httpClientAdapter = adapter,
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        client.setLocale(entry.key);
        expect(client.setLocale(entry.key), isFalse);
        final prefix = entry.value.isEmpty ? '' : '/${entry.value}';
        expect(
          client.homeUrl,
          'https://missav.ai${prefix.isEmpty ? '/' : prefix}',
        );

        await client.browse('https://missav.ai/dm123/cn/new?page=4');
        expect(adapter.requests.single.uri.path, '/dm123$prefix/new');
        expect(adapter.requests.single.uri.queryParameters['page'], '4');
        await client.search('sample query');
        expect(adapter.requests.last.uri.path, '$prefix/search/sample%20query');
        expect(adapter.requests.last.uri.pathSegments.last, 'sample query');
        await client.browse('https://missav.ai/dm123/ja/genres?page=2');
        expect(adapter.requests.last.uri.path, '/dm123$prefix/genres');
        expect(adapter.requests.last.uri.queryParameters['page'], '2');
        expect(
          client.collectionUrl('favorites'),
          'https://missav.ai$prefix/saved',
        );
        expect(
          client.collectionUrl('actorFavorites'),
          'https://missav.ai$prefix/saved/actresses',
        );
        expect(
          client.collectionUrl('playlists'),
          'https://missav.ai$prefix/playlists',
        );
        expect(
          client.collectionUrl('history'),
          'https://missav.ai$prefix/history',
        );
      },
    );
  }

  for (final language in ['zh', 'zh-Hant', 'en', 'ja']) {
    test('genre routes keep their source language under $language', () async {
      final adapter = _Adapter(
        (_) => _response('''
<main><a href="?page=2&amp;sort=published_at" rel="next">Next</a></main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      )..setLocale(language);
      addTearDown(client.dispose);

      for (final path in [
        '/ja/genres/フェラ',
        '/dm1303/ja/genres/フェラ',
        '/dm1303/cn/genres/口交',
        '/genres/口交',
        '/en/genres/Oral Sex',
      ]) {
        final uri = Uri.https('missav.ai', path, {
          'page': '1',
          'sort': 'published_at',
        });
        final page = await client.browse(uri.toString());
        expect(adapter.requests.last.uri, uri);
        expect(page.url, uri.toString());
        await client.browse(page.nextUrl!);
        expect(
          adapter.requests.last.uri,
          uri.replace(queryParameters: {'page': '2', 'sort': 'published_at'}),
        );
      }
    });
  }

  for (final entry in {
    VideoSearchFilterKind.genre: 'genres',
    VideoSearchFilterKind.actor: 'actresses',
    VideoSearchFilterKind.studio: 'makers',
    VideoSearchFilterKind.series: 'series',
  }.entries) {
    test('filter picker loads only ${entry.value} choices and pages', () async {
      final route = entry.value;
      final adapter = _Adapter(
        (_) => _response('''
<nav><a href="/ja/$route/navigation">Navigation</a></nav>
<main>
<a href="/dm123/ja/$route/choice">Choice</a>
<a href="/ja/$route">Directory</a>
<a href="/ja/$route/ranking">Ranking</a>
<a href="/ja/history">History</a>
<a href="/ja/new">New</a>
<a href="https://elsewhere.example/$route/other">External</a>
<a href="/ja/$route?page=2" rel="next">Next</a>
</main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      )..setLocale('ja');
      addTearDown(client.dispose);

      final page = await client.searchFilterOptions(entry.key);
      expect(adapter.requests.single.uri.path, '/ja/$route');
      expect(page.links.map((link) => link.label), ['Choice']);
      expect(page.nextUrl, 'https://missav.ai/ja/$route?page=2');
      await client.searchFilterOptions(entry.key, pageUrl: page.nextUrl);
      expect(adapter.requests.last.uri.queryParameters['page'], '2');
    });
  }

  test('combined search intersects every source across later pages', () async {
    final adapter = _Adapter((request) {
      final page = request.uri.queryParameters['page'] ?? '1';
      final path = request.uri.path;
      if (path.contains('/search/')) {
        return _response(
          _searchCatalogHtml(
            page == '1' ? ['query-only'] : ['shared', 'genre-only', 'shared'],
            nextUrl: page == '1' ? '/cn/search/needle%20words?page=2' : null,
          ),
        );
      }
      if (path == '/ja/genres/selected') {
        return _response(
          _searchCatalogHtml(
            page == '1' ? ['genre-only'] : ['shared'],
            nextUrl: page == '1' ? '/ja/genres/selected?page=2' : null,
          ),
        );
      }
      if (path == '/cn/actresses/selected') {
        return _response(
          _searchCatalogHtml(
            page == '1' ? ['genre-only'] : ['shared'],
            nextUrl: '/cn/actresses/selected?page=${int.parse(page) + 1}',
          ),
        );
      }
      return _response(_searchCatalogHtml(['shared']));
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final results = await client.searchWithFilters(' needle words ', const [
      VideoLink(
        label: 'Genre',
        url: 'https://missav.ai/ja/genres/selected?page=9',
      ),
      VideoLink(label: 'Actor', url: 'https://missav.ai/cn/actresses/selected'),
      VideoLink(label: 'Studio', url: 'https://missav.ai/cn/makers/selected'),
    ]);

    expect(results.map((video) => video.id), ['shared']);
    expect(adapter.requests.first.uri.pathSegments.last, 'needle words');
    expect(adapter.requests[2].uri.path, '/ja/genres/selected');
    expect(adapter.requests[3].uri.path, '/ja/genres/selected');
    expect(
      adapter.requests.map(
        (request) => request.uri.queryParameters['page'] ?? '1',
      ),
      ['1', '2', '1', '2', '1', '2', '1'],
    );
    expect(adapter.requests.last.uri.path, '/cn/makers/selected');
  });

  test(
    'filter-only search keeps source order and deduplicates filters',
    () async {
      final adapter = _Adapter(
        (_) => _response(_searchCatalogHtml(['second', 'first', 'second'])),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      )..setLocale('ja');
      addTearDown(client.dispose);
      const filter = VideoLink(
        label: 'Actor',
        url: 'https://missav.ai/cn/actresses/selected',
      );

      final results = await client.searchWithFilters('', [filter, filter]);
      expect(results.map((video) => video.id), ['second', 'first']);
      expect(adapter.requests.single.uri.path, '/ja/actresses/selected');
    },
  );

  test(
    'superseded combined search stops before reading another page',
    () async {
      var current = true;
      final adapter = _Adapter((_) {
        current = false;
        return _response(
          _searchCatalogHtml(['one'], nextUrl: '/cn/genres/selected?page=2'),
        );
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final result = await client.searchWithFilters('', const [
        VideoLink(label: 'Genre', url: 'https://missav.ai/cn/genres/selected'),
      ], isCurrent: () => current);
      expect(result, isEmpty);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'combined search fails rather than returning a partial intersection',
    () async {
      final adapter = _Adapter(
        (request) => request.uri.path.contains('/genres/')
            ? _response(_searchCatalogHtml(['one']))
            : _response('Unavailable', statusCode: 503),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      await expectLater(
        client.searchWithFilters('', const [
          VideoLink(
            label: 'Genre',
            url: 'https://missav.ai/cn/genres/selected',
          ),
          VideoLink(
            label: 'Actor',
            url: 'https://missav.ai/cn/actresses/selected',
          ),
        ]),
        throwsA(isA<MissavException>()),
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'page jumps preserve collection filters without counting other catalogs',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<nav aria-label="Pagination">
  <a href="/cn/new?sort=views&amp;page=3" rel="next">Next</a>
  <a href="/cn/new?sort=views&amp;page=18">18</a>
  <a href="/cn/new?sort=date&amp;page=99">Other sort</a>
  <a href="/cn/actresses?page=200">Other catalog</a>
</nav>
<main></main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.browse(
        'https://missav.ai/dm123/cn/new?sort=views&page=2',
      );

      expect(page.currentPage, 2);
      expect(page.jumpMaxPage, 18);
      expect(Uri.parse(page.pageUrl(12)).queryParameters, {
        'sort': 'views',
        'page': '12',
      });
    },
  );

  group('signed-in MissAV access', () {
    for (final collection in [
      'favorites',
      'actorFavorites',
      'playlists',
      'history',
    ]) {
      test(
        '$collection uses the account host without probing mirrors',
        () async {
          final mirror = missavMirrors.first.baseUrl;
          final adapter = _Adapter((request) {
            if (request.uri.host != 'missav.ws') {
              return _response('Unavailable', statusCode: HttpStatus.notFound);
            }
            if (request.uri.path.endsWith('/api/login')) {
              return _metadataResponse({
                'user': {'name': 'signed-in-viewer'},
              });
            }
            return _response('<main><h1>Account collection</h1></main>');
          });
          final client = MissavClient(
            dio: Dio()..httpClientAdapter = adapter,
            metadataDio: _emptyMetadataDio(),
            secureStorage: _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token',
            contentHosts: [mirror, ...missavOfficialBaseUrls],
          );
          addTearDown(client.dispose);
          await client.initialize();
          await client.selectAccountHost('https://missav.ws');
          client.selectMirror(mirror);
          await client.login(
            email: 'viewer@example.test',
            password: 'password',
          );
          adapter.requests.clear();

          final page = await client.browse(client.collectionUrl(collection));

          expect(Uri.parse(page.url).host, 'missav.ws');
          expect(adapter.requests, hasLength(1));
          expect(adapter.requests.single.uri.host, 'missav.ws');
          expect(client.activeMirrorHost, Uri.parse(mirror).host);
          expect(client.isLoggedIn, isTrue);
        },
      );
    }

    test(
      'verified login keeps account access while details use the mirror',
      () async {
        final mirror = missavMirrors.first.baseUrl;
        final detail = await _detailHtml();
        final native = _Adapter((request) {
          if (request.uri.origin == mirror) return _response(detail);
          return _response(
            '<title>Just a moment...</title>',
            statusCode: HttpStatus.forbidden,
          );
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = native,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: [mirror, ...missavOfficialBaseUrls],
        );
        addTearDown(client.dispose);
        final documents = <Uri>[];
        late final MissavBrowserAdapter browser;
        browser = MissavBrowserAdapter(
          currentUrl: () async => MissavClient.origin,
          navigateDocument: (uri, _) async {
            documents.add(uri);
            return '<main><h1>Account collection</h1></main>';
          },
          disposeBrowser: () async {},
          readCookieHeader: () async =>
              'XSRF-TOKEN=token; session=authenticated',
          runJavaScript: (script) async {
            final match = RegExp(r'const request = (.*);').firstMatch(script);
            if (match == null) return;
            final request = jsonDecode(match.group(1)!) as Map;
            browser.receiveMessage({
              'id': request['id'],
              'nonce': request['nonce'],
              'origin': MissavClient.origin,
              'status': 200,
              'url': request['url'],
              'headers': {'content-type': 'application/json'},
              'body': '{"user":{"name":"signed-in-viewer"}}',
            });
          },
        );
        await client.importVerifiedSession(
          cookieHeader: 'XSRF-TOKEN=token; session=verified',
          userAgent: 'Browser UA',
        );
        client.selectMirror(mirror);
        client.useVerifiedBrowserTransport(browser);
        await client.login(email: 'viewer@example.test', password: 'password');

        final details = await client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
        );
        final playlists = await client.browse(
          client.collectionUrl('playlists'),
        );
        final history = await client.browse(client.collectionUrl('history'));

        expect(details.video.title, 'Sample detail');
        expect(Uri.parse(details.video.pageUrl).origin, mirror);
        expect(playlists.title, 'Account collection');
        expect(history.title, 'Account collection');
        expect(documents.map((uri) => uri.path), [
          '/cn/playlists',
          '/cn/history',
        ]);
        expect(
          native.requests.every((request) => request.uri.origin == mirror),
          isTrue,
        );
        expect(client.isLoggedIn, isTrue);
      },
    );
  });

  test(
    'collection search starts at the first page and includes later matches',
    () async {
      final adapter = _Adapter((request) {
        final page =
            int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
        final id = page == 1 ? 'first' : 'matching';
        final title = page == 1 ? 'Unrelated title' : 'Needle video';
        return _response('''
<main>
<div class="relative aspect-w-16 aspect-h-9">
  <a href="/cn/$id"><img alt="$title" src="https://media.example/cover.jpg"></a>
</div>
${page < 3 ? '<a href="/cn/saved?page=${page + 1}" rel="next">Next</a>' : ''}
</main>
''');
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final results = await client.searchCollection(
        'https://missav.ai/cn/saved?page=9',
        'NEEDLE',
      );

      expect(results.map((video) => video.id), ['matching']);
      expect(
        adapter.requests.map(
          (request) => request.uri.queryParameters['page'] ?? '1',
        ),
        ['1', '2', '3'],
      );
      expect(
        adapter.requests.every((request) => request.uri.path == '/cn/saved'),
        isTrue,
      );
    },
  );

  test('superseded collection search stops fetching later pages', () async {
    var current = true;
    final adapter = _Adapter((_) {
      current = false;
      return _response(
        '<main><a href="/cn/history?page=2" rel="next">Next</a></main>',
      );
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    expect(
      await client.searchCollection(
        client.collectionUrl('history'),
        'sample',
        isCurrent: () => current,
      ),
      isEmpty,
    );
    expect(adapter.requests, hasLength(1));
  });

  test(
    'unpacks base-62 streams without replacing inserted numeric paths',
    () async {
      final words = List.filled(43, '');
      words[2] = 'corrupt';
      words.setRange(36, 43, [
        'source',
        'https',
        'media',
        'example',
        'clip',
        'mp4',
        '2',
      ]);
      final adapter = _Adapter(
        (_) => _response('''
<main><h1>Sample video</h1><script>
eval(function(p,a,c,k,e,d){return p}('A="B://C.D/G/E.F";',62,43,'${words.join('|')}'.split('|'),0,{}))
</script></main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final details = await client.details(
        const VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/sample',
        ),
      );

      expect(details.streams.single.url, 'https://media.example/2/clip.mp4');
    },
  );

  test('rewrites mirror streams through the mirror media proxy', () async {
    final adapter = _Adapter(
      (_) => _response(r'''
<main><h1>Mirror sample</h1><script>
eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\b'+e(c)+'\b','g'),k[c])}}return p}('f=\'8://7.6/5-4-3-2-1/e.0\';d=\'8://7.6/5-4-3-2-1/c/9.0\';b=\'8://7.6/5-4-3-2-1/a/9.0\';',16,16,'m3u8|eda2e2c38fd8|847b|4e75|aae6|b67dbefa|com|surrit|https|video|1080p|source1280|720p|source842|playlist|source'.split('|'),0,{}))
</script></main>
'''),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final details = await client.details(
      const VideoItem(
        id: 'sample',
        title: 'Sample',
        pageUrl: 'https://www.missav9.net/en/sample',
      ),
    );

    expect(details.streams.map((stream) => stream.url), [
      'https://www.missav9.net/jmpres/surrit.com/b67dbefa-aae6-4e75-847b-eda2e2c38fd8/playlist.m3u8',
      'https://www.missav9.net/jmpres/surrit.com/b67dbefa-aae6-4e75-847b-eda2e2c38fd8/720p/video.m3u8',
      'https://www.missav9.net/jmpres/surrit.com/b67dbefa-aae6-4e75-847b-eda2e2c38fd8/1080p/video.m3u8',
    ]);
    expect(details.streams.first.headers['Origin'], 'https://www.missav9.net');
  });

  test(
    'a newer session change prevents an import waiting for initialization',
    () async {
      final storage = _MemorySecureStorage();
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final imported = client.importVerifiedSession(
        cookieHeader: 'session=stale',
        userAgent: 'Sample browser',
      );
      client.restoreNativeTransport();

      await expectLater(imported, throwsA(isA<MissavException>()));
      expect(storage.values, isEmpty);
      expect(client.isLoggedIn, isFalse);
    },
  );

  test(
    'browser navigates details and confirms the account through the API',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final documents = <Uri>[];
      final apiRequests = <String>[];
      final nativeAdapter = _Adapter(
        (request) => ResponseBody.fromString(
          request.uri.path.contains('/api/') ? '{"user":null}' : fixture,
          200,
        ),
      );
      final storage = _MemorySecureStorage();
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);
      client.setLocale('ja');
      await client.importVerifiedSession(
        cookieHeader: 'session=browser',
        userAgent: 'MissAV WebView/1.0',
      );
      late final MissavBrowserAdapter browser;
      browser = MissavBrowserAdapter(
        currentUrl: () async => 'https://missav.ai/ja/open-sample-001',
        disposeBrowser: () async {},
        readCookieHeader: () async => apiRequests.isEmpty
            ? 'session=rotated-in-document'
            : apiRequests.length == 1
            ? 'session=rotated-in-browser'
            : 'session=rotated-after-save',
        navigateDocument: (uri, cancelled) async {
          documents.add(uri);
          return fixture;
        },
        runJavaScript: (script) async {
          final match = RegExp(r'const request = (.*);').firstMatch(script);
          if (match == null) return;
          if (apiRequests.isEmpty) {
            expect(storage.cookie, 'session=rotated-in-document');
          }
          final request = jsonDecode(match.group(1)!) as Map<String, dynamic>;
          apiRequests.add(request['url'] as String);
          browser.receiveMessage({
            'id': request['id'],
            'nonce': request['nonce'],
            'origin': MissavClient.origin,
            'status': 200,
            'url': request['url'],
            'headers': {'content-type': 'application/json'},
            'body': '{"saved":false,"user":{"name":"Sample account"}}',
          }, origin: MissavClient.origin);
        },
      );
      client.useVerifiedBrowserTransport(browser);
      var mediaRoutes = 0;
      client.useVerifiedBrowserTransport(
        browser,
        mediaRoute: (uri) {
          mediaRoutes++;
          return Uri.parse('http://127.0.0.1:1234${uri.path}');
        },
      );

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Sample',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
        ),
      );

      expect(documents.map((uri) => uri.path), ['/ja/open-sample-001']);
      expect(apiRequests, ['https://missav.ai/api/items/source-123/view']);
      expect(client.isLoggedIn, isTrue);
      expect(storage.cookie, 'session=rotated-in-browser');
      expect(details.streams, hasLength(2));
      expect(mediaRoutes, 0);
      final prepared = await client.prepareMediaStream(
        details.video,
        details.streams.first,
      );
      expect(Uri.parse(prepared.url).host, '127.0.0.1');
      expect(prepared.headers, isEmpty);
      expect(mediaRoutes, 1);
      expect(nativeAdapter.requests, isEmpty);

      storage.beforeWrite = () async => throw StateError('Storage unavailable');
      await client.setVideoFavorite(details, true);
      expect(apiRequests.last, 'https://missav.ai/api/items/source-123/save');
      expect(storage.cookie, 'session=rotated-in-browser');
      storage.beforeWrite = null;
      await client.checkBrowserAccess();
      expect(storage.cookie, 'session=rotated-after-save');

      client.restoreNativeTransport();
      final nativeDetails = await client.details(details.video);
      expect(
        nativeDetails.streams.every(
          (stream) => Uri.parse(stream.url).host == 'media.example',
        ),
        isTrue,
      );
      expect(nativeAdapter.requests, hasLength(2));
    },
  );

  test('anonymous mirror details skip the account API', () async {
    final fixture = await File(
      'test/fixtures/missav/detail.html',
    ).readAsString();
    final adapter = _Adapter((request) {
      if (request.uri.path.contains('/api/')) {
        throw StateError('Unexpected account API request.');
      }
      return _response(fixture);
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    await client.initialize();
    client.selectMirror('https://www.missav9.net');

    final details = await client.details(
      const VideoItem(
        id: 'open-sample-001',
        title: 'Sample',
        pageUrl: 'https://www.missav9.net/en/open-sample-001',
      ),
    );

    expect(details.streams, isNotEmpty);
    expect(
      adapter.requests.any((request) => request.uri.path.contains('/api/')),
      isFalse,
    );
  });

  test(
    'mirror details read favorites from the restored account line',
    () async {
      final mirror = missavMirrors.first.baseUrl;
      const account = 'https://missav.ws';
      final storage = _MemorySecureStorage()
        ..values['iroru.missav_verified_session'] = jsonEncode({
          'cookie': 'session=saved',
          'userAgent': 'Saved Browser UA',
          'host': account,
        });
      final fixture = await _detailHtml();
      final adapter = _Adapter((request) {
        if (request.uri.path.endsWith('/view')) {
          return _response('{"saved":true,"user":{"name":"Viewer"}}');
        }
        return _response(fixture);
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: storage,
        contentHosts: [mirror, account],
      );
      addTearDown(client.dispose);

      final details = await client.details(
        VideoItem(
          id: 'open-sample-001',
          title: 'Sample',
          pageUrl: '$mirror/en/open-sample-001',
        ),
      );

      expect(details.isFavorite, isTrue);
      final page = adapter.requests.first;
      final view = adapter.requests.last;
      expect(page.uri.origin, mirror);
      expect(_cookieHeader(page), isEmpty);
      expect(view.uri.origin, account);
      expect(view.uri.path, endsWith('/view'));
      expect(_cookieHeader(view), 'session=saved');
      expect(details.streams, isNotEmpty);
      expect(
        details.streams.every(
          (stream) => Uri.parse(stream.url).origin == mirror,
        ),
        isTrue,
      );
    },
  );

  test('does not treat Cloudflare JSD as a verification challenge', () async {
    final fixture = await File(
      'test/fixtures/missav/catalog.html',
    ).readAsString();
    final pageWithCloudflareJsd = fixture.replaceFirst(
      '</body>',
      '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>'
          '</body>',
    );
    final adapter = _Adapter((_) => _response(pageWithCloudflareJsd));
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/dm285/ja');

    expect(page.videos, hasLength(2));
    expect(adapter.requests, hasLength(1));
  });

  test('recognizes concrete Cloudflare challenge markers', () async {
    final bodies = [
      '<title>Attention Required! | Cloudflare</title>',
      '<script>window._cf_chl_opt = {};</script>',
      '<form id="challenge-form"></form>',
      '<form action="/cdn-cgi/challenge-platform/h/b/flow"></form>',
      '<script src="/orchestrate/chl_page"></script>',
    ];
    var bodyIndex = 0;
    final adapter = _Adapter(
      (_) => _response(bodies[bodyIndex++], statusCode: HttpStatus.forbidden),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    for (final body in bodies) {
      await expectLater(
        client.browse('https://missav.ai/dm285/ja'),
        throwsA(isA<MissavVerificationRequiredException>()),
        reason: body,
      );
    }

    expect(adapter.requests, hasLength(bodies.length));
  });

  test('uses native access after a closed browser session', () async {
    final native = _Adapter(
      (_) => _response('<main><h1>Native catalog</h1></main>'),
    );
    final replacement = _Adapter((_) => _response('<h1>Restored catalog</h1>'));
    final navigationStarted = Completer<void>();
    final navigationFinished = Completer<void>();
    final navigationGate = Completer<String>();
    var restorations = 0;
    var browserDisposals = 0;
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = native,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (client, expectedGeneration) async {
        restorations++;
        expect(client.sessionGeneration, expectedGeneration);
        client.useVerifiedBrowserTransport(replacement);
      },
    );
    addTearDown(client.dispose);
    late final MissavBrowserAdapter browser;
    browser = MissavBrowserAdapter(
      currentUrl: () async => MissavClient.origin,
      navigateDocument: (_, _) async {
        navigationStarted.complete();
        final body = await navigationGate.future;
        navigationFinished.complete();
        return body;
      },
      disposeBrowser: () async => browserDisposals++,
      runJavaScript: (script) async {
        final match = RegExp(r'const request = (.*);').firstMatch(script)!;
        final request = jsonDecode(match.group(1)!) as Map;
        browser.receiveMessage({
          'id': request['id'],
          'nonce': request['nonce'],
          'origin': MissavClient.origin,
          'status': 200,
          'url': request['url'],
          'headers': {'content-type': 'application/json'},
          'body': '{"user":{"name":"viewer"}}',
        });
      },
    );
    await client.importVerifiedSession(
      cookieHeader: 'session=verified',
      userAgent: 'Test browser',
    );
    client.useVerifiedBrowserTransport(browser);

    final pendingBrowse = client
        .browse(client.homeUrl)
        .then<Object?>((page) => page, onError: (Object error) => error);
    await navigationStarted.future;
    browser.close(force: true);
    final browseError = await pendingBrowse;
    expect(
      browseError,
      isA<MissavException>().having(
        (error) => error.message,
        'message',
        contains('(connectionError)'),
      ),
    );
    expect(browseError, isNot(isA<MissavVerificationRequiredException>()));
    navigationGate.complete('<h1>Late catalog</h1>');
    await navigationFinished.future;
    await browser.whenClosed;
    final page = await client.browse(client.homeUrl);

    expect(page.title, 'Native catalog');
    expect(restorations, 0);
    expect(browserDisposals, 1);
    expect(
      native.requests.where((request) => !_isMirrorProbe(request)).toList(),
      hasLength(1),
    );
    expect(replacement.requests, isEmpty);
    await client.browse(client.homeUrl);
    expect(restorations, 0);
  });

  test(
    'restores native transport and invalidates an in-flight browser request',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final started = Completer<void>();
      final browserResponse = Completer<ResponseBody>();
      final nativeAdapter = _Adapter((_) => _response(fixture));
      final browserAdapter = _Adapter((_) {
        started.complete();
        return browserResponse.future;
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      client.useVerifiedBrowserTransport(browserAdapter);
      final staleBrowse = client.browse('https://missav.ai/dm285/ja');
      await started.future;

      client.restoreNativeTransport();
      browserResponse.complete(_response(fixture));

      await expectLater(staleBrowse, throwsA(isA<MissavException>()));
      await client.browse('https://missav.ai/dm285/ja');

      expect(browserAdapter.requests, hasLength(1));
      expect(nativeAdapter.requests, hasLength(1));
      expect(browserAdapter.closeCalls, 1);
      expect(nativeAdapter.closeCalls, 0);
    },
  );

  test(
    'replacing native transport invalidates an in-flight native request',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final started = Completer<void>();
      final nativeResponse = Completer<ResponseBody>();
      var nativeRequestCount = 0;
      final nativeAdapter = _Adapter((_) {
        nativeRequestCount++;
        if (nativeRequestCount == 1) {
          started.complete();
          return nativeResponse.future;
        }
        return _response(fixture);
      });
      final browserAdapter = _Adapter((_) => _response(fixture));
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final staleBrowse = client.browse('https://missav.ai/dm285/ja');
      await started.future;
      client.useVerifiedBrowserTransport(browserAdapter);
      nativeResponse.complete(_response(fixture));

      await expectLater(staleBrowse, throwsA(isA<MissavException>()));
      await client.browse('https://missav.ai/dm285/ja');

      expect(nativeAdapter.requests, hasLength(1));
      expect(nativeAdapter.closeCalls, 0);
      expect(browserAdapter.requests, hasLength(1));
    },
  );

  test(
    'cancels a login before the replacement transport can send it',
    () async {
      SharedPreferences.setMockInitialValues({
        missavAccountBaseUrlKey: MissavClient.accountHosts.first,
      });
      final transformStarted = Completer<void>();
      final releaseTransform = Completer<void>();
      final nativeAdapter = _Adapter((_) => _response('{}'));
      final browserAdapter = _CancelAwareAdapter((_) => _response('{}'));
      final dio = Dio()..httpClientAdapter = nativeAdapter;
      dio.transformer = _BlockingRequestTransformer(
        transformStarted,
        releaseTransform.future,
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: dio,
        secureStorage: _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D',
      );
      addTearDown(client.dispose);

      final login = client.login(email: 'user@example.test', password: 'pw');
      await transformStarted.future;
      client.useVerifiedBrowserTransport(browserAdapter);
      releaseTransform.complete();

      await expectLater(login, throwsA(isA<MissavException>()));

      expect(browserAdapter.requests, isEmpty);
      expect(nativeAdapter.requests, isEmpty);
    },
  );

  test(
    'closes replaced browser adapters and both owned adapters on dispose',
    () {
      final nativeAdapter = _Adapter((_) => _response('{}'));
      final firstBrowserAdapter = _Adapter((_) => _response('{}'));
      final secondBrowserAdapter = _Adapter((_) => _response('{}'));
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );

      var sessionChanges = 0;
      client.addListener(() => sessionChanges++);

      client.useVerifiedBrowserTransport(firstBrowserAdapter);
      client.useVerifiedBrowserTransport(firstBrowserAdapter);
      client.useVerifiedBrowserTransport(secondBrowserAdapter);
      expect(sessionChanges, 2);

      expect(firstBrowserAdapter.closeCalls, 1);
      expect(secondBrowserAdapter.closeCalls, 0);
      expect(nativeAdapter.closeCalls, 0);

      client.dispose();

      expect(firstBrowserAdapter.closeCalls, 1);
      expect(secondBrowserAdapter.closeCalls, 1);
      expect(nativeAdapter.closeCalls, 1);

      final sameAdapter = _Adapter((_) => _response('{}'));
      final sameAdapterClient = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = sameAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      sameAdapterClient.useVerifiedBrowserTransport(sameAdapter);
      sameAdapterClient.dispose();

      expect(sameAdapter.closeCalls, 1);
    },
  );

  test(
    'logout restores native transport and closes the browser adapter',
    () async {
      final nativeAdapter = _Adapter((_) => _response('<main></main>'));
      final browserAdapter = _Adapter((_) => _response('{}'));
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage()..cookie = 'session=source-only',
      );
      addTearDown(client.dispose);

      client.useVerifiedBrowserTransport(browserAdapter);
      await client.logout();
      await client.browse('https://missav.ai/dm285/ja');

      expect(browserAdapter.closeCalls, 1);
      expect(browserAdapter.requests, isEmpty);
      expect(nativeAdapter.requests, hasLength(1));
      expect(nativeAdapter.closeCalls, 0);
    },
  );

  test('rethrows a browser verification exception through Dio', () async {
    const sourceUrl = 'https://missav.ai/dm285/ja';
    const verificationError = MissavVerificationRequiredException(
      sourceUrl: sourceUrl,
    );
    final browserAdapter = _Adapter(
      (options) =>
          throw DioException(requestOptions: options, error: verificationError),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    client.useVerifiedBrowserTransport(browserAdapter);

    await expectLater(
      client.browse(sourceUrl),
      throwsA(same(verificationError)),
    );
  });

  test(
    'reads login state from the source page rather than the stored cookie',
    () async {
      _selectOriginAccountHost();
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final authenticatedFixture = fixture.replaceFirst(
        '{user: null}',
        "{user: {username: 'sample-viewer'}}",
      );
      final storage = _MemorySecureStorage()..cookie = 'visitor=source-cookie';
      final adapter = _Adapter((_) => _response(authenticatedFixture));
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await client.initialize();
      expect(client.isLoggedIn, isFalse);

      await client.browse('https://missav.ai/dm285/ja');

      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'sample-viewer');
      expect(storage.cookie, 'visitor=source-cookie');
    },
  );

  test('does not restore or alter previous app credentials', () async {
    final legacyValues = {
      'missav_session_cookie': 'session=legacy',
      'missav_verified_session':
          '{"cookie":"session=legacy","userAgent":"Old app"}',
    };
    final storage = _MemorySecureStorage()..values.addAll(legacyValues);
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    await client.initialize();

    expect(client.hasRestorableSession, isFalse);
    expect(storage.values, legacyValues);
  });

  test(
    'restores an imported browser session without treating it as logged in',
    () async {
      const cookie = 'session=browser-session';
      const userAgent = 'MissAV WebView/1.0';
      final storage = _MemorySecureStorage();
      final importingClient = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
        secureStorage: storage,
      );
      await importingClient.importVerifiedSession(
        cookieHeader: cookie,
        userAgent: userAgent,
      );
      expect(importingClient.isLoggedIn, isFalse);
      importingClient.dispose();

      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final adapter = _Adapter(
        (request) => _response(
          request.uri.path.endsWith('/saved')
              ? '<body x-data="{user: {name: \'Browser viewer\'}}"></body>'
              : fixture,
        ),
      );
      final restoredClient = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(restoredClient.dispose);

      await restoredClient.initialize();
      expect(restoredClient.isLoggedIn, isFalse);
      expect(adapter.requests, isEmpty);

      await restoredClient.browse('https://missav.ai/cn');

      expect(adapter.requests, hasLength(1));
      expect(_cookieHeader(adapter.requests.single), cookie);
      expect(_headerValue(adapter.requests.single, 'User-Agent'), userAgent);
      expect(restoredClient.isLoggedIn, isFalse);
      expect(storage.cookie, cookie);
      expect(
        storage.values.values.any((value) => value.contains(userAgent)),
        isTrue,
      );
      expect(await restoredClient.restoreAccount(), isTrue);
      expect(restoredClient.accountName, 'Browser viewer');
      expect(_cookieHeader(adapter.requests.last), cookie);
    },
  );

  test('coalesces account restoration and saves rotated cookies', () async {
    const accountMarkup = '<body x-data="{user: {name: \'Viewer\'}}"></body>';
    final storage = _MemorySecureStorage()..cookie = 'session=browser';
    final firstResponse = Completer<ResponseBody>();
    final requestStarted = Completer<void>();
    final adapter = _Adapter((request) {
      expect(request.uri, Uri.parse('https://missav.ai/en/saved'));
      expect(_cookieHeader(request), 'session=browser');
      requestStarted.complete();
      return firstResponse.future;
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    await client.initialize();
    final first = client.restoreAccount();
    await requestStarted.future;
    final second = client.restoreAccount();
    firstResponse.complete(
      _response(
        accountMarkup,
        headers: {
          'set-cookie': [
            'session=rotated; Path=/; Max-Age=120; '
                'Expires=Sat, 01 Jan 2000 00:00:00 GMT',
          ],
        },
      ),
    );
    expect(await Future.wait([first, second]), [true, true]);
    expect(client.accountName, 'Viewer');
    expect(adapter.requests, hasLength(1));
    expect(storage.cookie, 'session=rotated');
    final record =
        jsonDecode(storage.values['iroru.missav_verified_session']!) as Map;
    expect(record['expires'], contains('session'));
    client.dispose();

    final nextAdapter = _Adapter((request) {
      expect(_cookieHeader(request), 'session=rotated');
      if (request.method == 'POST') return _response('{}');
      return _response(accountMarkup);
    });
    final restarted = MissavClient(
      dio: Dio()..httpClientAdapter = nextAdapter,
      secureStorage: storage,
    );
    addTearDown(restarted.dispose);
    expect(await restarted.restoreAccount(), isTrue);
    await restarted.setVideoFavorite(
      const VideoDetails(
        video: VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/en/sample',
        ),
        sourceId: 'sample-id',
      ),
      true,
    );
    expect(nextAdapter.requests.last.uri.path, '/api/items/sample-id/save');
  });

  test('does not recover an expired cookie from the legacy copy', () async {
    final storage = _MemorySecureStorage()..cookie = 'session=expired';
    storage.values['iroru.missav_verified_session'] = jsonEncode({
      'cookie': storage.cookie,
      'host': 'https://missav.ai',
      'userAgent': 'MissAV WebView/1.0',
      'expires': {'session': 1},
    });
    final adapter = _Adapter((_) => _response('{}'));
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);
    expect(await client.restoreAccount(), isFalse);
    expect(adapter.requests, isEmpty);
  });

  test('only discards a saved session after account rejection', () async {
    final storage = _MemorySecureStorage()..cookie = 'session=saved';
    var attempts = 0;
    final adapter = _Adapter((request) {
      expect(_cookieHeader(request), 'session=saved');
      return switch (++attempts) {
        1 => _response(
          'Unavailable',
          statusCode: HttpStatus.serviceUnavailable,
        ),
        2 => _response(
          '<body x-data="{user: null}"><button>Login</button></body>',
        ),
        _ => _response(
          '<main><h1>My video collection</h1><a href="#">Login</a></main>',
        ),
      };
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    for (var failure = 0; failure < 2; failure++) {
      await expectLater(
        client.restoreAccount(),
        throwsA(isA<MissavException>()),
      );
      expect(storage.cookie, 'session=saved');
      expect(client.hasRestorableSession, isTrue);
    }
    expect(await client.restoreAccount(), isFalse);
    expect(storage.values, isEmpty);
    expect(await client.restoreAccount(), isFalse);
    expect(adapter.requests, hasLength(3));
  });

  test('rechecking a signed-in account clears a rejected session', () async {
    final storage = _MemorySecureStorage()..cookie = 'session=saved';
    var expired = false;
    final adapter = _Adapter(
      (_) => expired
          ? _response('Unauthorized', statusCode: HttpStatus.unauthorized)
          : _response('<body x-data="{user: {name: \'Viewer\'}}"></body>'),
    );
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    expect(await client.restoreAccount(), isTrue);
    expired = true;
    expect(await client.restoreAccount(), isTrue);
    expect(adapter.requests, hasLength(1));
    expect(await client.restoreAccount(recheck: true), isFalse);
    expect(adapter.requests, hasLength(2));
    expect(client.isLoggedIn, isFalse);
    expect(storage.values, isEmpty);
  });

  test('logout wins over a late account restore response', () async {
    final storage = _MemorySecureStorage()..cookie = 'session=saved';
    final requestStarted = Completer<void>();
    final response = Completer<ResponseBody>();
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          requestStarted.complete();
          return response.future;
        }),
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    final restoring = expectLater(
      client.restoreAccount(),
      throwsA(isA<MissavException>()),
    );
    await requestStarted.future;
    await client.logout();
    response.complete(
      _response(
        '<body x-data="{user: {name: \'Old viewer\'}}"></body>',
        headers: {
          'set-cookie': ['session=late; Path=/; Secure'],
        },
      ),
    );
    await restoring;
    expect(client.isLoggedIn, isFalse);
    expect(await client.restoreAccount(), isFalse);
    expect(storage.values, isEmpty);
  });

  test('surfaces the browser challenge as a source entry point', () async {
    final fixture = await File(
      'test/fixtures/missav/challenge.html',
    ).readAsString();
    final adapter = _Adapter(
      (_) => _response(fixture, statusCode: HttpStatus.forbidden),
    );
    final storage = _MemorySecureStorage()..cookie = 'session=existing';
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);
    client.setLocale('ja');

    await expectLater(
      client.browse('https://missav.ai/dm285/ja'),
      throwsA(
        isA<MissavVerificationRequiredException>()
            .having(
              (error) => error.sourceUrl,
              'source URL',
              'https://missav.ai/dm285/ja',
            )
            .having(
              (error) => error.message,
              'message',
              contains('verification'),
            ),
      ),
    );
    expect(storage.cookie, 'session=existing');
    expect(client.isLoggedIn, isFalse);
  });

  test(
    'recognizes the challenge response header and preserves the session',
    () async {
      final adapter = _Adapter(
        (_) => _response(
          '<html>Verification needed</html>',
          statusCode: HttpStatus.forbidden,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
      );
      final storage = _MemorySecureStorage()..cookie = 'session=valid';
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.browse('https://missav.ai/cn'),
        throwsA(
          isA<MissavVerificationRequiredException>().having(
            (error) => error.message,
            'message',
            contains('verification'),
          ),
        ),
      );

      expect(storage.cookie, 'session=valid');
      expect(client.isLoggedIn, isFalse);
    },
  );

  test('rejects empty or line-breaking browser request headers', () async {
    final storage = _MemorySecureStorage();
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    for (final values in [
      (cookie: '', userAgent: 'Browser UA'),
      (cookie: 'session=valid', userAgent: ''),
      (cookie: 'session=valid\r\nX-Injected: yes', userAgent: 'Browser UA'),
      (cookie: 'session=valid', userAgent: 'Browser UA\nCookie: injected'),
    ]) {
      await expectLater(
        client.importVerifiedSession(
          cookieHeader: values.cookie,
          userAgent: values.userAgent,
        ),
        throwsArgumentError,
      );
    }

    expect(storage.values, isEmpty);
  });

  test('keeps a stored session after source and network errors', () async {
    final failures =
        <
          ({
            String name,
            FutureOr<ResponseBody> Function(RequestOptions) respond,
          })
        >[
          (
            name: 'server error',
            respond: (RequestOptions _) => _response(
              'Service unavailable',
              statusCode: HttpStatus.serviceUnavailable,
            ),
          ),
          (
            name: 'connection error',
            respond: (RequestOptions options) => throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          ),
        ];
    for (final failure in failures) {
      final storage = _MemorySecureStorage()..cookie = 'session=valid';
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = _Adapter(failure.respond),
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.browse('https://missav.ai/cn'),
        throwsA(isA<MissavException>()),
        reason: failure.name,
      );
      expect(storage.cookie, 'session=valid', reason: failure.name);
      expect(client.isLoggedIn, isFalse, reason: failure.name);
    }
  });

  test('probes native access once before concurrent first requests', () async {
    _selectOriginAccountHost();
    final fixture = await File(
      'test/fixtures/missav/catalog.html',
    ).readAsString();
    final storage = _storedBrowserSession();
    var restoreCalls = 0;
    final nativeAdapter = _Adapter((request) {
      if (request.uri.path == '/api/playlists/open-sample-001') {
        return _response(
          '{"data":[]}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response(fixture);
    });
    final browserAdapter = _Adapter(
      (_) => throw StateError('Native access should be used first.'),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = nativeAdapter,
      secureStorage: storage,
      restoreSavedSession: (client, expectedGeneration) async {
        restoreCalls++;
        await client.importVerifiedSession(
          cookieHeader: 'session=browser',
          userAgent: 'Browser UA',
          expectedGeneration: expectedGeneration,
        );
        client.useVerifiedBrowserTransport(browserAdapter);
      },
    );
    addTearDown(client.dispose);

    final browse = client.browse('https://missav.ai/cn');
    final playlists = client.playlistsFor(
      const VideoItem(
        id: 'open-sample-001',
        title: 'Sample',
        pageUrl: 'https://missav.ai/cn/open-sample-001',
      ),
    );

    await browse;
    await playlists;
    await client.browse('https://missav.ai/cn');

    expect(restoreCalls, 0);
    final contentRequests = nativeAdapter.requests
        .where((request) => !_isMirrorProbe(request))
        .toList();
    expect(contentRequests, hasLength(3));
    expect(browserAdapter.requests, isEmpty);
    for (final request in contentRequests) {
      expect(_cookieHeader(request), 'session=saved');
      expect(_headerValue(request, 'User-Agent'), 'Saved Browser UA');
    }
    expect(storage.cookie, 'session=saved');
  });

  test('tries content hosts in order and skips mirror challenges', () async {
    final first = missavMirrors[0].baseUrl;
    final second = missavMirrors[1].baseUrl;
    final adapter = _Adapter((request) {
      if (request.uri.origin == first) {
        return _response(
          '<title>Just a moment...</title>',
          statusCode: HttpStatus.forbidden,
        );
      }
      return _response(_searchCatalogHtml(['fallback-mirror']));
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      contentHosts: [first, second],
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'fallback-mirror');
    expect(client.activeMirrorHost, Uri.parse(second).host);
  });

  test('tries official hosts after content hosts', () async {
    final mirror = missavMirrors.first.baseUrl;
    final adapter = _Adapter((request) {
      if (request.uri.host == 'missav.ws') {
        return _response(_searchCatalogHtml(['official-video']));
      }
      return _response(
        '<title>Just a moment...</title>',
        statusCode: HttpStatus.forbidden,
      );
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      contentHosts: [mirror, 'https://missav.ws'],
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'official-video');
    expect(client.activeMirrorHost, 'missav.ws');
  });

  test('login tries missav.live before the other official hosts', () async {
    final loginHosts = <String>[];
    final adapter = _Adapter((request) {
      if (request.method == 'POST' && request.uri.path.endsWith('/api/login')) {
        loginHosts.add(request.uri.host);
      }
      if (request.uri.host == 'missav.live') {
        return request.uri.path.endsWith('/api/login')
            ? _response('{"user":{"name":"live-viewer"}}')
            : _response('<html></html>');
      }
      return _response(
        '<title>Just a moment...</title>',
        statusCode: HttpStatus.forbidden,
      );
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (_, _) async {},
    );
    addTearDown(client.dispose);

    await client.login(
      email: 'viewer@example.invalid',
      password: 'sample-password',
    );

    expect(loginHosts, ['missav.live']);
    expect(client.accountHostUrl, 'https://missav.live');
    expect(client.isLoggedIn, isTrue);
  });

  test('login falls back when the selected line has a gateway error', () async {
    final loginHosts = <String>[];
    final adapter = _Adapter((request) {
      if (request.method == 'POST' && request.uri.path.endsWith('/api/login')) {
        loginHosts.add(request.uri.host);
      }
      if (request.uri.host == 'missav.ws') {
        return request.uri.path.endsWith('/api/login')
            ? _response('{"user":{"name":"ws-viewer"}}')
            : _response('<html></html>');
      }
      return _response('Gateway error', statusCode: HttpStatus.badGateway);
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (_, _) async {},
    );
    addTearDown(client.dispose);

    await client.login(
      email: 'viewer@example.invalid',
      password: 'sample-password',
    );

    expect(loginHosts, ['missav.ws']);
    expect(client.accountHostUrl, 'https://missav.ws');
    expect(client.isLoggedIn, isTrue);
  });

  test('a late media route is discarded on account logout', () async {
    final route = Completer<Uri>();
    final client = MissavClient(secureStorage: _MemorySecureStorage());
    addTearDown(client.dispose);
    client.useVerifiedBrowserTransport(
      _Adapter((_) => throw StateError('Unexpected source request.')),
      mediaRoute: (_) => route.future,
    );
    final pending = expectLater(
      client.prepareMediaStream(
        const VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/sample',
        ),
        const VideoStream(label: 'Original', url: 'https://media.example/hls'),
      ),
      throwsA(isA<MissavException>()),
    );
    await client.logout();
    route.complete(Uri.parse('http://127.0.0.1/media'));
    await pending;
  });

  test(
    'cancelling media preparation leaves the shared route available',
    () async {
      final routeStarted = Completer<void>();
      final routeResult = Completer<Uri>();
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);
      client.useVerifiedBrowserTransport(
        _Adapter((_) => throw StateError('Unexpected source request.')),
        mediaRoute: (_) {
          if (!routeStarted.isCompleted) routeStarted.complete();
          return routeResult.future;
        },
      );
      const video = VideoItem(
        id: 'sample',
        title: 'Sample',
        pageUrl: 'https://missav.ai/cn/sample',
      );
      const stream = VideoStream(
        label: 'Source',
        url: 'https://media.example/hls',
      );
      final cancellation = RemoteAssetCancellation();
      final pending = expectLater(
        client.prepareMediaStreamWithCancellation(video, stream, cancellation),
        throwsA(isA<MissavException>()),
      );
      await routeStarted.future;
      cancellation.cancel();
      await pending;
      routeResult.complete(Uri.parse('http://127.0.0.1/media'));
      final next = await client.prepareMediaStream(video, stream);
      expect(next.url, 'http://127.0.0.1/media');
    },
  );

  for (final (status, headers, errorType) in [
    (403, <String, List<String>>{}, MissavAccessDeniedException),
    (
      429,
      {
        HttpHeaders.retryAfterHeader: [HttpDate.format(DateTime.utc(2030, 4))],
      },
      MissavRateLimitException,
    ),
    (
      503,
      {
        'cf-mitigated': ['challenge'],
      },
      MissavVerificationRequiredException,
    ),
  ]) {
    test('login stops on HTTP $status with the classified response', () async {
      final adapter = _Adapter(
        (request) => request.method == 'POST'
            ? _response('Source response', statusCode: status, headers: headers)
            : _response('<html></html>'),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      await expectLater(
        client.login(email: 'viewer@example.invalid', password: 'sample'),
        throwsA(
          predicate<MissavException>(
            (error) =>
                error.runtimeType == errorType &&
                (error is! MissavRateLimitException ||
                    error.retryAt == DateTime.utc(2030, 4)),
          ),
        ),
      );
      expect(
        adapter.requests.where((request) => request.method == 'POST'),
        hasLength(1),
      );
      expect(adapter.requests.map((request) => request.uri.host).toSet(), {
        'missav.live',
      });
    });
  }

  test('login starts from the selected account host', () async {
    final loginHosts = <String>[];
    final adapter = _Adapter((request) {
      if (request.method == 'POST' && request.uri.path.endsWith('/api/login')) {
        loginHosts.add(request.uri.host);
      }
      if (request.uri.host == 'missav.ai') {
        return request.uri.path.endsWith('/api/login')
            ? _response('{"user":{"name":"ai-viewer"}}')
            : _response('<html></html>');
      }
      return _response(
        '<title>Just a moment...</title>',
        statusCode: HttpStatus.forbidden,
      );
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (_, _) async {},
    );
    addTearDown(client.dispose);
    await client.selectAccountHost('https://missav.ai');

    await client.login(
      email: 'viewer@example.invalid',
      password: 'sample-password',
    );

    expect(loginHosts, ['missav.ai']);
    expect(client.accountHostUrl, 'https://missav.ai');
    expect(client.isLoggedIn, isTrue);
  });

  test('browser login restores the selected account host', () async {
    SharedPreferences.setMockInitialValues({});
    final native = _Adapter((_) => _response('<html></html>'));
    final browser = _Adapter((request) {
      if (request.method == 'POST' && request.uri.path.endsWith('/api/login')) {
        return _metadataResponse({
          'user': {'name': 'browser-viewer'},
        });
      }
      return _response('<html></html>');
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = native,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    await client.initialize();
    await client.selectAccountHost('https://missav.ws');
    client.useVerifiedBrowserTransport(browser);

    await client.login(
      email: 'viewer@example.invalid',
      password: 'sample-password',
    );

    expect(client.accountHostUrl, 'https://missav.ws');
    expect(client.isLoggedIn, isTrue);
    expect(
      browser.requests
          .where((request) => request.uri.path.endsWith('/api/login'))
          .single
          .uri
          .host,
      'missav.ai',
    );
  });

  test('keeps a saved mirror preference', () async {
    const savedHost = 'www.thisav02.com';
    SharedPreferences.setMockInitialValues({
      missavMirrorBaseUrlKey: 'https://$savedHost',
    });
    final adapter = _Adapter((request) {
      if (request.uri.host == savedHost) {
        return _response(_searchCatalogHtml(['saved-mirror']));
      }
      return _response(
        '<title>Just a moment...</title>',
        statusCode: HttpStatus.forbidden,
      );
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (client, expectedGeneration) async {},
    );
    addTearDown(client.dispose);
    await client.initialize();

    final page = await client.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'saved-mirror');
    expect(client.activeMirrorHost, savedHost);
    expect(client.usesAutomaticMirror, isFalse);
  });

  test('clears a saved mirror that no longer works', () async {
    const savedHost = 'www.thisav02.com';
    SharedPreferences.setMockInitialValues({
      missavMirrorBaseUrlKey: 'https://$savedHost',
    });
    final adapter = _Adapter((request) {
      if (request.uri.host == savedHost) {
        return _response(
          '<title>Just a moment...</title>',
          statusCode: HttpStatus.forbidden,
        );
      }
      return _response(_searchCatalogHtml(['automatic-mirror']));
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (client, expectedGeneration) async {},
    );
    addTearDown(client.dispose);
    await client.initialize();

    final page = await client.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'automatic-mirror');
    expect(client.usesAutomaticMirror, isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(missavMirrorBaseUrlKey), '');
  });

  test('keeps a saved mirror after a transient failure', () async {
    const savedHost = 'www.thisav02.com';
    SharedPreferences.setMockInitialValues({
      missavMirrorBaseUrlKey: 'https://$savedHost',
    });
    final adapter = _Adapter((request) {
      if (request.uri.host == savedHost) {
        return _response('', statusCode: HttpStatus.badGateway);
      }
      return _response(_searchCatalogHtml(['automatic-mirror']));
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (client, expectedGeneration) async {},
    );
    addTearDown(client.dispose);
    await client.initialize();

    final page = await client.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'automatic-mirror');
    expect(client.activeMirrorHost, 'missav.ai');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(missavMirrorBaseUrlKey), 'https://$savedHost');
  });

  test('reuses the last good content host on the next start', () async {
    final first = missavMirrors[0].baseUrl;
    final good = missavMirrors[1].baseUrl;
    final firstRequests = <String>[];
    final firstClient = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((request) {
          firstRequests.add(request.uri.origin);
          return request.uri.origin == good
              ? _response(_searchCatalogHtml(['cached-page']))
              : _response(
                  '<title>Just a moment...</title>',
                  statusCode: HttpStatus.forbidden,
                );
        }),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      contentHosts: [first, good],
    );
    addTearDown(firstClient.dispose);
    await firstClient.browse('https://missav.ai/cn/release');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(missavLastGoodHostKey), good);

    final nextRequests = <String>[];
    final nextClient = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((request) {
          nextRequests.add(request.uri.origin);
          return _response(_searchCatalogHtml(['next-page']));
        }),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      contentHosts: [first, good],
    );
    addTearDown(nextClient.dispose);
    final page = await nextClient.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'next-page');
    expect(nextClient.activeMirrorHost, Uri.parse(good).host);
    expect(nextRequests, [good]);
    expect(firstRequests, contains(first));
  });

  test('replaces a failed cached host with the next success', () async {
    final failed = missavMirrors[2].baseUrl;
    final good = missavMirrors[3].baseUrl;
    SharedPreferences.setMockInitialValues({missavLastGoodHostKey: failed});
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((request) {
          return request.uri.origin == failed
              ? _response('', statusCode: HttpStatus.badGateway)
              : _response(_searchCatalogHtml(['next-good']));
        }),
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      contentHosts: [failed, good],
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/cn/release');
    final preferences = await SharedPreferences.getInstance();

    expect(page.videos.single.id, 'next-good');
    expect(client.activeMirrorHost, Uri.parse(good).host);
    expect(preferences.getString(missavLastGoodHostKey), good);
  });

  test('uses a mirror without opening a browser', () async {
    final mirror = missavMirrors.first;
    final nativeAdapter = _Adapter((request) {
      if (request.uri.host == 'missav.ai') {
        return _response(
          '<title>Just a moment...</title>',
          statusCode: HttpStatus.forbidden,
        );
      }
      return _response(_searchCatalogHtml(['mirror-video']));
    });
    var restoreCalls = 0;
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = nativeAdapter,
      secureStorage: _storedBrowserSession(),
      contentHosts: [mirror.baseUrl],
      restoreSavedSession: (client, expectedGeneration) async {
        restoreCalls++;
      },
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/cn/release');

    expect(page.videos.single.id, 'mirror-video');
    expect(restoreCalls, 0);
    final mirrorRequest = nativeAdapter.requests.firstWhere(
      (request) => request.uri.host == mirror.host,
    );
    expect(_cookieHeader(mirrorRequest), '');
  });

  test('surfaces official challenges without opening a browser', () async {
    final adapter = _Adapter(
      (_) => _response(
        '<title>Just a moment...</title>',
        statusCode: HttpStatus.forbidden,
      ),
    );
    var restoreCalls = 0;
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (_, _) async => restoreCalls++,
    );
    addTearDown(client.dispose);

    await expectLater(
      client.browse('https://missav.ai/cn'),
      throwsA(isA<MissavVerificationRequiredException>()),
    );
    expect(restoreCalls, 0);
  });

  test('login uses the verified browser without restoring another', () async {
    final nativeAdapter = _Adapter(
      (_) => _response(
        '<title>Just a moment...</title>',
        statusCode: HttpStatus.forbidden,
      ),
    );
    final browserAdapter = _Adapter((request) {
      if (request.uri.path.endsWith('/api/login')) {
        return _response(
          '{"user":{"name":"browser-viewer"}}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response('<html></html>');
    });
    var restoreCalls = 0;
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = nativeAdapter,
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (client, expectedGeneration) async {
        restoreCalls++;
      },
    );
    addTearDown(client.dispose);
    await client.importVerifiedSession(
      cookieHeader: 'XSRF-TOKEN=token%3D',
      userAgent: 'Browser UA',
    );
    client.useVerifiedBrowserTransport(browserAdapter);

    await client.login(
      email: 'viewer@example.invalid',
      password: 'sample-password',
    );

    expect(restoreCalls, 0);
    expect(nativeAdapter.requests, isEmpty);
    expect(
      browserAdapter.requests.any(
        (request) =>
            request.method == 'POST' && request.uri.path == '/en/api/login',
      ),
      isTrue,
    );
    expect(client.accountName, 'browser-viewer');
  });

  test('login returns content to the selected mirror', () async {
    const mirrorHost = 'www.missav9.net';
    final nativeAdapter = _Adapter(
      (request) => request.uri.host == mirrorHost
          ? _response(_searchCatalogHtml(['after-login']))
          : _response(
              '<title>Just a moment...</title>',
              statusCode: HttpStatus.forbidden,
            ),
    );
    final browserAdapter = _Adapter((request) {
      if (request.uri.path.endsWith('/api/login')) {
        return _response(
          '{"user":{"name":"mirror-viewer"}}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response('<html></html>');
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = nativeAdapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    await client.initialize();
    client.selectMirror('https://$mirrorHost');
    await client.importVerifiedSession(
      cookieHeader: 'session=browser',
      userAgent: 'Browser UA',
    );
    client.useVerifiedBrowserTransport(browserAdapter);

    await client.login(
      email: 'viewer@example.invalid',
      password: 'sample-password',
    );

    expect(browserAdapter.closeCalls, 0);
    expect(client.activeMirrorHost, mirrorHost);
    final page = await client.browse('https://missav.ai/cn/release');
    expect(page.videos.single.id, 'after-login');
  });

  test('loads the first page without a separate probe', () async {
    var restoreCalls = 0;
    final adapter = _Adapter((_) => _response('<main></main>'));
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (_, _) async {
        restoreCalls++;
      },
    );
    addTearDown(client.dispose);

    await client.browse('https://missav.ai/cn');

    expect(restoreCalls, 0);
    expect(
      adapter.requests.where((request) => !_isMirrorProbe(request)).toList(),
      hasLength(1),
    );
  });

  test(
    'parses detail state and packed stream URLs without executing scripts',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final adapter = _Adapter((options) {
        if (options.uri.path.endsWith('/api/login')) {
          return _response('{"user":{"email":"viewer@example.invalid"}}');
        }
        if (options.uri.path == '/api/items/source-123/view') {
          return _response(
            '{"user":{"email":"viewer@example.invalid"},"saved":true}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        return _response(fixture);
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await client.selectAccountHost('https://missav.ai');
      client.setLocale('ja');

      await client.login(email: 'viewer@example.invalid', password: 'sample');
      final accountStates = <bool>[];
      client.addListener(() => accountStates.add(client.isLoggedIn));

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Card title',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
          hasSubtitles: true,
          isUncensored: true,
        ),
      );

      expect(details.video.title, 'Sample detail');
      expect(details.video.cover, 'https://fourhoi.com/sample-001/cover-n.jpg');
      expect(details.description, 'A sanitized sample description');
      expect(details.metadata['配信開始日'], '2024-03-02');
      expect(details.video.releaseDate, '2024-03-02');
      expect(details.video.hasSubtitles, isTrue);
      expect(details.video.isUncensored, isTrue);
      expect(details.metadata.containsKey('メーカー'), isFalse);
      expect(details.video.actors.map((actor) => actor.label), [
        'Sample actor',
      ]);
      expect(details.video.tags.map((tag) => tag.label), [
        'Sample genre',
        'Sample maker',
        'Sample director',
        'Sample label',
      ]);
      expect(details.video.tags.last.kind, VideoLinkKind.category);
      expect(details.related.map((video) => video.id), ['open-related-002']);
      expect(details.related.single.releaseDate, isNull);
      expect(details.related.single.actors, isEmpty);
      expect(details.related.single.tags, isEmpty);
      expect(details.sourceId, 'source-123');
      expect(details.isFavorite, isTrue);
      expect(details.streams, hasLength(2));
      expect(
        details.streams.first.url,
        'https://media.example/hls/master.m3u8',
      );
      expect(details.streams.first.isHls, isTrue);
      expect(
        details.streams.first.headers[HttpHeaders.refererHeader],
        'https://missav.ai/ja/open-sample-001',
      );
      expect(details.streams.first.headers['Origin'], MissavClient.origin);
      expect(details.streams.first.headers.containsKey('Cookie'), isFalse);
      expect(
        details.streams.first.headers.containsKey('Authorization'),
        isFalse,
      );
      expect(details.streams.last.url, 'https://media.example/file/clip.mp4');
      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'viewer@example.invalid');
      expect(accountStates, isEmpty);
      expect(
        adapter.requests.map((request) => request.uri.host),
        everyElement('missav.ai'),
      );
    },
  );

  test(
    'keeps source metadata unless displayed links express the full row',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<main>
  <h1>Metadata sample</h1>
  <div class="text-secondary"><span>Genre link:</span><a href="/cn/genres/drama">Drama</a>, <a href="/cn/genres/action">Action</a></div>
  <div class="text-secondary"><span>Genre:</span>Plain genre</div>
  <div class="text-secondary"><span>Maker:</span><a href="/cn/makers/acme">Acme</a></div>
  <div class="text-secondary"><span>Makers:</span>Plain maker</div>
  <div class="text-secondary"><span>Labels:</span>Plain label</div>
  <div class="text-secondary"><span>Series:</span>Plain series</div>
  <div class="text-secondary"><span>Directors:</span>Plain director</div>
  <div class="text-secondary"><span>Actresses:</span>Plain actor</div>
  <div class="text-secondary"><span>Maker note:</span><a href="/cn/makers/acme">Acme</a> licensed</div>
  <div class="text-secondary"><span>Unclassified:</span><a href="/cn/genres/drama">Drama</a> source detail</div>
  <div class="text-secondary"><span>Duration:</span>128 minutes</div>
</main>
'''),
      );
      final metadata = _Adapter(
        (_) => _metadataResponse({
          'recomms': [
            {
              'id': 'metadata-sample',
              'values': {
                'actresses': ['Plain actor'],
                'genres': ['Plain genre'],
                'markers': ['Plain maker'],
                'labels': ['Plain label'],
                'series': ['Plain series'],
                'directors': ['Plain director'],
              },
            },
          ],
        }),
      );
      final client = MissavClient(
        metadataDio: Dio()..httpClientAdapter = metadata,
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final details = await client.details(
        const VideoItem(
          id: 'metadata-sample',
          title: 'Metadata sample',
          pageUrl: 'https://missav.ai/cn/metadata-sample',
        ),
      );

      for (final label in [
        'Genre link',
        'Genre',
        'Maker',
        'Makers',
        'Labels',
        'Series',
        'Directors',
        'Actresses',
      ]) {
        expect(details.metadata.containsKey(label), isFalse, reason: label);
      }
      expect(details.metadata['Maker note'], 'Acme licensed');
      expect(details.metadata['Unclassified'], 'Drama source detail');
      expect(details.metadata['Duration'], '128 minutes');
      expect(details.video.tags.map((tag) => tag.label), [
        'Plain genre',
        'Drama',
        'Action',
        'Acme',
      ]);
      expect(details.video.makers, ['Plain maker']);
      expect(details.video.labels, ['Plain label']);
      expect(details.video.series, ['Plain series']);
      expect(details.video.directors, ['Plain director']);
      expect(details.video.actors.single.label, 'Plain actor');
    },
  );

  test('metadata name boundaries preserve unmatched source names', () async {
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _response('''
<main>
  <h1>Metadata boundaries</h1>
  <div class="text-secondary"><span>Maker:</span>StudioABC</div>
  <div class="text-secondary"><span>Makers:</span>Studio, ABC</div>
  <div class="text-secondary"><span>Studio:</span>Studio ABC</div>
  <div class="text-secondary"><span>Studios:</span>Studio/ABC</div>
  <div class="text-secondary"><span>Manufacturer:</span>StudioABC licensed</div>
</main>
'''),
        ),
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter(
          (options) => throw DioException(requestOptions: options),
        ),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final details = await client.details(
      const VideoItem(
        id: 'metadata-boundaries',
        title: 'Metadata boundaries',
        pageUrl: 'https://missav.ai/cn/metadata-boundaries',
        makers: ['Studio', 'ABC'],
      ),
    );

    expect(details.metadata['Maker'], 'StudioABC');
    expect(details.metadata['Manufacturer'], 'StudioABC licensed');
    for (final label in ['Makers', 'Studio', 'Studios']) {
      expect(details.metadata.containsKey(label), isFalse, reason: label);
    }
    expect(details.video.makers, ['Studio', 'ABC']);
  });

  test('keeps metadata for cached names replaced by source links', () async {
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _response('''
<main>
  <h1>Updated source details</h1>
  <div class="text-secondary"><span>Genre:</span><a href="/cn/genres/source">Source genre</a></div>
  <div class="text-secondary"><span>Genres:</span>Cached genre</div>
</main>
'''),
        ),
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter(
          (options) => throw DioException(requestOptions: options),
        ),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final details = await client.details(
      const VideoItem(
        id: 'updated-metadata',
        title: 'Cached details',
        pageUrl: 'https://missav.ai/cn/updated-metadata',
        tags: [
          VideoLink(
            label: 'Cached genre',
            url: 'https://missav.ai/cn/genres/cached',
            kind: VideoLinkKind.category,
          ),
        ],
      ),
    );

    expect(details.video.tags.single.label, 'Source genre');
    expect(details.metadata['Genres'], 'Cached genre');
  });

  test(
    'keeps same-named metadata in separate groups after supplement',
    () async {
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => _response('''
<main>
  <h1>Shared metadata names</h1>
  <div class="text-secondary"><span>Genre:</span><a href="/cn/genres/shared">Shared</a></div>
  <div class="text-secondary"><span>Maker:</span><a href="/cn/makers/shared">Shared</a></div>
</main>
'''),
          ),
        metadataDio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => _metadataResponse({
              'recomms': [
                {
                  'id': 'shared-metadata',
                  'values': {
                    'genres': ['Shared'],
                  },
                },
              ],
            }),
          ),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final details = await client.details(
        const VideoItem(
          id: 'shared-metadata',
          title: 'Shared metadata names',
          pageUrl: 'https://missav.ai/cn/shared-metadata',
        ),
      );

      expect(details.metadata.containsKey('Genre'), isFalse);
      expect(details.metadata.containsKey('Maker'), isFalse);
      expect(
        details.video.tags.map((tag) => tag.url),
        unorderedEquals([
          'https://missav.ai/cn/genres/shared',
          'https://missav.ai/cn/makers/shared',
        ]),
      );
    },
  );

  test(
    'uses the imported user agent for media without forwarding its cookie',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      const cookie = 'session=browser-only';
      const userAgent = 'MissAV WebView/1.0';
      final adapter = _Adapter((options) {
        if (options.uri.path == '/api/items/source-123/view') {
          return _response(
            '{"user":{"username":"browser-viewer"},"saved":false}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        return _response(fixture);
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await client.selectAccountHost('https://missav.ai');

      await client.importVerifiedSession(
        cookieHeader: cookie,
        userAgent: userAgent,
      );
      expect(client.isLoggedIn, isFalse);

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Card title',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
        ),
      );

      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'browser-viewer');
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.uri.host, 'missav.ai');
        expect(_cookieHeader(request), cookie);
        expect(_headerValue(request, 'User-Agent'), userAgent);
      }
      expect(details.streams, hasLength(2));
      for (final stream in details.streams) {
        expect(stream.headers[HttpHeaders.userAgentHeader], userAgent);
        expect(_hasHeader(stream.headers.keys, 'Cookie'), isFalse);
        expect(_hasHeader(stream.headers.keys, 'Authorization'), isFalse);
      }
      expect(details.streams.map((stream) => Uri.parse(stream.url).host), [
        'media.example',
        'media.example',
      ]);
    },
  );

  for (final failingLogin in [false, true]) {
    test(
      'authentication failure updates account state (login=$failingLogin)',
      () async {
        SharedPreferences.setMockInitialValues({
          missavAccountBaseUrlKey: MissavClient.accountHosts.first,
        });
        var loginRequests = 0;
        final adapter = _Adapter((options) {
          if (options.uri.path.endsWith('/api/login') && ++loginRequests == 1) {
            return _response('{"user":{"name":"Saved account"}}');
          }
          return _response('{}', statusCode: HttpStatus.unauthorized);
        });
        final storage = _MemorySecureStorage()
          ..cookie = 'XSRF-TOKEN=token%3D; clearance=verified';
        final client = MissavClient(
          metadataDio: _emptyMetadataDio(),
          dio: Dio()..httpClientAdapter = adapter,
          secureStorage: storage,
        );
        addTearDown(client.dispose);
        await client.login(email: 'viewer@example.test', password: 'sample');
        expect(client.isLoggedIn, isTrue);

        final operation = failingLogin
            ? client.login(email: 'other@example.test', password: 'wrong')
            : client.setVideoFavorite(
                const VideoDetails(
                  video: VideoItem(
                    id: 'sample',
                    title: 'Sample',
                    pageUrl: 'https://missav.ai/cn/sample',
                  ),
                  sourceId: 'source-123',
                ),
                true,
              );
        await expectLater(
          operation,
          throwsA(isA<MissavAuthenticationException>()),
        );

        expect(client.isLoggedIn, failingLogin);
        expect(client.accountName, failingLogin ? 'Saved account' : isNull);
        expect(storage.cookie, 'XSRF-TOKEN=token%3D; clearance=verified');
      },
    );
  }

  test(
    'updates video favorites through the observed source endpoint',
    () async {
      late RequestOptions request;
      final adapter = _Adapter((options) {
        request = options;
        return _response(
          '{}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await client.selectAccountHost('https://missav.ai');

      await client.setVideoFavorite(
        const VideoDetails(
          video: VideoItem(
            id: 'open-sample-001',
            title: 'Sample video',
            pageUrl: 'https://missav.ai/ja/open-sample-001',
          ),
          sourceId: 'source-123',
        ),
        true,
      );

      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'https://missav.ai/api/items/source-123/save',
      );
    },
  );

  test('loads an actor source ID before updating its favorite', () async {
    final fixture = await File(
      'test/fixtures/missav/actor.html',
    ).readAsString();
    final adapter = _Adapter((options) {
      if (options.uri.path == '/api/actresses/987654321/view') {
        return _response(
          '{"user":{"username":"sample-viewer"},"saved":false}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response(
        fixture,
        headers: {
          'content-type': ['text/html'],
        },
      );
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    client.setLocale('ja');

    await client.setActorFavorite(
      const VideoLink(
        label: 'Sample actor',
        url: 'https://missav.ai/dm288/ja/actresses/sample-actor',
        kind: VideoLinkKind.actor,
      ),
      true,
    );

    expect(adapter.requests.map((request) => request.uri.path), [
      '/dm288/ja/actresses/sample-actor',
      '/api/actresses/987654321/view',
      '/api/actresses/987654321/save',
    ]);
    expect(adapter.requests.last.method, 'POST');
    expect(client.accountName, 'sample-viewer');
  });

  test(
    'loads playlist state and uses the observed membership endpoints',
    () async {
      final adapter = _Adapter((options) {
        if (options.uri.path == '/api/playlists/open-sample-001') {
          return _response(
            '{"data":[{"key":"list-key","name":"Sample list","is_added":true}]}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        return _response(
          '{}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await client.selectAccountHost('https://missav.ai');
      client.setLocale('ja');
      const item = VideoItem(
        id: 'open-sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/ja/open-sample-001',
      );

      final playlists = await client.playlistsFor(item);
      expect(playlists, hasLength(1));
      expect(playlists.single.sourceKey, 'list-key');
      expect(playlists.single.isAdded, isTrue);
      expect(playlists.single.url, 'https://missav.ai/ja/playlists');

      await client.removeFromPlaylist(playlists.single, item);
      final request = adapter.requests.last;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://missav.ai/api/playlists/remove');
      expect(request.data, {'dvdId': 'open-sample-001', 'key': 'list-key'});
    },
  );

  test('does not follow a source redirect to a media host', () async {
    _selectOriginAccountHost();
    final adapter = _Adapter(
      (_) => _response(
        '',
        statusCode: HttpStatus.found,
        headers: {
          HttpHeaders.locationHeader: ['https://cdn.example/stream.m3u8'],
        },
      ),
    );
    final storage = _MemorySecureStorage()..cookie = 'session=source-only';
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    await expectLater(
      client.browse('https://missav.ai/dm285/ja'),
      throwsA(isA<MissavUnsupportedException>()),
    );

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.host, 'missav.ai');
    expect(_cookieHeader(adapter.requests.single), 'session=source-only');
  });

  test(
    'posts the observed login contract and stores only account-host cookies',
    () async {
      SharedPreferences.setMockInitialValues({
        missavAccountBaseUrlKey: 'https://missav.live',
      });
      final storage = _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D';
      late RequestOptions request;
      final adapter = _Adapter((options) {
        request = options;
        return _response(
          '{"user":{"email":"account@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=authenticated; Path=/; Secure'],
          },
        );
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await client.login(
        email: 'account@example.invalid',
        password: 'test-password',
      );

      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://missav.live/en/api/login');
      expect(request.data, {
        'email': 'account@example.invalid',
        'password': 'test-password',
        'remember': true,
      });
      expect(_cookieHeader(request), 'XSRF-TOKEN=token%3D');
      expect(request.headers['X-XSRF-TOKEN'], 'token=');
      expect(request.headers['Accept'], 'application/json, text/plain, */*');
      expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(request.headers['Origin'], 'https://missav.live');
      expect(request.headers['Referer'], 'https://missav.live/');
      expect(request.headers['Accept-Language'], 'en-US,en;q=0.9');
      expect(request.headers['Cache-Control'], 'no-cache');
      expect(_headerValue(request, 'User-Agent'), contains('Chrome/149.0.0.0'));
      expect(storage.cookie, 'XSRF-TOKEN=token%3D; session=authenticated');
      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'account@example.invalid');
    },
  );

  test('refreshes XSRF and retries login after HTTP 419', () async {
    var loginAttempts = 0;
    final adapter = _Adapter((options) {
      if (options.method == 'POST') {
        loginAttempts++;
        if (loginAttempts == 1) {
          return _response(
            'Page expired',
            statusCode: 419,
            headers: {
              'content-type': ['text/html; charset=utf-8'],
            },
          );
        }
        return _response(
          '{"user":{"email":"account@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=authenticated; Path=/; Secure'],
          },
        );
      }
      return _response(
        '<html></html>',
        headers: {
          'content-type': ['text/html; charset=utf-8'],
          'set-cookie': ['XSRF-TOKEN=fresh%3D; Path=/; Secure'],
        },
      );
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.login(
      email: 'account@example.invalid',
      password: 'test-password',
    );

    expect(adapter.requests.map((request) => request.method), [
      'GET',
      'POST',
      'GET',
      'POST',
    ]);
    expect(_cookieHeader(adapter.requests[3]), contains('XSRF-TOKEN=fresh%3D'));
    expect(client.isLoggedIn, isTrue);
  });

  test('confirms a native login through the home page', () async {
    SharedPreferences.setMockInitialValues({
      missavAccountBaseUrlKey: MissavClient.accountHosts.first,
    });
    final adapter = _Adapter((options) {
      if (options.method == 'POST') {
        return _response(
          '',
          headers: {
            'set-cookie': ['session=authenticated; Path=/; Secure'],
          },
        );
      }
      return _response(
        '<html><body x-data="{user: {name: \'Confirmed viewer\'}}">'
        '</body></html>',
      );
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D',
    );
    addTearDown(client.dispose);

    await client.login(
      email: 'account@example.invalid',
      password: 'test-password',
    );

    expect(adapter.requests.map((request) => request.method), ['POST', 'GET']);
    expect(client.isLoggedIn, isTrue);
    expect(client.accountName, 'Confirmed viewer');
  });

  test('rejects an error response that only mentions a user', () async {
    final adapter = _Adapter((options) {
      if (options.method == 'POST') {
        return _response(
          '{"message":"Invalid user or password"}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response('<html><body></body></html>');
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D',
    );
    addTearDown(client.dispose);

    await expectLater(
      client.login(
        email: 'account@example.invalid',
        password: 'wrong-password',
      ),
      throwsA(isA<MissavException>()),
    );
    expect(client.isLoggedIn, isFalse);
    expect(client.accountName, isNull);
  });

  test(
    'a late login response cannot replace a newer account session',
    () async {
      final firstResponse = Completer<ResponseBody>();
      final secondResponse = Completer<ResponseBody>();
      final firstSent = Completer<void>();
      final secondSent = Completer<void>();
      final storage = _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D';
      final adapter = _Adapter((options) {
        final email = (options.data as Map)['email'];
        if (email == 'first@example.invalid') {
          firstSent.complete();
          return firstResponse.future;
        }
        secondSent.complete();
        return secondResponse.future;
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final firstLogin = client.login(
        email: 'first@example.invalid',
        password: 'first-password',
      );
      final firstLoginRejected = expectLater(
        firstLogin,
        throwsA(isA<MissavException>()),
      );
      await firstSent.future;
      final secondLogin = client.login(
        email: 'second@example.invalid',
        password: 'second-password',
      );
      await secondSent.future;

      secondResponse.complete(
        _response(
          '{"user":{"email":"second@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=second; Path=/; Secure'],
          },
        ),
      );
      await secondLogin;
      firstResponse.complete(
        _response(
          '{"user":{"email":"first@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=first; Path=/; Secure'],
          },
        ),
      );

      await firstLoginRejected;
      expect(storage.cookie, 'XSRF-TOKEN=token%3D; session=second');
      expect(client.accountName, 'second@example.invalid');
    },
  );

  test(
    'an imported session wins over a delayed response-cookie write',
    () async {
      _selectOriginAccountHost();
      final started = Completer<void>();
      final release = Completer<void>();
      var blockNextWrite = true;
      final storage = _MemorySecureStorage()
        ..beforeWrite = () {
          if (!blockNextWrite) return Future<void>.value();
          blockNextWrite = false;
          started.complete();
          return release.future;
        };
      final fixture =
          (await File(
            'test/fixtures/missav/catalog.html',
          ).readAsString()).replaceFirst(
            '{user: null}',
            "{user: {username: 'stale-account'}}",
          );
      final adapter = _Adapter(
        (_) => _response(
          fixture,
          headers: {
            'set-cookie': ['session=stale; Path=/; Secure'],
          },
        ),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final staleBrowse = client.browse('https://missav.ai/cn');
      await started.future;
      final import = client.importVerifiedSession(
        cookieHeader: 'session=browser',
        userAgent: 'Browser UA',
      );
      await Future<void>.value();
      release.complete();

      await expectLater(staleBrowse, throwsA(isA<MissavException>()));
      await import;

      expect(storage.cookie, 'session=browser');
      expect(client.isLoggedIn, isFalse);
      expect(client.accountName, isNull);
    },
  );

  test(
    'logout invalidates a page while its response cookie is being stored',
    () async {
      _selectOriginAccountHost();
      final started = Completer<void>();
      final release = Completer<void>();
      final storage = _MemorySecureStorage()
        ..beforeWrite = () {
          started.complete();
          return release.future;
        };
      final fixture =
          (await File(
            'test/fixtures/missav/catalog.html',
          ).readAsString()).replaceFirst(
            '{user: null}',
            "{user: {username: 'old-account'}}",
          );
      final adapter = _Adapter(
        (_) => _response(
          fixture,
          headers: {
            'set-cookie': ['session=old; Path=/; Secure'],
          },
        ),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final request = expectLater(
        client.browse('https://missav.ai/cn'),
        throwsA(isA<MissavException>()),
      );
      await started.future;
      final logout = client.logout();
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait([request, logout]);
      expect(client.isLoggedIn, isFalse);
      expect(client.accountName, isNull);
      expect(storage.cookie, isNull);
    },
  );

  test(
    'logout clears the local source session without an unverified endpoint',
    () async {
      final storage = _MemorySecureStorage()..cookie = 'session=source-only';
      final adapter = _Adapter((_) => _response('{}'));
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await client.initialize();
      await client.importVerifiedSession(
        cookieHeader: 'session=source-only',
        userAgent: 'Browser UA',
      );
      await client.logout();

      expect(storage.cookie, isNull);
      expect(storage.values, isEmpty);
      expect(client.isLoggedIn, isFalse);
      expect(adapter.requests, isEmpty);
    },
  );

  group('background mirror probes', () {
    late ProxyMode previousProxyMode;

    setUp(() {
      previousProxyMode = ProxyConfig.mode;
      ProxyConfig.mode = ProxyMode.direct;
    });

    tearDown(() {
      ProxyConfig.mode = previousProxyMode;
    });

    test(
      'scans three mirrors once before using the fastest for browse and detail',
      () async {
        final detail = await _detailHtml();
        final hosts = [
          for (final mirror in missavMirrors.take(4)) mirror.baseUrl,
        ];
        final cached = hosts.last;
        SharedPreferences.setMockInitialValues({missavLastGoodHostKey: cached});
        final preferences = await SharedPreferences.getInstance();
        final responses = <String, Completer<ResponseBody>>{};
        final active = <String>{};
        var maxActive = 0;
        final adapter = _Adapter((request) {
          if (_isMirrorProbe(request)) {
            final host = request.uri.origin;
            active.add(host);
            maxActive = active.length > maxActive ? active.length : maxActive;
            final response = responses[host] = Completer<ResponseBody>();
            return response.future.whenComplete(() => active.remove(host));
          }
          return request.uri.path.endsWith('/open-sample-001')
              ? _response(detail)
              : _response(_searchCatalogHtml(['probed-first']));
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: _MemorySecureStorage(),
          contentHosts: hosts,
        );
        addTearDown(client.dispose);

        fakeAsync((async) {
          client.scheduleBackgroundMirrorProbe();
          _flushFakeAsync(async);
          expect(adapter.requests, isEmpty);

          client.initialize();
          _flushFakeAsync(async);
          client.scheduleBackgroundMirrorProbe();
          client.scheduleBackgroundMirrorProbe();
          async.elapse(const Duration(milliseconds: 999));
          _flushFakeAsync(async);
          expect(adapter.requests, isEmpty);

          async.elapse(const Duration(milliseconds: 1));
          _flushFakeAsync(async);
          expect(adapter.requests.map((request) => request.uri.origin), [
            cached,
          ]);
          expect(
            adapter.requests.single.uri.queryParameters['ts'],
            matches(RegExp(r'^\d+$')),
          );
          expect(maxActive, 1);

          responses[cached]!.complete(
            _response('down', statusCode: HttpStatus.serviceUnavailable),
          );
          _flushFakeAsync(async);
          expect(adapter.requests.map((request) => request.uri.origin), [
            cached,
            hosts[0],
          ]);
          expect(maxActive, 1);

          responses[hosts[0]]!.complete(_response('<html></html>'));
          _flushFakeAsync(async);
          expect(adapter.requests.map((request) => request.uri.origin), [
            cached,
            hosts[0],
            hosts[1],
          ]);
          expect(maxActive, 1);

          responses[hosts[1]]!.complete(
            _response('down', statusCode: HttpStatus.serviceUnavailable),
          );
          _flushFakeAsync(async);
          expect(adapter.requests, hasLength(3));
          expect(preferences.getString(missavLastGoodHostKey), cached);
          expect(preferences.getString(missavMirrorBaseUrlKey), isNull);

          client.scheduleBackgroundMirrorProbe();
          async.elapse(const Duration(seconds: 5));
          _flushFakeAsync(async);
          expect(adapter.requests, hasLength(3));

          adapter.requests.clear();
          var browseDone = false;
          client
              .browse('https://missav.ai/cn/release')
              .then((_) => browseDone = true)
              .ignore();
          _flushFakeAsync(async);
          expect(browseDone, isTrue);
          expect(adapter.requests.single.uri.origin, hosts[0]);

          adapter.requests.clear();
          var detailDone = false;
          client
              .details(
                VideoItem(
                  id: 'open-sample-001',
                  title: 'Sample',
                  pageUrl: '${hosts[1]}/cn/open-sample-001',
                ),
                includeAccountState: false,
              )
              .then((_) => detailDone = true)
              .ignore();
          _flushFakeAsync(async);
          expect(detailDone, isTrue);
          expect(adapter.requests.first.uri.origin, hosts[0]);
        });
      },
    );

    test('cancellation or starting details prevents the idle scan', () async {
      final detail = await _detailHtml();
      final adapter = _Adapter((request) {
        if (_isMirrorProbe(request)) return _response('<html></html>');
        return request.uri.path.endsWith('/open-sample-001')
            ? _response(detail)
            : _response('<main></main>');
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      fakeAsync((async) {
        client.initialize();
        _flushFakeAsync(async);

        client.scheduleBackgroundMirrorProbe();
        async.elapse(const Duration(milliseconds: 500));
        client.cancelBackgroundMirrorProbe();
        async.elapse(const Duration(seconds: 2));
        _flushFakeAsync(async);
        expect(adapter.requests, isEmpty);

        client.scheduleBackgroundMirrorProbe();
        var detailsDone = false;
        client
            .details(
              const VideoItem(
                id: 'open-sample-001',
                title: 'Sample',
                pageUrl: 'https://missav.ai/cn/open-sample-001',
              ),
              includeAccountState: false,
            )
            .then((_) => detailsDone = true)
            .ignore();
        _flushFakeAsync(async);
        async.elapse(const Duration(seconds: 2));
        _flushFakeAsync(async);

        expect(detailsDone, isTrue);
        expect(adapter.requests.where(_isMirrorProbe), isEmpty);
      });
    });

    test('does not probe while a saved session is unresolved', () async {
      final adapter = _Adapter((_) => _response('<html></html>'));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage()..cookie = 'session=saved',
      );
      addTearDown(client.dispose);

      fakeAsync((async) {
        client.initialize();
        _flushFakeAsync(async);
        client.scheduleBackgroundMirrorProbe();
        async.elapse(const Duration(seconds: 2));
        _flushFakeAsync(async);
        expect(adapter.requests, isEmpty);
      });
    });
  });

  group('bound account origin', () {
    test('a failed login on another host keeps the saved session', () async {
      final storage = _MemorySecureStorage()
        ..values['iroru.missav_verified_session'] = jsonEncode({
          'cookie': 'session=saved',
          'userAgent': 'Saved Browser UA',
          'host': MissavClient.origin,
        });
      final adapter = _Adapter((request) {
        if (request.method == 'POST') {
          return _response('', statusCode: HttpStatus.unauthorized);
        }
        if (request.uri.host == 'missav.ws') {
          return _response(
            '<html></html>',
            headers: {
              'set-cookie': ['XSRF-TOKEN=attempt; Path=/; Secure'],
            },
          );
        }
        return _response('<main><h1>Saved</h1></main>');
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        metadataDio: _emptyMetadataDio(),
        secureStorage: storage,
      );
      addTearDown(client.dispose);
      await client.selectAccountHost('https://missav.ws');

      await expectLater(
        client.login(email: 'viewer@example.test', password: 'wrong'),
        throwsA(isA<MissavAuthenticationException>()),
      );
      await client.browse(client.collectionUrl('favorites'));

      expect(_cookieHeader(adapter.requests[0]), isEmpty);
      expect(_cookieHeader(adapter.requests[1]), 'XSRF-TOKEN=attempt');
      expect(adapter.requests.last.uri.origin, MissavClient.origin);
      expect(_cookieHeader(adapter.requests.last), 'session=saved');
      final record =
          jsonDecode(storage.values['iroru.missav_verified_session']!) as Map;
      expect(record['host'], MissavClient.origin);
      expect(record['cookie'], 'session=saved');
    });

    test(
      'native login saves the successful host and ignores a later preference',
      () async {
        SharedPreferences.setMockInitialValues({
          missavAccountBaseUrlKey: 'https://missav.ai',
        });
        final storage = _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D';
        final loginAdapter = _Adapter((request) {
          if (request.uri.host == 'missav.ws') {
            if (request.method == 'POST' &&
                request.uri.path.endsWith('/api/login')) {
              return _response(
                '{"user":{"name":"ws viewer"}}',
                headers: {
                  'set-cookie': ['session=ws; Path=/; Secure'],
                },
              );
            }
            return _response(
              '<html></html>',
              headers: {
                'set-cookie': ['XSRF-TOKEN=token%3D; Path=/; Secure'],
              },
            );
          }
          return _response('down', statusCode: HttpStatus.serviceUnavailable);
        });
        final client = MissavClient(
          dio: Dio()..httpClientAdapter = loginAdapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: storage,
        );
        addTearDown(client.dispose);

        await client.login(
          email: 'viewer@example.invalid',
          password: 'sample-password',
        );

        expect(client.accountHostUrl, 'https://missav.ws');
        final record =
            jsonDecode(storage.values['iroru.missav_verified_session']!) as Map;
        expect(record['host'], 'https://missav.ws');
        client.dispose();

        SharedPreferences.setMockInitialValues({
          missavAccountBaseUrlKey: 'https://missav.ai',
        });
        final requests = <RequestOptions>[];
        final restored = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter((request) {
              requests.add(request);
              if (request.uri.path == '/en/saved') {
                return _response(
                  '<body x-data="{user: {name: \'ws viewer\'}}"></body>',
                );
              }
              return request.uri.path.endsWith('/saved')
                  ? _response('<main><h1>Saved</h1></main>')
                  : _response(_searchCatalogHtml(['public']));
            }),
          metadataDio: _emptyMetadataDio(),
          secureStorage: storage,
        );
        addTearDown(restored.dispose);
        await restored.initialize();
        expect(restored.accountHostUrl, 'https://missav.ai');
        expect(await restored.restoreAccount(), isTrue);
        expect(restored.accountName, 'ws viewer');
        expect(requests.single.uri, Uri.parse('https://missav.ws/en/saved'));

        await restored.browse('https://missav.ai/cn/release');
        await restored.browse('https://missav.ws/cn/saved');

        final publicRequest = requests.firstWhere(
          (request) => request.uri.host == 'missav.ai',
        );
        final accountRequest = requests.firstWhere(
          (request) => request.uri.host == 'missav.ws',
        );
        expect(_cookieHeader(publicRequest), isEmpty);
        expect(_headerValue(publicRequest, 'X-XSRF-TOKEN'), isNull);
        expect(_cookieHeader(accountRequest), contains('session=ws'));
        expect(_headerValue(accountRequest, 'X-XSRF-TOKEN'), 'token=');
      },
    );

    test(
      'browser import binds missav.ai across restart and isolates its cookie',
      () async {
        SharedPreferences.setMockInitialValues({
          missavAccountBaseUrlKey: 'https://missav.ws',
        });
        final storage = _MemorySecureStorage();
        final requests = <RequestOptions>[];
        final adapter = _Adapter((request) {
          requests.add(request);
          return request.uri.path.endsWith('/saved')
              ? _response('<main><h1>Saved</h1></main>')
              : _response(_searchCatalogHtml(['public']));
        });
        final importing = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: storage,
        );
        addTearDown(importing.dispose);
        await importing.initialize();

        await importing.importVerifiedSession(
          cookieHeader: 'session=browser',
          userAgent: 'Browser UA',
        );

        final record =
            jsonDecode(storage.values['iroru.missav_verified_session']!) as Map;
        expect(record['host'], 'https://missav.ai');
        await importing.browse('https://missav.ws/cn/saved');
        expect(requests.single.uri.origin, 'https://missav.ai');
        expect(_cookieHeader(requests.single), 'session=browser');
        importing.dispose();

        requests.clear();
        final restored = MissavClient(
          dio: Dio()..httpClientAdapter = adapter,
          metadataDio: _emptyMetadataDio(),
          secureStorage: storage,
        );
        addTearDown(restored.dispose);
        await restored.initialize();

        await restored.browse('https://missav.ws/cn/saved');
        expect(requests.single.uri.origin, 'https://missav.ai');
        expect(_cookieHeader(requests.single), 'session=browser');

        requests.clear();
        await restored.browse('https://missav.ai/cn/release');
        await restored.browse('https://missav.ws/cn/release');
        expect(requests.map((request) => request.uri.origin), [
          'https://missav.ai',
          'https://missav.ws',
        ]);
        expect(_cookieHeader(requests[0]), 'session=browser');
        expect(_cookieHeader(requests[1]), isEmpty);
      },
    );

    for (final savedHost in [null, 'https://missav.ws']) {
      test('restores a legacy cookie with saved host $savedHost', () async {
        SharedPreferences.setMockInitialValues({
          if (savedHost != null) missavAccountBaseUrlKey: savedHost,
        });
        final storage = _MemorySecureStorage()..cookie = 'session=legacy';
        final requests = <RequestOptions>[];
        final client = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter((request) {
              requests.add(request);
              return request.uri.path.endsWith('/saved')
                  ? _response('<main><h1>Saved</h1></main>')
                  : _response(_searchCatalogHtml(['public']));
            }),
          metadataDio: _emptyMetadataDio(),
          secureStorage: storage,
        );
        addTearDown(client.dispose);
        await client.initialize();

        await client.browse('https://missav.ai/cn/saved');
        final expectedHost = savedHost ?? MissavClient.origin;
        final otherHost = savedHost == null
            ? MissavClient.accountHosts.first
            : MissavClient.origin;
        await client.browse('$otherHost/cn/release');

        expect(requests.map((request) => request.uri.origin), [
          expectedHost,
          otherHost,
        ]);
        expect(_cookieHeader(requests[0]), 'session=legacy');
        expect(_cookieHeader(requests[1]), isEmpty);
      });
    }
  });
}
