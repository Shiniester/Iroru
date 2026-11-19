import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/services/remote_asset_cache.dart';
import 'package:iroru/src/services/resumable_file_transfer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_resumable_file_transfer_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('resumes a download after the existing contiguous prefix', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(
      partial,
      const [1, 2],
      Uri.parse('https://example.com/track.mp3'),
      etag: '"v1"',
    );
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.partialContent,
        contentLength: 3,
        headers: {'content-range': 'bytes 2-4/5'},
        stream: Stream.empty(),
      ),
      body: const [3, 4, 5],
    );
    final transfer = ResumableFileTransfer(transport: transport);

    final result = await transfer.download(
      uri: Uri.parse('https://example.com/track.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.request!.headers['Range'], 'bytes=2-');
    expect(transport.request!.headers['If-Range'], '"v1"');
    expect(transport.request!.headers['Accept-Encoding'], 'identity');
    expect(result.totalBytes, 5);
    expect(await partial.readAsBytes(), const [1, 2, 3, 4, 5]);
  });

  test('a server that ignores Range safely replaces the old prefix', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [
      1,
      2,
    ], Uri.parse('https://example.com/track.mp3'));
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: 4,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [9, 8, 7, 6],
    );

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/track.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(result.totalBytes, 4);
    expect(await partial.readAsBytes(), const [9, 8, 7, 6]);
  });

  test('a temporary server failure retains the resumable prefix', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [
      1,
      2,
    ], Uri.parse('https://example.com/track.mp3'));
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.serviceUnavailable,
        contentLength: 0,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [],
    );

    await expectLater(
      ResumableFileTransfer(transport: transport).download(
        uri: Uri.parse('https://example.com/track.mp3'),
        partialFile: partial,
        cancellation: RemoteAssetCancellation(),
      ),
      throwsA(isA<HttpException>()),
    );

    expect(await partial.readAsBytes(), const [1, 2]);
  });

  test(
    'an HTML redirect page is rejected without replacing the prefix',
    () async {
      final partial = File('${tempDirectory.path}/track.m4a.downloading');
      await _seedPrefix(partial, const [
        1,
        2,
      ], Uri.parse('https://example.com/track.m4a'));
      final transport = _TransferTransport(
        const RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 20,
          headers: {'content-type': 'text/html; charset=utf-8'},
          stream: Stream.empty(),
        ),
        body: const [60, 104, 116, 109, 108],
      );

      await expectLater(
        ResumableFileTransfer(transport: transport).download(
          uri: Uri.parse('https://example.com/track.m4a'),
          partialFile: partial,
          cancellation: RemoteAssetCancellation(),
          expectedAudio: true,
        ),
        throwsA(isA<HttpException>()),
      );

      expect(await partial.readAsBytes(), const [1, 2]);
    },
  );

  test(
    'an HTML body with a misleading content type is rejected for audio',
    () async {
      final partial = File('${tempDirectory.path}/track.m4a.downloading');
      await _seedPrefix(partial, const [
        1,
        2,
      ], Uri.parse('https://example.com/track.m4a'));
      final body = '<!doctype html><html>error</html>'.codeUnits;
      final transport = _TransferTransport(
        RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: body.length,
          headers: {'content-type': 'application/octet-stream'},
          stream: const Stream.empty(),
        ),
        body: body,
      );

      await expectLater(
        ResumableFileTransfer(transport: transport).download(
          uri: Uri.parse('https://example.com/track.m4a'),
          partialFile: partial,
          cancellation: RemoteAssetCancellation(),
          expectedAudio: true,
        ),
        throwsA(isA<HttpException>()),
      );

      expect(await partial.readAsBytes(), const [1, 2]);
    },
  );

  test('HTML assets remain downloadable when audio is not expected', () async {
    final partial = File('${tempDirectory.path}/lyrics.html.downloading');
    final body = '<html>lyrics</html>'.codeUnits;
    final transport = _TransferTransport(
      RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: body.length,
        headers: {'content-type': 'text/html'},
        stream: const Stream.empty(),
      ),
      body: body,
    );

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/lyrics.html'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(result.totalBytes, body.length);
    expect(await partial.readAsBytes(), body);
  });

  test('resumes HTML without validators', () async {
    final uri = Uri.parse('https://example.com/lyrics.html');
    final partial = File('${tempDirectory.path}/lyrics.html.downloading');
    final prefix = '<html>lyrics'.codeUnits;
    final suffix = '</html>'.codeUnits;
    final total = prefix.length + suffix.length;
    await _seedPrefix(partial, prefix, uri, noValidator: true);
    final transport = _SequenceTransport([
      (
        RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: prefix.length,
          headers: {
            'content-type': 'text/html',
            'content-range': 'bytes 0-${prefix.length - 1}/$total',
          },
          stream: const Stream.empty(),
        ),
        prefix,
      ),
      (
        RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: suffix.length,
          headers: {
            'content-type': 'text/html',
            'content-range': 'bytes ${prefix.length}-${total - 1}/$total',
          },
          stream: const Stream.empty(),
        ),
        suffix,
      ),
    ]);

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: uri,
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.requests.map((request) => request.headers['Range']), [
      'bytes=0-${prefix.length - 1}',
      'bytes=${prefix.length}-',
    ]);
    expect(result.totalBytes, total);
    expect(await partial.readAsString(), '<html>lyrics</html>');
  });

  test('a complete prefix accepts the 416 HTML range response', () async {
    final partial = File('${tempDirectory.path}/track.m4a.downloading');
    await _seedPrefix(partial, const [
      1,
      2,
    ], Uri.parse('https://example.com/track.m4a'));
    final body = '<html>range not satisfiable</html>'.codeUnits;
    final transport = _TransferTransport(
      RemoteAssetResponse(
        statusCode: HttpStatus.requestedRangeNotSatisfiable,
        contentLength: body.length,
        headers: {'content-range': 'bytes */2', 'content-type': 'text/html'},
        stream: const Stream.empty(),
      ),
      body: body,
    );

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/track.m4a'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
      expectedAudio: true,
    );

    expect(result.totalBytes, 2);
    expect(await partial.readAsBytes(), const [1, 2]);
  });

  test('restarts when a partial has no source marker', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await partial.writeAsBytes(const [1, 2]);
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: 4,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [9, 8, 7, 6],
    );

    await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/track.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.request!.headers['Range'], isNull);
    expect(await partial.readAsBytes(), const [9, 8, 7, 6]);
  });

  test('restarts when the source URL changed', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [
      1,
      2,
    ], Uri.parse('https://example.com/old.mp3'));
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: 4,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [9, 8, 7, 6],
    );

    await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/new.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.request!.headers['Range'], isNull);
    expect(await partial.readAsBytes(), const [9, 8, 7, 6]);
  });

  test('restarts when the source length changed', () async {
    final uri = Uri.parse('https://example.com/track.mp3');
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [1, 2], uri, length: 5);
    final transport = _SequenceTransport([
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 2,
          headers: {'content-range': 'bytes 2-3/4'},
          stream: Stream.empty(),
        ),
        const [3, 4],
      ),
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 4,
          headers: {},
          stream: Stream.empty(),
        ),
        const [9, 8, 7, 6],
      ),
    ]);

    await ResumableFileTransfer(transport: transport).download(
      uri: uri,
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.headers['Range'], 'bytes=2-');
    expect(transport.requests.last.headers['Range'], isNull);
    expect(await partial.readAsBytes(), const [9, 8, 7, 6]);
  });

  test('resumes when the URL changes but the identity is stable', () async {
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(
      partial,
      const [1, 2],
      Uri.parse('https://example.com/old.mp3'),
      identity: 'track-1',
    );
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.partialContent,
        contentLength: 3,
        headers: {'content-range': 'bytes 2-4/5'},
        stream: Stream.empty(),
      ),
      body: const [3, 4, 5],
    );

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: Uri.parse('https://example.com/new.mp3'),
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
      sourceIdentity: 'track-1',
    );

    expect(transport.request!.headers['Range'], 'bytes=2-');
    expect(result.totalBytes, 5);
    expect(await partial.readAsBytes(), const [1, 2, 3, 4, 5]);
  });

  test('restarts when the source identity changes', () async {
    final uri = Uri.parse('https://example.com/track.mp3');
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [1, 2], uri, identity: 'old');
    final transport = _TransferTransport(
      const RemoteAssetResponse(
        statusCode: HttpStatus.ok,
        contentLength: 4,
        headers: {},
        stream: Stream.empty(),
      ),
      body: const [9, 8, 7, 6],
    );

    await ResumableFileTransfer(transport: transport).download(
      uri: uri,
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
      sourceIdentity: 'new',
    );

    expect(transport.request!.headers['Range'], isNull);
    expect(await partial.readAsBytes(), const [9, 8, 7, 6]);
  });

  test('restarts a no-validator prefix whose first bytes changed', () async {
    final uri = Uri.parse('https://example.com/track.mp3');
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [1, 2], uri, noValidator: true);
    final transport = _SequenceTransport([
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 2,
          headers: {'content-range': 'bytes 0-1/4'},
          stream: Stream.empty(),
        ),
        const [9, 9],
      ),
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.ok,
          contentLength: 4,
          headers: {},
          stream: Stream.empty(),
        ),
        const [9, 9, 9, 9],
      ),
    ]);

    await ResumableFileTransfer(transport: transport).download(
      uri: uri,
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.headers['Range'], 'bytes=0-1');
    expect(transport.requests.last.headers['Range'], isNull);
    expect(await partial.readAsBytes(), const [9, 9, 9, 9]);
  });

  test('resumes a no-validator prefix whose first bytes match', () async {
    final uri = Uri.parse('https://example.com/track.mp3');
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [1, 2], uri, noValidator: true);
    final transport = _SequenceTransport([
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 2,
          headers: {'content-range': 'bytes 0-1/5'},
          stream: Stream.empty(),
        ),
        const [1, 2],
      ),
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 3,
          headers: {'content-range': 'bytes 2-4/5'},
          stream: Stream.empty(),
        ),
        const [3, 4, 5],
      ),
    ]);

    final result = await ResumableFileTransfer(transport: transport).download(
      uri: uri,
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.headers['Range'], 'bytes=0-1');
    expect(transport.requests.last.headers['Range'], 'bytes=2-');
    expect(result.totalBytes, 5);
    expect(await partial.readAsBytes(), const [1, 2, 3, 4, 5]);
  });

  test('a weak ETag uses the prefix probe instead of If-Range', () async {
    final uri = Uri.parse('https://example.com/track.mp3');
    final partial = File('${tempDirectory.path}/track.mp3.downloading');
    await _seedPrefix(partial, const [1, 2], uri, etag: 'W/"v1"');
    final transport = _SequenceTransport([
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 2,
          headers: {'content-range': 'bytes 0-1/5'},
          stream: Stream.empty(),
        ),
        const [1, 2],
      ),
      (
        const RemoteAssetResponse(
          statusCode: HttpStatus.partialContent,
          contentLength: 3,
          headers: {'content-range': 'bytes 2-4/5'},
          stream: Stream.empty(),
        ),
        const [3, 4, 5],
      ),
    ]);

    await ResumableFileTransfer(transport: transport).download(
      uri: uri,
      partialFile: partial,
      cancellation: RemoteAssetCancellation(),
    );

    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.headers['If-Range'], isNull);
    expect(transport.requests.last.headers['If-Range'], isNull);
    expect(await partial.readAsBytes(), const [1, 2, 3, 4, 5]);
  });
}

