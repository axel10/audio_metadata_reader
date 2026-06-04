import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/utils/bit_manipulator.dart';
import 'package:audio_metadata_reader/src/utils/buffer.dart';
import 'package:audio_metadata_reader/src/writers/base_writer.dart';
import 'package:audio_metadata_reader/src/writers/id3v4_writer.dart';

/// Writer for AIFF metadata.
///
/// AIFF is an IFF-family container format using big-endian byte order.
/// Chunks are padded to a 2-byte word boundary if they have an odd size.
///
/// In this writer:
/// 1. We parse the original FORM chunks.
/// 2. We skip legacy metadata chunks ('NAME', 'AUTH', 'ANNO', '(c) ') and the 'ID3 ' chunk.
/// 3. We copy other chunks (e.g. 'COMM', 'SSND' sound data) verbatim.
/// 4. We append updated metadata in the form of legacy text chunks and a rich 'ID3 ' chunk (containing artwork, etc.).
/// 5. Finally, we update the FORM chunk size and write everything back.
class AiffWriter extends BaseMetadataWriter<RiffMetadata> {
  @override
  void write(File file, RiffMetadata metadata) {
    final reader = file.openSync();
    final buffer = Buffer(randomAccessFile: reader);

    try {
      reader.setPositionSync(0);
      final fileLength = reader.lengthSync();

      if (fileLength < 12) {
        throw StateError('Invalid AIFF file: too short');
      }

      final formId = String.fromCharCodes(buffer.read(4));
      if (formId != 'FORM') {
        throw StateError('Invalid AIFF file: missing FORM header');
      }

      // Skip size for now, we will recalculate it
      buffer.read(4);

      final formType = String.fromCharCodes(buffer.read(4));
      if (formType != 'AIFF' && formType != 'AIFC') {
        throw StateError('Unsupported FORM type: $formType');
      }

      final builder = BytesBuilder();

      // Read and copy all chunks except standard metadata and ID3 tags
      while (buffer.fileCursor + 8 <= fileLength) {
        final chunkIdBytes = buffer.read(4);
        final chunkId = String.fromCharCodes(chunkIdBytes);
        final chunkSizeBytes = buffer.read(4);
        final chunkSize = getUint32(chunkSizeBytes);

        if (chunkSize > buffer.remainingBytes) {
          // File is truncated or chunk size is corrupt
          break;
        }

        // Chunks to skip / rewrite
        if (chunkId == 'NAME' ||
            chunkId == 'AUTH' ||
            chunkId == 'ANNO' ||
            chunkId == '(c) ' ||
            chunkId == 'ID3 ') {
          buffer.skip(chunkSize);
          if (chunkSize.isOdd && buffer.fileCursor < fileLength) {
            buffer.skip(1);
          }
        } else {
          // Copy chunk id and size
          builder.add(chunkIdBytes);
          builder.add(chunkSizeBytes);
          // Copy chunk payload
          builder.add(buffer.read(chunkSize));

          if (chunkSize.isOdd) {
            if (buffer.fileCursor < fileLength) {
              buffer.skip(1);
            }
            builder.addByte(0); // write even padding alignment byte
          }
        }
      }

      // Append new legacy metadata chunks
      if (metadata.title != null) {
        builder.add(_writeTextChunk('NAME', metadata.title!));
      }
      if (metadata.artist != null) {
        builder.add(_writeTextChunk('AUTH', metadata.artist!));
      }
      if (metadata.comment != null) {
        builder.add(_writeTextChunk('ANNO', metadata.comment!));
      }
      if (metadata.copyright != null) {
        builder.add(_writeTextChunk('(c) ', metadata.copyright!));
      }

      // Compile ID3v2.4 tag block and append it as 'ID3 ' chunk
      final id3Metadata = Mp3Metadata()
        ..songName = metadata.title
        ..leadPerformer = metadata.artist
        ..album = metadata.album
        ..year = metadata.year?.year
        ..trackNumber = metadata.trackNumber
        ..encoderSoftware = metadata.encoder
        ..publisher = metadata.publisher
        ..genres = metadata.genre != null ? [metadata.genre!] : []
        ..copyrightMessage = metadata.copyright
        ..pictures = metadata.pictures;

      final id3Bytes = Id3v4Writer().compile(id3Metadata);
      if (id3Bytes.isNotEmpty) {
        builder.add(_writeChunk('ID3 ', id3Bytes));
      }

      final childChunksData = builder.toBytes();

      // Write final file contents
      final finalBuilder = BytesBuilder();
      finalBuilder.add('FORM'.codeUnits);
      // FORM chunk size = 4 (form type) + length of child chunks
      finalBuilder.add(intToUint32(4 + childChunksData.length));
      finalBuilder.add(formType.codeUnits);
      finalBuilder.add(childChunksData);

      reader.closeSync();
      file.writeAsBytesSync(finalBuilder.toBytes(), flush: true);
    } catch (e) {
      try {
        reader.closeSync();
      } catch (_) {}
      rethrow;
    }
  }

  Uint8List _writeChunk(String id, Uint8List data) {
    final builder = BytesBuilder();
    builder.add(ascii.encode(id));
    builder.add(intToUint32(data.length));
    builder.add(data);
    if (data.length.isOdd) {
      builder.addByte(0);
    }
    return builder.toBytes();
  }

  Uint8List _writeTextChunk(String id, String value) {
    final valueBytes = utf8.encode(value);
    return _writeChunk(id, valueBytes);
  }
}
