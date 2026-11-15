import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../services/proxy_config.dart';

const missavMirrorBaseUrlKey = 'missav_mirror_base_url';

class MissavMirror {
  const MissavMirror(this.host) : baseUrl = 'https://$host';

  final String host;
  final String baseUrl;
}

const missavMirrors = <MissavMirror>[
  MissavMirror('www.missav.watch'),
  MissavMirror('www.missav01.net'),
  MissavMirror('www.missav02.net'),
  MissavMirror('www.missav05.com'),
  MissavMirror('www.missav05.net'),
  MissavMirror('www.missav06.com'),
  MissavMirror('www.missav08.com'),
  MissavMirror('www.missav08.net'),
  MissavMirror('www.missav09.com'),
  MissavMirror('www.missav1.one'),
  MissavMirror('www.missav1.vip'),
  MissavMirror('www.missav123.life'),
  MissavMirror('www.missav123.nl'),
  MissavMirror('www.missav2.one'),
  MissavMirror('www.missav3.one'),
  MissavMirror('www.missav365.icu'),
  MissavMirror('www.missav365.one'),
  MissavMirror('www.missav666.cc'),
  MissavMirror('www.missav666.net'),
  MissavMirror('www.missav888.net'),
  MissavMirror('www.missav9.net'),
  MissavMirror('www.njav.one'),
  MissavMirror('www.njav01.com'),
  MissavMirror('www.njavtv.art'),
  MissavMirror('www.njavtv.nl'),
  MissavMirror('www.njavtv01.com'),
  MissavMirror('www.thisav.pw'),
  MissavMirror('www.thisav.sbs'),
  MissavMirror('www.thisav01.cc'),
  MissavMirror('www.thisav01.net'),
  MissavMirror('www.thisav02.com'),
  MissavMirror('www.thisav02.net'),
  MissavMirror('www.thisav33.com'),
  MissavMirror('www.thisav33.net'),
];

const _automaticHosts = {
  'www.missav01.net',
  'www.missav666.cc',
  'www.thisav.pw',
  'www.missav9.net',
  'www.njavtv.nl',
};

final missavAutomaticMirrors = missavMirrors
    .where((mirror) => _automaticHosts.contains(mirror.host))
    .toList(growable: false);

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
  const MissavMirrorLatency({required this.mirror, this.millis, this.error});

  final MissavMirror mirror;
  final int? millis;
  final String? error;

  bool get isAvailable => millis != null;
}

typedef MissavMirrorProbeCallback = void Function(MissavMirrorLatency result);

class MissavMirrorProber {
  MissavMirrorProber({Dio? dio, this.timeout = const Duration(seconds: 3)})
    : _dio = dio ?? _createDio();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/149.0.0.0 Safari/537.36';
  final Dio _dio;
  final Duration timeout;

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        sendTimeout: const Duration(seconds: 3),
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
  }) async {
    var result = await _probeOnce(
      mirror,
      '/status.html',
      timeout,
      requireOkBody: true,
      cancelToken: cancelToken,
    );
    if (!result.isAvailable &&
        result.error == DioExceptionType.connectionError.name) {
      result = await _probeOnce(
        mirror,
        '/status.html',
        timeout,
        requireOkBody: true,
        cancelToken: cancelToken,
      );
    }
    return result;
  }

  Future<MissavMirrorLatency> probeContent(
    MissavMirror mirror,
    String path, {
    CancelToken? cancelToken,
    Duration contentTimeout = const Duration(seconds: 5),
  }) async {
    var result = await _probeOnce(
      mirror,
      path,
      contentTimeout,
      requireOkBody: false,
      cancelToken: cancelToken,
    );
    if (!result.isAvailable &&
        result.error == DioExceptionType.connectionError.name) {
      result = await _probeOnce(
        mirror,
        path,
        contentTimeout,
        requireOkBody: false,
        cancelToken: cancelToken,
      );
    }
    return result;
  }

  Future<MissavMirrorLatency> _probeOnce(
    MissavMirror mirror,
    String path,
    Duration requestTimeout, {
    required bool requireOkBody,
    CancelToken? cancelToken,
  }) async {
    final separator = path.contains('?') ? '&' : '?';
    await ProxyConfig.ensureSystemProxyResolved();
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio
          .get<String>(
            '${mirror.baseUrl}$path'
            '${separator}ts=${DateTime.now().millisecondsSinceEpoch}',
            cancelToken: cancelToken,
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
          .timeout(requestTimeout);
      stopwatch.stop();
      final body = (response.data ?? '').trim().toLowerCase();
      final challenge =
          response.headers.value('cf-mitigated')?.toLowerCase() ==
              'challenge' ||
          body.contains('just a moment') ||
          body.contains('_cf_chl_opt') ||
          body.contains('id="challenge-form"');
      final validBody = requireOkBody ? body == 'ok' : body.contains('<html');
      if (response.statusCode == HttpStatus.ok && validBody && !challenge) {
        return MissavMirrorLatency(
          mirror: mirror,
          millis: stopwatch.elapsedMilliseconds,
        );
      }
      return MissavMirrorLatency(
        mirror: mirror,
        error: 'HTTP ${response.statusCode}',
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
    int concurrency = 6,
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
