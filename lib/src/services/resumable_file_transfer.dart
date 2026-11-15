import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'http_byte_range.dart';
import 'remote_asset_cache.dart';

typedef ResumableDownloadProgress =
    void Function(int receivedBytes, int? totalBytes);

class ResumableFileTransferResult {
  const ResumableFileTransferResult({required this.totalBytes});

  final int totalBytes;
}

class ResumableFileTransfer {
  ResumableFileTransfer({RemoteAssetTransport? transport})
    : _transport = transport ?? HttpRemoteAssetTransport();

  final RemoteAssetTransport _transport;

  /// Resumes only when the stored source matches [sourceIdentity], or the
  /// canonical URL when no stable identity is supplied.
  Future<ResumableFileTransferResult> download({
    required Uri uri,
    required File partialFile,
    required RemoteAssetCancellation cancellation,
    Map<String, String> headers = const {},
    String? sourceIdentity,
    bool expectedAudio = false,
    ResumableDownloadProgress? onProgress,
  }) async {
    final markerFile = _sourceMarkerFile(partialFile);
    final sourceId = sourceIdentity ?? RemoteAssetKey.canonicalUri(uri);
    var prefixLength = await partialFile.exists()
        ? await partialFile.length()
        : 0;
    var sourceMarker = prefixLength > 0
        ? await _readSourceMarker(markerFile)
        : null;
    if (prefixLength > 0 &&
        (sourceMarker == null || sourceMarker.source != sourceId)) {
      await partialFile.delete();
      await _deleteSourceMarker(markerFile);
      prefixLength = 0;
      sourceMarker = null;
    } else if (prefixLength == 0) {
      await _deleteSourceMarker(markerFile);
    }
    final hasStrongValidator =
        _isStrongEtag(sourceMarker?.etag) ||
        (sourceMarker?.lastModified?.trim().isNotEmpty ?? false);
    if (prefixLength > 0 && !hasStrongValidator) {
      final matches = await _prefixMatches(
        uri: uri,
        partialFile: partialFile,
        length: prefixLength,
        headers: headers,
        cancellation: cancellation,
      );
      if (!matches) {
        await partialFile.delete();
        await _deleteSourceMarker(markerFile);
        prefixLength = 0;
        sourceMarker = null;
      }
    }
    final ifRange = prefixLength > 0
        ? (_isStrongEtag(sourceMarker?.etag)
              ? sourceMarker!.etag
              : sourceMarker?.lastModified)
        : null;
    final requestHeaders = <String, String>{
      ...headers,
      'Accept-Encoding': 'identity',
      if (prefixLength > 0) 'Range': 'bytes=$prefixLength-',
      if (ifRange != null) 'If-Range': ifRange,
    };
    final response = await _transport.open(
      RemoteAssetTransportRequest(
        uri: uri,
        headers: requestHeaders,
        cancellation: cancellation,
      ),
    );

    late final ByteRangeResponsePlan plan;
    try {
      plan = resolveByteRangeResponse(
        statusCode: response.statusCode,
        requestedStart: prefixLength,
        contentLength: response.contentLength,
        contentRange: response.header(HttpHeaders.contentRangeHeader),
      );
    } on FormatException {
      await response.stream.drain<void>();
      if (await partialFile.exists()) await partialFile.delete();
      await _deleteSourceMarker(markerFile);
      rethrow;
    } on HttpException {
      // Server failures do not invalidate a previously verified prefix.
      await response.stream.drain<void>();
      rethrow;
    }
    if (plan.kind == ByteRangeResponseKind.partial &&
        prefixLength > 0 &&
        sourceMarker?.length != null &&
        plan.sourceLength != null &&
        sourceMarker!.length != plan.sourceLength) {
      await response.stream.drain<void>();
      await partialFile.delete();
      await _deleteSourceMarker(markerFile);
      return download(
        uri: uri,
        partialFile: partialFile,
        cancellation: cancellation,
        headers: headers,
        sourceIdentity: sourceIdentity,
        expectedAudio: expectedAudio,
        onProgress: onProgress,
      );
    }
    final contentType = response
        .header(HttpHeaders.contentTypeHeader)
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (plan.kind == ByteRangeResponseKind.alreadyComplete) {
      await response.stream.drain<void>();
      await _deleteSourceMarker(markerFile);
      return ResumableFileTransferResult(totalBytes: prefixLength);
    }
    if (expectedAudio && contentType == 'text/html') {
      await response.stream.drain<void>();
      throw const HttpException('Unexpected HTML download response');
    }

    final iterator = StreamIterator<List<int>>(response.stream);
    final initialChunks = <List<int>>[];
    var initialByteCount = 0;
    if (expectedAudio) {
      try {
        while (initialByteCount < 64 && await iterator.moveNext()) {
          if (cancellation.isCancelled) {
            throw const HttpException('File transfer cancelled');
          }
          final chunk = iterator.current;
          initialChunks.add(chunk);
          initialByteCount += chunk.length;
        }
      } catch (_) {
        await iterator.cancel();
        rethrow;
      }
      if (_looksLikeHtml(initialChunks)) {
        await iterator.cancel();
        throw const HttpException('Unexpected HTML download response');
      }
    }

    final append = plan.kind == ByteRangeResponseKind.partial;
    final retainedPrefix = append ? prefixLength : 0;
    final markerToWrite = _DownloadSourceMarker(
      source: sourceId,
      etag: response.header(HttpHeaders.etagHeader) ?? sourceMarker?.etag,
      lastModified:
          response.header(HttpHeaders.lastModifiedHeader) ??
          sourceMarker?.lastModified,
      length: plan.sourceLength ?? sourceMarker?.length,
    );
    late final RandomAccessFile output;
    RandomAccessFile? openedOutput;
    try {
      await partialFile.parent.create(recursive: true);
      openedOutput = await partialFile.open(
        mode: append ? FileMode.writeOnlyAppend : FileMode.write,
      );
      await _writeSourceMarker(markerFile, markerToWrite);
      output = openedOutput;
    } catch (_) {
      await openedOutput?.close();
      await iterator.cancel();
      rethrow;
    }
    var received = 0;
    var structurallyInvalid = false;

    Future<void> writeChunk(List<int> chunk) async {
      if (cancellation.isCancelled) {
        throw const HttpException('File transfer cancelled');
      }
      final nextReceived = received + chunk.length;
      if (plan.responseLength != null && nextReceived > plan.responseLength!) {
        structurallyInvalid = true;
        throw const FormatException('Byte range exceeded its declared length');
      }
      await output.writeFrom(chunk);
      received = nextReceived;
      onProgress?.call(retainedPrefix + received, plan.sourceLength);
    }

    try {
      for (final chunk in initialChunks) {
        await writeChunk(chunk);
      }
      while (await iterator.moveNext()) {
        await writeChunk(iterator.current);
      }
      await output.flush();
    } finally {
      await iterator.cancel();
      await output.close();
      if (structurallyInvalid) {
        if (await partialFile.exists()) await partialFile.delete();
        await _deleteSourceMarker(markerFile);
      }
    }
    if (plan.responseLength != null && received != plan.responseLength) {
      throw const HttpException('File transfer ended before declared length');
    }
    final actualLength = await partialFile.length();
    final totalLength = plan.sourceLength ?? actualLength;
    if (actualLength != totalLength) {
      throw const HttpException('File transfer is incomplete');
    }
    await _deleteSourceMarker(markerFile);
    return ResumableFileTransferResult(totalBytes: totalLength);
  }

