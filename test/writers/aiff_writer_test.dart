import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:test/test.dart';

void main() {
  test('AiffWriter writes legacy chunks to AIFF file', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track.aiff');
    target.writeAsBytesSync(File('test/aiff/track.aiff').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'Updated AIFF Title',
      artist: 'Updated AIFF Artist',
      comment: 'Updated Comment',
      copyright: '2026 Updated Copyright',
    );

    AiffWriter().write(target, metadata);

    expect(target.existsSync(), isTrue);

    final parsedMetadata = readMetadata(target, getImage: false);
    expect(parsedMetadata.title, equals('Updated AIFF Title'));
    expect(parsedMetadata.artist, equals('Updated AIFF Artist'));

    final allMetadata = readAllMetadata(target, getImage: false) as RiffMetadata;
    expect(allMetadata.title, equals('Updated AIFF Title'));
    expect(allMetadata.artist, equals('Updated AIFF Artist'));
    expect(allMetadata.comment, equals('Updated Comment'));
    expect(allMetadata.copyright, equals('2026 Updated Copyright'));
  });

  test('AiffWriter writes ID3 rich metadata chunks to AIFF file', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track_id3.aiff');
    target.writeAsBytesSync(File('test/aiff/track_id3.aiff').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'Rich Title',
      artist: 'Rich Artist',
      album: 'Rich Album',
      trackNumber: 12,
      genre: 'Jazz',
      year: DateTime(2025),
    );

    AiffWriter().write(target, metadata);

    final parsedMetadata = readMetadata(target, getImage: false);
    expect(parsedMetadata.title, equals('Rich Title'));
    expect(parsedMetadata.artist, equals('Rich Artist'));
    expect(parsedMetadata.album, equals('Rich Album'));
    expect(parsedMetadata.trackNumber, equals(12));
    expect(parsedMetadata.genres, contains('Jazz'));
    expect(parsedMetadata.year, equals(DateTime(2025)));
  });

  test('AiffWriter writes cover/pictures to AIFF and retrieves them', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track_cover.aiff');
    target.writeAsBytesSync(File('test/aiff/track.aiff').readAsBytesSync());

    final coverBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

    final metadata = RiffMetadata(
      title: 'AIFF with Cover',
    );
    metadata.pictures = [
      Picture(coverBytes, 'image/jpeg', PictureType.coverFront),
    ];

    AiffWriter().write(target, metadata);

    final parsed = readMetadata(target, getImage: true);
    expect(parsed.title, equals('AIFF with Cover'));
    expect(parsed.hasArtwork, isTrue);
    expect(parsed.pictures, hasLength(1));
    expect(parsed.pictures.first.mimetype, equals('image/jpeg'));
    expect(parsed.pictures.first.pictureType, equals(PictureType.coverFront));
    expect(parsed.pictures.first.bytes, equals(coverBytes));
  });

  test('AiffWriter writes and reads back non-ASCII metadata (UTF-8)', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track_utf8.aiff');
    target.writeAsBytesSync(File('test/aiff/track.aiff').readAsBytesSync());

    final metadata = RiffMetadata(
      title: 'ポッピンサマー',
      artist: 'エイリアン',
    );

    AiffWriter().write(target, metadata);

    final parsed = readMetadata(target, getImage: false);
    expect(parsed.title, equals('ポッピンサマー'));
    expect(parsed.artist, equals('エイリアン'));
  });
}
