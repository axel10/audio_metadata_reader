import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:test/test.dart';

void main() {
  test('ApeWriter writes metadata to a real APE file', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track.ape');
    target.writeAsBytesSync(File('test/ape/track.ape').readAsBytesSync());

    final metadata = ApeMetadata()
      ..title = 'APE Test Title'
      ..artist = 'APE Test Artist'
      ..album = 'APE Test Album'
      ..trackNumber = 3
      ..trackTotal = 8
      ..discNumber = 1
      ..discTotal = 2
      ..genres = ['Electronic', 'Dance']
      ..lyric = 'This is a lyric'
      ..comment = 'APE Comment'
      ..composer = 'Composer Name'
      ..copyright = '2026 Copyright'
      ..encodedBy = 'LAME'
      ..date = DateTime(2026);

    ApeWriter().write(target, metadata);

    expect(target.existsSync(), isTrue);

    final parsedMetadata = readMetadata(target, getImage: false);
    expect(parsedMetadata.title, equals('APE Test Title'));
    expect(parsedMetadata.artist, equals('APE Test Artist'));
    expect(parsedMetadata.album, equals('APE Test Album'));
    expect(parsedMetadata.trackNumber, equals(3));
    expect(parsedMetadata.trackTotal, equals(8));
    expect(parsedMetadata.discNumber, equals(1));
    expect(parsedMetadata.totalDisc, equals(2));
    expect(parsedMetadata.genres, equals(['Electronic', 'Dance']));
    expect(parsedMetadata.lyrics, equals('This is a lyric'));
    expect(parsedMetadata.year, equals(DateTime(2026)));

    final allMetadata = readAllMetadata(target, getImage: false) as ApeMetadata;
    expect(allMetadata.comment, equals('APE Comment'));
    expect(allMetadata.composer, equals('Composer Name'));
    expect(allMetadata.copyright, equals('2026 Copyright'));
    expect(allMetadata.encodedBy, equals('LAME'));
  });

  test('ApeWriter writes binary cover art to APE file', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track_cover.ape');
    target.writeAsBytesSync(File('test/ape/track.ape').readAsBytesSync());

    final coverBytes = File('test/data/cover.png').readAsBytesSync();

    final metadata = ApeMetadata()
      ..title = 'APE with Cover'
      ..pictures = [
        Picture(coverBytes, 'image/png', PictureType.coverFront),
      ];

    ApeWriter().write(target, metadata);

    final parsed = readMetadata(target, getImage: true);
    expect(parsed.title, equals('APE with Cover'));
    expect(parsed.hasArtwork, isTrue);
    expect(parsed.pictures, hasLength(1));
    expect(parsed.pictures.first.mimetype, equals('image/png'));
    expect(parsed.pictures.first.pictureType, equals(PictureType.coverFront));
    expect(parsed.pictures.first.bytes, equals(coverBytes));
  });

  test('ApeWriter writes metadata to APE tag in MP3 file and reads it back', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/base_no_tag.mp3');
    target.writeAsBytesSync(File('test/ape/base_no_tag.mp3').readAsBytesSync());

    final metadata = ApeMetadata()
      ..title = 'MP3 APE Title'
      ..artist = 'MP3 APE Artist'
      ..album = 'MP3 APE Album'
      ..genres = ['Pop'];

    ApeWriter().write(target, metadata);

    final parsed = readMetadata(target, getImage: false);
    expect(parsed.title, equals('MP3 APE Title'));
    expect(parsed.artist, equals('MP3 APE Artist'));
    expect(parsed.album, equals('MP3 APE Album'));
    expect(parsed.genres, equals(['Pop']));
  });

  test('ApeWriter writes non-ASCII UTF-8 tags to APE file', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));

    final target = File('${dir.path}/track_utf8.ape');
    target.writeAsBytesSync(File('test/ape/track.ape').readAsBytesSync());

    final metadata = ApeMetadata()
      ..title = '测试标题'
      ..artist = '歌手'
      ..genres = ['流行'];

    ApeWriter().write(target, metadata);

    final parsed = readMetadata(target, getImage: false);
    expect(parsed.title, equals('测试标题'));
    expect(parsed.artist, equals('歌手'));
    expect(parsed.genres, equals(['流行']));
  });
}
