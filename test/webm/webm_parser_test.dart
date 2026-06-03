import 'dart:io';

import 'package:audio_metadata_reader/src/parser.dart';
import 'package:test/test.dart';

void main() {
  test("Parse WebM file without cover art", () {
    final track = File('./test/webm/track.webm');
    expect(track.existsSync(), isTrue);

    final result = readMetadata(track, getImage: false);

    expect(result.title, equals("WebM Test Title"));
    expect(result.artist, equals("WebM Test Artist"));
    expect(result.album, equals("WebM Test Album"));
    expect(result.genres, contains("Lo-Fi"));
    expect(result.trackNumber, equals(2));
    expect(result.discNumber, equals(1));
    expect(result.lyrics, isNull);
    expect(result.sampleRate, equals(48000));
    // The duration is 2.5 seconds (2500 milliseconds)
    expect(result.duration?.inMilliseconds, closeTo(2500, 100));
    expect(result.hasArtwork, isFalse);
    expect(result.pictures, isEmpty);
  });

  test("Parse Matroska (MKA) file with cover art", () {
    final track = File('./test/webm/track.mka');
    expect(track.existsSync(), isTrue);

    // Test readMetadata without extracting image bytes
    final resultNoImage = readMetadata(track, getImage: false);
    expect(resultNoImage.title, equals("WebM Test Title"));
    expect(resultNoImage.artist, equals("WebM Test Artist"));
    expect(resultNoImage.album, equals("WebM Test Album"));
    expect(resultNoImage.genres, contains("Lo-Fi"));
    expect(resultNoImage.trackNumber, equals(2));
    expect(resultNoImage.discNumber, equals(1));
    expect(resultNoImage.sampleRate, equals(48000));
    expect(resultNoImage.duration?.inMilliseconds, closeTo(2500, 100));
    expect(resultNoImage.hasArtwork, isTrue); // Matroska has attached file
    expect(resultNoImage.pictures, isEmpty); // But bytes are skipped

    // Test readMetadata with extracting image bytes
    final resultWithImage = readMetadata(track, getImage: true);
    expect(resultWithImage.hasArtwork, isTrue);
    expect(resultWithImage.pictures, isNotEmpty);
    expect(resultWithImage.pictures.first.mimetype, equals("image/jpeg"));
    expect(resultWithImage.pictures.first.bytes, isNotEmpty);
  });
}
