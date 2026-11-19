import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/services/audio_file_signature.dart';

void main() {
  test('detects supported audio containers', () {
    final oggHeader = List<int>.filled(27, 0);
    oggHeader.setAll(0, const [0x4f, 0x67, 0x67, 0x53]);

    expect(
      audioExtensionFromHeader(const [
        0x00,
        0x00,
        0x00,
        0x1c,
        0x66,
        0x74,
        0x79,
        0x70,
        0x4d,
        0x34,
        0x41,
        0x20,
      ]),
      '.m4a',
    );
    expect(
      audioExtensionFromHeader(const [
        0x52,
        0x49,
        0x46,
        0x46,
        0x00,
        0x00,
        0x00,
        0x00,
        0x57,
        0x41,
        0x56,
        0x45,
      ]),
      '.wav',
    );
    expect(audioExtensionFromHeader(const [0x66, 0x4c, 0x61, 0x43]), '.flac');
    expect(audioExtensionFromHeader(const [0x49, 0x44, 0x33, 0x04]), '.mp3');
    expect(
      audioExtensionFromHeader([...oggHeader, ...'OpusHead'.codeUnits]),
      '.opus',
    );
    expect(audioExtensionFromHeader(const [0, 1, 2]), isNull);
  });

  test('reads the container from a file', () async {
    final directory = await Directory.systemTemp.createTemp('audio_signature_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/track.wav');
    await file.writeAsBytes(const [
      0x52,
      0x49,
      0x46,
      0x46,
      0x00,
      0x00,
      0x00,
      0x00,
      0x57,
      0x41,
      0x56,
      0x45,
    ]);

    expect(await readAudioExtension(file), '.wav');
  });
}
