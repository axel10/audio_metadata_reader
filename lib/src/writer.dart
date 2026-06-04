import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/parsers/containers/ogg.dart';
import 'package:audio_metadata_reader/src/parsers/containers/riff.dart';
import 'package:audio_metadata_reader/src/writers/ogg_writer.dart';

/// Reads the metadata, allows modification via [updater], and writes it back.
///
/// The [updater] receives the specific metadata object (e.g Mp3Metadata).
/// You can modify this object directly within the callback.
void updateMetadata(File track, void Function(ParserTag metadata) updater) {
  final metadata = readAllMetadata(track);

  updater(metadata);

  writeMetadata(track, metadata);
}

/// Write [metadata] back into [track] using the matching container writer.
///
/// The runtime type of [metadata] must match the detected writer.
void writeMetadata(File track, ParserTag metadata) {
  final reader = track.openSync();
  String? format;

  try {
    if (MP3Parser.hasID3v2Tag(reader)) {
      format = 'mp3_id3v2';
    } else if (MP4Parser.canUserParser(reader)) {
      format = 'mp4';
    } else if (FlacParser.canUserParser(reader)) {
      format = 'flac';
    } else if (OGGParser.canUserParser(reader)) {
      format = 'ogg';
    } else if (RiffParser.canUserParser(reader)) {
      format = 'riff';
    } else if (MP3Parser.hasID3v1Tag(reader)) {
      format = 'mp3_id3v1';
    }
  } finally {
    // Always close the file handle opened by this function.
    reader.closeSync();
  }

  if (format == 'mp3_id3v2') {
    Id3v4Writer().write(track, metadata as Mp3Metadata);
  } else if (format == 'mp4') {
    Mp4Writer().write(track, metadata as Mp4Metadata);
  } else if (format == 'flac') {
    FlacWriter().write(track, metadata as VorbisMetadata);
  } else if (format == 'ogg') {
    OggWriter().write(track, metadata as VorbisMetadata);
  } else if (format == 'riff') {
    RiffWriter().write(track, metadata as RiffMetadata);
  } else if (format == 'mp3_id3v1') {
    ID3v1Writer().write(track, metadata as Mp3Metadata);
  }
}
