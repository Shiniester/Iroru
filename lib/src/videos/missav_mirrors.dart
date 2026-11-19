import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../services/proxy_config.dart';

const missavMirrorBaseUrlKey = 'missav_mirror_base_url';
const missavAccountBaseUrlKey = 'missav_account_base_url';
const missavLastGoodHostKey = 'missav_last_good_host';

const missavOfficialHosts = {'missav.ai', 'missav.ws', 'missav.live'};
const missavOfficialBaseUrls = [
  'https://missav.live',
  'https://missav.ws',
  'https://missav.ai',
];

class MissavMirror {
  const MissavMirror(this.host) : baseUrl = 'https://$host';

  final String host;
  final String baseUrl;
}

// Measured 2026-11-16; no Cloudflare challenge, fastest first.
// The cached last-good host is tried before this order.
const missavMirrors = <MissavMirror>[
  MissavMirror('www.missav05.com'),
  MissavMirror('www.missav02.net'),
  MissavMirror('www.thisav02.com'),
  MissavMirror('www.missav888.net'),
  MissavMirror('www.missav.watch'),
  MissavMirror('www.missav123.nl'),
  MissavMirror('www.missav01.net'),
  MissavMirror('www.missav123.life'),
  MissavMirror('www.thisav01.cc'),
  MissavMirror('www.thisav01.net'),
  MissavMirror('www.missav1.vip'),
  MissavMirror('www.njavtv.art'),
  MissavMirror('www.missav08.net'),
  MissavMirror('www.thisav.pw'),
  MissavMirror('www.missav666.net'),
  MissavMirror('www.missav365.one'),
  MissavMirror('www.missav666.cc'),
  MissavMirror('www.njav01.com'),
  MissavMirror('www.missav05.net'),
  MissavMirror('www.thisav.sbs'),
  MissavMirror('www.missav3.one'),
  MissavMirror('www.thisav33.net'),
  MissavMirror('www.njavtv01.com'),
  MissavMirror('www.thisav33.com'),
  MissavMirror('www.missav08.com'),
  MissavMirror('www.missav365.icu'),
  MissavMirror('www.missav1.one'),
  MissavMirror('www.thisav02.net'),
  MissavMirror('www.missav2.one'),
  MissavMirror('www.missav09.com'),
  MissavMirror('www.missav06.com'),
  MissavMirror('www.njav.one'),
  MissavMirror('www.missav9.net'),
  MissavMirror('www.njavtv.nl'),
];

String missavMirrorDomain(String host) =>
    host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

MissavMirror? missavMirrorForBaseUrl(String? baseUrl) {
  if (baseUrl == null || baseUrl.isEmpty) return null;
  final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  for (final mirror in missavMirrors) {
    if (mirror.baseUrl == normalized) return mirror;
  }
  return null;
}

class MissavMirrorLatency {
  const MissavMirrorLatency({
    required this.mirror,
    this.millis,
    this.error,
    this.isChallenge = false,
  });

  final MissavMirror mirror;
  final int? millis;
  final String? error;
  final bool isChallenge;

  bool get isAvailable => millis != null;
}

typedef MissavMirrorProbeCallback = void Function(MissavMirrorLatency result);

class MissavMirrorProber {
  MissavMirrorProber({Dio? dio, this.timeout = const Duration(seconds: 12)})
    : _dio = dio ?? _createDio();

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 10; K) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/149.0.0.0 Mobile Safari/537.36';
  final Dio _dio;
  final Duration timeout;

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 12),
        followRedirects: true,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()..findProxy = ProxyConfig.findProxyFor,
    );
    return dio;
  }

  Future<MissavMirrorLatency> probe(
    MissavMirror mirror, {
    CancelToken? cancelToken,
  }) => probeContent(
    mirror,
    '/cn',
    cancelToken: cancelToken,
    contentTimeout: timeout,
  );

  Future<MissavMirrorLatency> probeContent(
    MissavMirror mirror,
    String path, {
    CancelToken? cancelToken,
    Duration contentTimeout = const Duration(seconds: 8),
  }) async {
    var result = await _probeOnce(
      mirror,
      path,
      contentTimeout,
      cancelToken: cancelToken,
    );
    if (!result.isAvailable &&
        result.error == DioExceptionType.connectionError.name) {
      result = await _probeOnce(
        mirror,
        path,
        contentTimeout,
        cancelToken: cancelToken,
      );
    }
    return result;
  }

  Future<MissavMirrorLatency> _probeOnce(
    MissavMirror mirror,
    String path,
    Duration requestTimeout, {
    CancelToken? cancelToken,
  }) async {
    final separator = path.contains('?') ? '&' : '?';
    await ProxyConfig.ensureSystemProxyResolved();
    if (cancelToken?.cancelError case final error?) throw error;
    final requestToken = CancelToken();
    cancelToken?.whenCancel.then((error) => requestToken.cancel(error.error));
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio
          .get<String>(
            '${mirror.baseUrl}$path'
            '${separator}ts=${DateTime.now().millisecondsSinceEpoch}',
            cancelToken: requestToken,
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: true,
              receiveTimeout: requestTimeout,
              sendTimeout: requestTimeout,
              headers: {
                HttpHeaders.userAgentHeader: _userAgent,
                HttpHeaders.acceptHeader: 'text/plain,*/*',
                HttpHeaders.cacheControlHeader: 'no-cache',
              },
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 600,
            ),
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              requestToken.cancel();
              throw TimeoutException('MissAV mirror probe timed out.');
            },
          );
      stopwatch.stop();
      final body = (response.data ?? '').trim().toLowerCase();
      final challenge =
          response.headers.value('cf-mitigated')?.toLowerCase() ==
              'challenge' ||
          body.contains('just a moment') ||
          body.contains('_cf_chl_opt') ||
          body.contains('id="challenge-form"');
      final validBody = body.contains('<html');
      if (response.statusCode == HttpStatus.ok && validBody && !challenge) {
        return MissavMirrorLatency(
          mirror: mirror,
          millis: stopwatch.elapsedMilliseconds,
        );
      }
      return MissavMirrorLatency(
        mirror: mirror,
        error: 'HTTP ${response.statusCode}',
        isChallenge: challenge,
      );
    } on TimeoutException {
      return MissavMirrorLatency(mirror: mirror, error: 'timeout');
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      return MissavMirrorLatency(mirror: mirror, error: error.type.name);
    }
  }

  Future<List<MissavMirrorLatency>> probeAll(
    Iterable<MissavMirror> mirrors, {
    MissavMirrorProbeCallback? onResult,
    CancelToken? cancelToken,
    int concurrency = 3,
  }) async {
    final list = mirrors.toList(growable: false);
    final results = <MissavMirrorLatency>[];
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= list.length) return;
        final result = await probe(list[index], cancelToken: cancelToken);
        results.add(result);
        onResult?.call(result);
      }
    }

    final workers = concurrency < 1
        ? 1
        : concurrency > list.length
        ? list.length
        : concurrency;
    await Future.wait(
      List<Future<void>>.generate(workers, (_) => worker()),
      eagerError: true,
    );
    results.sort(
      (left, right) =>
          (left.millis ?? 1 << 30).compareTo(right.millis ?? 1 << 30),
    );
    return results;
  }
}
