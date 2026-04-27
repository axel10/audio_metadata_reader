import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:test/test.dart';

import '../test_helpers.dart';

void main() {
  test('updateMetadata writes OGG vorbis comments and pictures', () {
    final target = createTemporaryFile(
      'track.ogg',
      File('test/ogg/track.ogg').readAsBytesSync(),
    );

    updateMetadata(target, (metadata) {
      final vorbis = metadata as VorbisMetadata;
      vorbis.title = ['Updated OGG title'];
      vorbis.artist = ['Updated OGG artist'];
      vorbis.trackNumber = [7];
      vorbis.trackTotal = 12;
      vorbis.discNumber = 2;
      vorbis.discTotal = 3;
      vorbis.genres = ['Jazz'];
      vorbis.pictures = [
        Picture(
          Uint8List.fromList(File('test/data/cover.png').readAsBytesSync()),
          'image/png',
          PictureType.coverFront,
        ),
      ];
    });

    final parsed = readMetadata(target, getImage: true);
    expect(parsed.title, equals('Updated OGG title'));
    expect(parsed.artist, equals('Updated OGG artist'));
    expect(parsed.trackNumber, equals(7));
    expect(parsed.trackTotal, equals(12));
    expect(parsed.discNumber, equals(2));
    expect(parsed.totalDisc, equals(3));
    expect(parsed.genres, equals(['Jazz']));
    expect(parsed.duration, equals(const Duration(seconds: 1)));
    expect(parsed.pictures, hasLength(1));
    expect(parsed.pictures.first.mimetype, equals('image/png'));
    expect(parsed.pictures.first.pictureType, equals(PictureType.coverFront));
  });

  test('updateMetadata writes Opus vorbis comments', () {
    final target = createTemporaryFile(
      'track.opus',
      File('test/opus/track.opus').readAsBytesSync(),
    );

    updateMetadata(target, (metadata) {
      final vorbis = metadata as VorbisMetadata;
      vorbis.title = ['Updated Opus title'];
      vorbis.artist = ['Updated Opus artist'];
      vorbis.trackNumber = [4];
      vorbis.trackTotal = 9;
      vorbis.discNumber = 1;
      vorbis.discTotal = 2;
      vorbis.genres = ['Rock'];
    });

    final parsed = readMetadata(target, getImage: false);
    expect(parsed.title, equals('Updated Opus title'));
    expect(parsed.artist, equals('Updated Opus artist'));
    expect(parsed.trackNumber, equals(4));
    expect(parsed.trackTotal, equals(9));
    expect(parsed.discNumber, equals(1));
    expect(parsed.totalDisc, equals(2));
    expect(parsed.genres, equals(['Rock']));
    expect(parsed.duration, equals(const Duration(seconds: 1)));
  });
}
