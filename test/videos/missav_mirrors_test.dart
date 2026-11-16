import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_mirrors.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  test('keeps only healthy mirrors and sorts them by latency', () async {
    const mirrors = [
      MissavMirror('www.missav9.net'),
      MissavMirror('www.thisav02.com'),
      MissavMirror('www.njav.one'),
      MissavMirror('www.missav1.one'),
    ];
    final adapter = _Adapter((request) async {
      switch (request.uri.host) {
        case 'www.missav9.net':
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return ResponseBody.fromString('<html></html>', HttpStatus.ok);
        case 'www.thisav02.com':
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return ResponseBody.fromString('<html></html>', HttpStatus.ok);
        case 'www.njav.one':
          return ResponseBody.fromString(
            '<title>Just a moment...</title>',
            HttpStatus.forbidden,
            headers: {
              'cf-mitigated': ['challenge'],
            },
          );
        default:
          return ResponseBody.fromString('error', HttpStatus.badGateway);
      }
    });
    final prober = MissavMirrorProber(
      dio: Dio()..httpClientAdapter = adapter,
      timeout: const Duration(seconds: 1),
    );
    final seen = <String>[];

    final results = await prober.probeAll(
      mirrors,
      onResult: (result) => seen.add(result.mirror.host),
    );

    expect(seen, hasLength(mirrors.length));
    expect(
      results
          .where((result) => result.isAvailable)
          .map((result) => result.mirror.host),
      ['www.missav9.net', 'www.thisav02.com'],
    );
    expect(results.first.millis, lessThan(results[1].millis!));
    expect(
      results
          .where((result) => !result.isAvailable)
          .every((result) => result.error != null),
      isTrue,
    );
  });

  test('rejects a mirror when the homepage is not HTML', () async {
    const mirrors = [
      MissavMirror('www.missav9.net'),
      MissavMirror('www.thisav02.com'),
    ];
    final adapter = _Adapter((request) {
      if (request.uri.host == 'www.missav9.net') {
        return ResponseBody.fromString('error', HttpStatus.serviceUnavailable);
      }
      return ResponseBody.fromString('ok', HttpStatus.ok);
    });
    final prober = MissavMirrorProber(
      dio: Dio()..httpClientAdapter = adapter,
      timeout: const Duration(seconds: 1),
    );

    final results = await prober.probeAll(mirrors);

    expect(results.every((result) => !result.isAvailable), isTrue);
  });

  test('resolves saved mirror base URLs', () {
    final mirror = missavMirrorForBaseUrl('https://www.missav9.net/');

    expect(mirror?.host, 'www.missav9.net');
    expect(missavMirrorForBaseUrl('https://unknown.example'), isNull);
    expect(missavMirrorForBaseUrl(null), isNull);
  });

  test('mirror catalog has unique HTTPS hosts', () {
    final hosts = missavMirrors.map((mirror) => mirror.host).toSet();

    expect(hosts, hasLength(missavMirrors.length));
    expect(
      missavMirrors.every((mirror) => mirror.baseUrl.startsWith('https://')),
      isTrue,
    );
    expect(missavAutomaticMirrors.every(missavMirrors.contains), isTrue);
  });
}
