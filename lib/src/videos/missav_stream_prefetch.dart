import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/proxy_config.dart';
import 'video_models.dart';

Future<VideoStream> resolveMissavMirrorStreamStart(VideoStream stream) =>
    MissavStreamPrefetch(stream).resolve();

/// Resolves the first mirror HLS redirect before the native player opens it.
/// The result is optional; cancellation and failures keep the original URL.
class MissavStreamPrefetch {
  MissavStreamPrefetch(this.stream);

  final VideoStream stream;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = _deadline
    ..findProxy = ProxyConfig.findProxyFor;
  Future<VideoStream>? _resolution;
  bool _cancelled = false;
  bool _closed = false;

  static const _deadline = Duration(milliseconds: 1400);

  Future<VideoStream> resolve() {
    return _resolution ??= _cancelled ? Future.value(stream) : _resolve();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _close();
  }

  Future<VideoStream> _resolve() async {
    final uri = Uri.tryParse(stream.url);
    if (!stream.isHls || uri == null || !uri.pathSegments.contains('jmpres')) {
      _close();
      return stream;
    }
    final watch = Stopwatch()..start();
    Duration remaining() {
      final value = _deadline - watch.elapsed;
      return value.isNegative ? Duration.zero : value;
    }

    try {
      var resolved = uri;
      for (var redirect = 0; redirect <= 5; redirect++) {
        if (_cancelled) return stream;
        final request = await _client.getUrl(resolved).timeout(remaining());
        request.followRedirects = false;
        stream.headers.forEach(request.headers.set);
        final response = await request.close().timeout(remaining());
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (response.isRedirect && location != null) {
          await response.drain<void>().timeout(remaining());
          resolved = resolved.resolve(location);
          continue;
        }
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          await response.drain<void>().timeout(remaining());
          return stream;
        }
        if (!await _hasHlsPrefix(response, remaining)) return stream;
        if (resolved == uri) return stream;
        return VideoStream(
          label: stream.label,
          url: resolved.toString(),
          headers: stream.headers,
          isHls: stream.isHls,
        );
      }
      return stream;
    } catch (_) {
      return stream;
    } finally {
      _close();
    }
  }

  Future<bool> _hasHlsPrefix(
    HttpClientResponse response,
    Duration Function() remaining,
  ) async {
    final bytes = <int>[];
    final iterator = StreamIterator<List<int>>(response);
    try {
      while (bytes.length < 7) {
        if (!await iterator.moveNext().timeout(remaining())) break;
        bytes.addAll(iterator.current);
      }
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {}
    }
    return utf8
        .decode(bytes.take(7).toList(), allowMalformed: true)
        .startsWith('#EXTM3U');
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}
