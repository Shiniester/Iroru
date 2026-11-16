import 'dart:io';

String? audioExtensionFromHeader(List<int> bytes) {
  bool startsWith(List<int> signature) =>
      bytes.length >= signature.length &&
      bytes
          .take(signature.length)
          .toList()
          .asMap()
          .entries
          .every((entry) => entry.value == signature[entry.key]);

  String asciiAt(int offset, int length) => bytes.length >= offset + length
      ? String.fromCharCodes(bytes.skip(offset).take(length))
      : '';

  if (asciiAt(0, 3) == 'ID3') return '.mp3';
  if (startsWith(const [0x66, 0x4c, 0x61, 0x43])) return '.flac';
  if (asciiAt(0, 4) == 'RIFF' && asciiAt(8, 4) == 'WAVE') return '.wav';
  if (asciiAt(0, 4) == 'OggS' && bytes.length >= 27) {
    final packetOffset = 27 + bytes[26];
    return asciiAt(packetOffset, 8) == 'OpusHead' ? '.opus' : '.ogg';
  }
  if (asciiAt(4, 4) == 'ftyp') {
    return asciiAt(8, 4) == 'M4B ' ? '.m4b' : '.m4a';
  }
  if (startsWith(const [
    0x30,
    0x26,
    0xb2,
    0x75,
    0x8e,
    0x66,
    0xcf,
    0x11,
    0xa6,
    0xd9,
  ])) {
    return '.wma';
  }
  if (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0) {
    return '.aac';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0xff &&
      (bytes[1] & 0xe0) == 0xe0 &&
      (bytes[1] & 0x06) != 0 &&
      (bytes[2] & 0xf0) != 0xf0 &&
      (bytes[2] & 0x0c) != 0x0c) {
    return '.mp3';
  }
  return null;
}

Future<String?> readAudioExtension(File file) async {
  final handle = await file.open();
  try {
    return audioExtensionFromHeader(await handle.read(64));
  } finally {
    await handle.close();
  }
}

