import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:test/test.dart';

void main() {
  test('RiffWriter writes to the target file instead of a fixed filename', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track.wav');
    target.writeAsBytesSync(File('test/wav/track.wav').readAsBytesSync());

    final fixedOutput = File('a_new.wav');
    if (fixedOutput.existsSync()) {
      fixedOutput.deleteSync();
    }

    final metadata = RiffMetadata(
      title: 'Updated WAV title',
    );

    RiffWriter().write(target, metadata);

    expect(target.existsSync(), isTrue);
    expect(fixedOutput.existsSync(), isFalse);

    final bytes = target.readAsBytesSync();
    final byteData = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), equals('RIFF'));
    expect(String.fromCharCodes(bytes.sublist(8, 12)), equals('WAVE'));
    expect(byteData.getUint32(4, Endian.little), equals(bytes.length - 8));

    final parsedMetadata = readMetadata(target, getImage: false);
    expect(parsedMetadata.title, equals('Updated WAV title'));
  });

  test('RiffWriter writes metadata to a file that does not have any metadata initially', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/test_no_metadata.wav');
    target.writeAsBytesSync(File('test/wav/test_no_metadata.wav').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'Newly added WAV title',
      artist: 'Newly added WAV artist',
    );

    RiffWriter().write(target, metadata);

    expect(target.existsSync(), isTrue);

    final bytes = target.readAsBytesSync();
    final byteData = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), equals('RIFF'));
    expect(String.fromCharCodes(bytes.sublist(8, 12)), equals('WAVE'));
    expect(byteData.getUint32(4, Endian.little), equals(bytes.length - 8));

    final parsedMetadata = readMetadata(target, getImage: false);
    expect(parsedMetadata.title, equals('Newly added WAV title'));
    expect(parsedMetadata.artist, equals('Newly added WAV artist'));
  });

  test('RiffWriter writes and reads back non-ASCII metadata (UTF-8)', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/test_utf8.wav');
    target.writeAsBytesSync(File('test/wav/test_no_metadata.wav').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'エイリアンエイリアン',
      artist: '青空ポッピンサマー',
    );

    RiffWriter().write(target, metadata);

    expect(target.existsSync(), isTrue);

    final bytes = target.readAsBytesSync();
    final byteData = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), equals('RIFF'));
    expect(String.fromCharCodes(bytes.sublist(8, 12)), equals('WAVE'));
    expect(byteData.getUint32(4, Endian.little), equals(bytes.length - 8));

    final parsedMetadata = readMetadata(target, getImage: false);
    expect(parsedMetadata.title, equals('エイリアンエイリアン'));
    expect(parsedMetadata.artist, equals('青空ポッピンサマー'));
  });

  test('RiffWriter updates existing ID3 chunk and LIST/INFO in WAV file', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track_id3.wav');
    target.writeAsBytesSync(File('test/wav/track_id3.wav').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'Updated WAV ID3 Title',
      artist: 'Updated WAV ID3 Artist',
      album: 'Updated WAV ID3 Album',
    );

    RiffWriter().write(target, metadata);

    // Read without getImage
    final parsed = readMetadata(target, getImage: false);
    expect(parsed.title, equals('Updated WAV ID3 Title'));
    expect(parsed.artist, equals('Updated WAV ID3 Artist'));
    expect(parsed.album, equals('Updated WAV ID3 Album'));
  });

  test('RiffWriter writes cover/pictures to WAV file and retrieves it', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/test_write_id3.wav');
    target.writeAsBytesSync(File('test/wav/test_write_id3.wav').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'WAV with Cover',
    );
    metadata.pictures = [
      Picture(Uint8List.fromList([10, 20, 30, 40]), 'image/jpeg', PictureType.coverFront),
    ];

    RiffWriter().write(target, metadata);

    // Read back with getImage: true
    final parsedWithImage = readMetadata(target, getImage: true);
    expect(parsedWithImage.title, equals('WAV with Cover'));
    expect(parsedWithImage.pictures, hasLength(1));
    expect(parsedWithImage.pictures.first.mimetype, equals('image/jpeg'));
    expect(parsedWithImage.pictures.first.pictureType, equals(PictureType.coverFront));
    expect(parsedWithImage.pictures.first.bytes, equals([10, 20, 30, 40]));
  });
}