  Future<bool> _prefixMatches({
    required Uri uri,
    required File partialFile,
    required int length,
    required Map<String, String> headers,
    required RemoteAssetCancellation cancellation,
  }) async {
    final probeLength = length < 64 ? length : 64;
    final response = await _transport.open(
      RemoteAssetTransportRequest(
        uri: uri,
        headers: {
          ...headers,
          'Range': 'bytes=0-${probeLength - 1}',
          'Accept-Encoding': 'identity',
        },
        cancellation: cancellation,
      ),
    );
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      await response.stream.listen((_) {}).cancel();
      return true;
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.stream.listen((_) {}).cancel();
      throw HttpException('Source prefix probe failed: ${response.statusCode}');
    }
    final iterator = StreamIterator<List<int>>(response.stream);
    final probe = <int>[];
    try {
      while (probe.length < probeLength && await iterator.moveNext()) {
        probe.addAll(iterator.current);
      }
    } finally {
      await iterator.cancel();
    }
    if (_looksLikeHtml([probe])) {
      throw const HttpException('Unexpected HTML download response');
    }
    if (probe.length < probeLength) return false;
    final handle = await partialFile.open();
    try {
      final prefix = await handle.read(probeLength);
      if (prefix.length != probeLength) return false;
      for (var index = 0; index < probeLength; index++) {
        if (prefix[index] != probe[index]) return false;
      }
      return true;
    } finally {
      await handle.close();
    }
  }

  bool _looksLikeHtml(List<List<int>> chunks) {
    final prefix = <int>[];
    for (final chunk in chunks) {
      prefix.addAll(chunk);
      if (prefix.length >= 128) break;
    }
    final text = ascii
        .decode(prefix, allowInvalid: true)
        .trimLeft()
        .toLowerCase();
    return text.startsWith('<!doctype html') ||
        text.startsWith('<html') ||
        text.startsWith('<head') ||
        text.startsWith('<body');
  }
}

bool _isStrongEtag(String? etag) {
  if (etag == null) return false;
  final value = etag.trimLeft();
  return value.isNotEmpty && !value.toUpperCase().startsWith('W/');
}

class _DownloadSourceMarker {
  const _DownloadSourceMarker({
    required this.source,
    this.etag,
    this.lastModified,
    this.length,
  });

  final String source;
  final String? etag;
  final String? lastModified;
  final int? length;

  factory _DownloadSourceMarker.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    if (source is! String || source.isEmpty) {
      throw const FormatException('Invalid download source marker');
    }
    return _DownloadSourceMarker(
      source: source,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      length: (json['length'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    if (etag != null) 'etag': etag,
    if (lastModified != null) 'lastModified': lastModified,
    if (length != null) 'length': length,
  };
}

File _sourceMarkerFile(File partialFile) {
  return File(
    p.join(partialFile.parent.path, '.${p.basename(partialFile.path)}.source'),
  );
}

Future<_DownloadSourceMarker?> _readSourceMarker(File file) async {
  if (!await file.exists()) return null;
  try {
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) return null;
    return _DownloadSourceMarker.fromJson(value);
  } catch (_) {
    return null;
  }
}

Future<void> _writeSourceMarker(File file, _DownloadSourceMarker marker) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(marker.toJson()), flush: true);
}

Future<void> _deleteSourceMarker(File file) async {
  if (await file.exists()) await file.delete();
}
