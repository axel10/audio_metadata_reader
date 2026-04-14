import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:test/test.dart';

import '../test_helpers.dart';

Uint8List _synchsafe(int value) {
  return Uint8List.fromList([
    (value >> 21) & 0x7F,
    (value >> 14) & 0x7F,
    (value >> 7) & 0x7F,
    value & 0x7F,
  ]);
}

Uint8List _utf16BeBytes(String text) {
  final bytes = <int>[];
  for (final unit in text.codeUnits) {
    bytes.add((unit >> 8) & 0xFF);
    bytes.add(unit & 0xFF);
  }
  return Uint8List.fromList(bytes);
}

Uint8List _latin1Bytes(String text) {
  return Uint8List.fromList(text.codeUnits.map((c) => c & 0xFF).toList());
}

Uint8List _makeV24TextFrame(String id, int encoding, Uint8List valueBytes) {
  final content = Uint8List.fromList([encoding, ...valueBytes]);
  final frame = BytesBuilder();
  frame.add(id.codeUnits);
  frame.add(_synchsafe(content.length));
  frame.add([0, 0]);
  frame.add(content);
  return frame.toBytes();
}

Uint8List _makeV22TextFrame(String id, int encoding, Uint8List valueBytes) {
  final content = Uint8List.fromList([encoding, ...valueBytes]);
  final frame = BytesBuilder();
  frame.add(id.codeUnits);
  frame.add([
    (content.length >> 16) & 0xFF,
    (content.length >> 8) & 0xFF,
    content.length & 0xFF,
  ]);
  frame.add(content);
  return frame.toBytes();
}

Uint8List _makeId3v24Tag(List<Uint8List> frames) {
  final frameBytes = BytesBuilder();
  for (final frame in frames) {
    frameBytes.add(frame);
  }

  final payload = frameBytes.toBytes();
  final tag = BytesBuilder();
  tag.add("ID3".codeUnits);
  tag.add([4, 0, 0]);
  tag.add(_synchsafe(payload.length));
  tag.add(payload);
  return tag.toBytes();
}

Uint8List _makeId3v22Tag(List<Uint8List> frames) {
  final frameBytes = BytesBuilder();
  for (final frame in frames) {
    frameBytes.add(frame);
  }

  final payload = frameBytes.toBytes();
  final tag = BytesBuilder();
  tag.add("ID3".codeUnits);
  tag.add([2, 0, 0]);
  tag.add(_synchsafe(payload.length));
  tag.add(payload);
  return tag.toBytes();
}

Uint8List _makeId3v1Tag({
  required String title,
  required String artist,
  required String album,
  required String year,
}) {
  final bytes = Uint8List(128);
  bytes.setAll(0, "TAG".codeUnits);
  bytes.setRange(3, 33, _latin1Bytes(title).padRight(30, 0));
  bytes.setRange(33, 63, _latin1Bytes(artist).padRight(30, 0));
  bytes.setRange(63, 93, _latin1Bytes(album).padRight(30, 0));
  bytes.setRange(93, 97, year.codeUnits.take(4).toList());
  return bytes;
}

extension _PadRight on Uint8List {
  List<int> padRight(int length, int fill) {
    final out = List<int>.from(this);
    while (out.length < length) {
      out.add(fill);
    }
    return out;
  }
}

void main() {
  test("decodes UTF-16BE ID3v2 text frames correctly", () {
    final tagBytes = _makeId3v24Tag([
      _makeV24TextFrame("TIT2", 2, _utf16BeBytes("Café")),
      _makeV24TextFrame("TPE1", 2, _utf16BeBytes("Beyoncé")),
    ]);
    final file = createTemporaryFile("utf16be.mp3", tagBytes);

    final metadata = readMetadata(file, getImage: false);

    expect(metadata.title, equals("Café"));
    expect(metadata.artist, equals("Beyoncé"));
  });

  test("decodes ID3v2.2 text frames", () {
    final tagBytes = _makeId3v22Tag([
      _makeV22TextFrame("TT2", 0, _latin1Bytes("Old Title")),
      _makeV22TextFrame("TP1", 0, _latin1Bytes("Old Artist")),
    ]);
    final file = createTemporaryFile("id3v22.mp3", tagBytes);

    final metadata = readMetadata(file, getImage: false);

    expect(metadata.title, equals("Old Title"));
    expect(metadata.artist, equals("Old Artist"));
  });

  test("decodes ID3v1 latin1 text without UTF-8 assumptions", () {
    final fileBytes = BytesBuilder()
      ..add([0xFF, 0xFB, 0x90, 0x64])
      ..add(List.filled(64, 0))
      ..add([0x01])
      ..add(List.filled(335, 0))
      ..add(_makeId3v1Tag(
        title: "Café",
        artist: "Beyoncé",
        album: "Résumé",
        year: "1999",
      ));
    final file = createTemporaryFile("id3v1.mp3", fileBytes.toBytes());

    final metadata = readMetadata(file, getImage: false);

    expect(metadata.title, equals("Café"));
    expect(metadata.artist, equals("Beyoncé"));
    expect(metadata.album, equals("Résumé"));
    expect(metadata.year, equals(DateTime(1999)));
  });
}
