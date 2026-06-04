import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/utils/bit_manipulator.dart';
import 'package:audio_metadata_reader/src/utils/buffer.dart';
import 'package:audio_metadata_reader/src/writers/base_writer.dart';
import 'package:audio_metadata_reader/src/writers/id3v4_writer.dart';

/// Writer for RIFF/WAVE INFO metadata chunks.
class RiffWriter extends BaseMetadataWriter<RiffMetadata> {
  /// Metadata currently being serialized.
  late RiffMetadata metadata;

  /// Reader helper bound to the original file.
  late final Buffer buffer;

  @override
  void write(File file, RiffMetadata metadata) {
    this.metadata = metadata;
    final builder = BytesBuilder();

    final reader = file.openSync();
    buffer = Buffer(randomAccessFile: reader);
    reader.setPositionSync(0);

    buffer.skip(12);
    final newData = _parseChunks();

    builder.add("RIFF".codeUnits);
    // RIFF chunk size is file size - 8, i.e. 4 ("WAVE") + payload bytes.
    builder.add(intToUint32LE(newData.length + 4));
    builder.add("WAVE".codeUnits);
    builder.add(newData);

    reader.closeSync();
    file.writeAsBytesSync(builder.toBytes());
  }

  Uint8List _parseChunks() {
    final builder = BytesBuilder();
    bool wroteListInfo = false;
    bool wroteId3 = false;

    while (buffer.fileCursor < buffer.randomAccessFile.lengthSync() - 8) {
      final chunkIdBytes = buffer.read(4);
      final chunkId = String.fromCharCodes(chunkIdBytes);
      final chunkSizeBytes = buffer.read(4);
      final chunkSize = getUint32LE(chunkSizeBytes);

      builder.add(chunkIdBytes);

      if (chunkId == "LIST") {
        // Peek at the next 4 bytes to check the LIST type
        final listTypeBytes = buffer.read(4);
        final listType = String.fromCharCodes(listTypeBytes);

        if (listType == "INFO") {
          wroteListInfo = true;
          // Skip old INFO data from the source file
          buffer.skip(chunkSize - 4);

          // Write new LIST chunk with updated INFO
          final infoBuilder = BytesBuilder();

          if (metadata.title != null) {
            infoBuilder.add(_writeChunk("INAM", metadata.title!));
          }
          if (metadata.artist != null) {
            infoBuilder.add(_writeChunk("IART", metadata.artist!));
          }
          if (metadata.album != null) {
            infoBuilder.add(_writeChunk("IPRD", metadata.album!));
          }
          if (metadata.year != null) {
            infoBuilder
                .add(_writeChunk("ICRD", metadata.year!.year.toString()));
          }
          if (metadata.comment != null) {
            infoBuilder.add(_writeChunk("ICMT", metadata.comment!));
          }
          if (metadata.trackNumber != null) {
            infoBuilder
                .add(_writeChunk("ITRK", metadata.trackNumber!.toString()));
          }
          if (metadata.encoder != null) {
            infoBuilder.add(_writeChunk("ISFT", metadata.encoder!));
          }
          if (metadata.genre != null) {
            infoBuilder.add(_writeChunk("IGNR", metadata.genre!));
          }
          if (metadata.copyright != null) {
            infoBuilder.add(_writeChunk("ICOP", metadata.copyright!));
          }

          final infoData = infoBuilder.toBytes();
          // 4 bytes for "INFO" + INFO subchunks
          final newChunkSize = 4 + infoData.length;

          builder.add(intToUint32LE(newChunkSize));
          builder.add(ascii.encode("INFO"));
          builder.add(infoData);

          // Note: Since all sub-chunks written by _writeChunk are aligned to even boundaries
          // (padding added inside _writeChunk if text is odd), newChunkSize is guaranteed
          // to be even. Thus, we do not write any padding byte to the output for this chunk.
          // However, if the original chunk size in the source file was odd, we must still
          // skip the original padding byte in the source buffer.
          if (chunkSize.isOdd) {
            buffer.skip(1);
          }
        } else {
          // Keep the LIST chunk as-is
          builder.add(chunkSizeBytes);
          builder.add(listTypeBytes);
          builder.add(buffer.read(chunkSize - 4));

          // If the original chunk size is odd, skip the pad byte in the input and copy it to the output.
          if (chunkSize.isOdd) {
            buffer.skip(1);
            builder.addByte(0);
          }
        }
      } else if (chunkId == "ID3 " || chunkId == "id3 ") {
        wroteId3 = true;
        // Skip old ID3 chunk from the source file
        buffer.skip(chunkSize);
        if (chunkSize.isOdd) {
          buffer.skip(1);
        }

        // Compile and write updated ID3 chunk.
        // We sync text metadata and pictures so that players reading ID3
        // get the same updated fields.
        final id3Metadata = Mp3Metadata()
          ..songName = metadata.title
          ..leadPerformer = metadata.artist
          ..album = metadata.album
          ..year = metadata.year?.year
          ..trackNumber = metadata.trackNumber
          ..encoderSoftware = metadata.encoder
          ..genres = metadata.genre != null ? [metadata.genre!] : []
          ..copyrightMessage = metadata.copyright
          ..pictures = metadata.pictures;

        final id3Bytes = Id3v4Writer().compile(id3Metadata);
        if (id3Bytes.isNotEmpty) {
          int size = id3Bytes.length;
          final needsPadding = size.isOdd;
          if (needsPadding) {
            size += 1;
          }
          builder.add(intToUint32LE(size));
          builder.add(id3Bytes);
          if (needsPadding) {
            builder.addByte(0);
          }
        } else {
          builder.add(intToUint32LE(0));
        }
      } else {
        // Keep the non-LIST chunk as-is
        builder.add(chunkSizeBytes);
        builder.add(buffer.read(chunkSize));

        // If the original chunk size is odd, skip the pad byte in the input and copy it to the output.
        if (chunkSize.isOdd) {
          buffer.skip(1);
          builder.addByte(0);
        }
      }
    }

    // If the file did not contain any LIST/INFO chunk, we append a new one at the end of the file.
    // This conforms to RIFF specifications where chunks can appear in any order inside the container.
    if (!wroteListInfo) {
      final infoBuilder = BytesBuilder();

      if (metadata.title != null) {
        infoBuilder.add(_writeChunk("INAM", metadata.title!));
      }
      if (metadata.artist != null) {
        infoBuilder.add(_writeChunk("IART", metadata.artist!));
      }
      if (metadata.album != null) {
        infoBuilder.add(_writeChunk("IPRD", metadata.album!));
      }
      if (metadata.year != null) {
        infoBuilder
            .add(_writeChunk("ICRD", metadata.year!.year.toString()));
      }
      if (metadata.comment != null) {
        infoBuilder.add(_writeChunk("ICMT", metadata.comment!));
      }
      if (metadata.trackNumber != null) {
        infoBuilder
            .add(_writeChunk("ITRK", metadata.trackNumber!.toString()));
      }
      if (metadata.encoder != null) {
        infoBuilder.add(_writeChunk("ISFT", metadata.encoder!));
      }
      if (metadata.genre != null) {
        infoBuilder.add(_writeChunk("IGNR", metadata.genre!));
      }
      if (metadata.copyright != null) {
        infoBuilder.add(_writeChunk("ICOP", metadata.copyright!));
      }

      final infoData = infoBuilder.toBytes();
      if (infoData.isNotEmpty) {
        final newChunkSize = 4 + infoData.length;
        builder.add(ascii.encode("LIST"));
        builder.add(intToUint32LE(newChunkSize));
        builder.add(ascii.encode("INFO"));
        builder.add(infoData);
        // newChunkSize is guaranteed to be even because all subchunks are even,
        // so no padding alignment byte is needed after this appended chunk.
      }
    }

    // If the file did not contain any ID3 chunk, but we have pictures to write,
    // we append a new ID3 chunk at the end of the file.
    if (!wroteId3 && metadata.pictures.isNotEmpty) {
      final id3Metadata = Mp3Metadata()
        ..songName = metadata.title
        ..leadPerformer = metadata.artist
        ..album = metadata.album
        ..year = metadata.year?.year
        ..trackNumber = metadata.trackNumber
        ..encoderSoftware = metadata.encoder
        ..genres = metadata.genre != null ? [metadata.genre!] : []
        ..copyrightMessage = metadata.copyright
        ..pictures = metadata.pictures;

      final id3Bytes = Id3v4Writer().compile(id3Metadata);
      if (id3Bytes.isNotEmpty) {
        builder.add(ascii.encode("ID3 "));
        int size = id3Bytes.length;
        final needsPadding = size.isOdd;
        if (needsPadding) {
          size += 1;
        }
        builder.add(intToUint32LE(size));
        builder.add(id3Bytes);
        if (needsPadding) {
          builder.addByte(0);
        }
      }
    }

    return builder.toBytes();
  }

  Uint8List _writeChunk(String id, String value) {
    final builder = BytesBuilder();

    final idBytes = ascii.encode(id);
    final valueBytes = utf8.encode(value);
    int size = valueBytes.length;

    // Add padding byte if size is odd (WAV format requires even chunk sizes)
    final needsPadding = size.isOdd;
    if (needsPadding) {
      size += 1;
    }

    builder.add(idBytes); // 4 bytes: chunk ID (e.g., "INAM")
    builder.add(intToUint32LE(size)); // 4 bytes: chunk size (padded if needed)
    builder.add(valueBytes); // chunk data
    if (needsPadding) {
      builder.addByte(0); // padding
    }

    return builder.toBytes();
  }
}