Future<void> _seedPrefix(
  File partial,
  List<int> bytes,
  Uri uri, {
  String? etag,
  String? lastModified,
  int? length,
  String? identity,
  bool noValidator = false,
}) async {
  await partial.parent.create(recursive: true);
  await partial.writeAsBytes(bytes);
  final marker = File(
    p.join(partial.parent.path, '.${p.basename(partial.path)}.source'),
  );
  final markerEtag =
      etag ?? (lastModified == null && !noValidator ? '"seed"' : null);
  await marker.writeAsString(
    jsonEncode({
      'source': identity ?? RemoteAssetKey.canonicalUri(uri),
      if (markerEtag != null) 'etag': markerEtag,
      if (lastModified != null) 'lastModified': lastModified,
      if (length != null) 'length': length,
    }),
  );
}

class _TransferTransport implements RemoteAssetTransport {
  _TransferTransport(this.response, {required this.body});

  final RemoteAssetResponse response;
  final List<int> body;
  RemoteAssetTransportRequest? request;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    this.request = request;
    return RemoteAssetResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      stream: Stream.value(body),
    );
  }
}

class _SequenceTransport implements RemoteAssetTransport {
  _SequenceTransport(this._responses);

  final List<(RemoteAssetResponse, List<int>)> _responses;
  final List<RemoteAssetTransportRequest> requests = [];

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    requests.add(request);
    final response = _responses[requests.length - 1];
    return RemoteAssetResponse(
      statusCode: response.$1.statusCode,
      contentLength: response.$1.contentLength,
      headers: response.$1.headers,
      stream: Stream.value(response.$2),
    );
  }
}
