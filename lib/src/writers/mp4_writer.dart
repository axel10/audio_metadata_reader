import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_metadata_reader/src/parsers/containers/mp4.dart';
import 'package:audio_metadata_reader/src/utils/bit_manipulator.dart';
import 'package:audio_metadata_reader/src/writers/base_writer.dart';

/// Writer for MP4/M4A metadata atoms.
class Mp4Writer extends BaseMetadataWriter<Mp4Metadata> {
  /// Metadata currently being serialized.
  late Mp4Metadata mp4metadata;

  @override
  void write(File file, Mp4Metadata metadata) {
    mp4metadata = metadata;
    final reader = file.openSync();

    final lengthFile = reader.lengthSync();
    final tempFile = File('${file.path}.tmp');
    final writer = tempFile.openSync(mode: FileMode.write);

    try {
      while (reader.positionSync() < lengthFile) {
        final startPosition = reader.positionSync();
        final headerBytes = reader.readSync(8);
        if (headerBytes.length < 8) {
          break;
        }
        var boxSize = getUint32(headerBytes.sublist(0, 4));
        final boxNameBytes = headerBytes.sublist(4);
        final boxType = String.fromCharCodes(boxNameBytes);

        var headerSize = 8;
        var isLargeBox = false;

        if (boxSize == 1) {
          final sizeBytes = reader.readSync(8);
          if (sizeBytes.length < 8) {
            break;
          }
          boxSize = getUint64BE(sizeBytes);
          headerSize = 16;
          isLargeBox = true;
        } else if (boxSize == 0) {
          boxSize = lengthFile - startPosition;
        }

        final payloadSize = boxSize - headerSize;

        if (boxType != "moov") {
          if (isLargeBox) {
            writer.writeFromSync(intToUint32(1));
            writer.writeFromSync(boxType.codeUnits);
            writer.writeFromSync(intToUint64(boxSize));
          } else {
            writer.writeFromSync(intToUint32(boxSize));
            writer.writeFromSync(boxType.codeUnits);
          }
          _copyBytes(reader, writer, payloadSize);
        } else {
          final topBoxData = reader.readSync(payloadSize);
          final data = _processBox(topBoxData);

          writer.writeFromSync(intToUint32(data.length + 8));
          writer.writeFromSync(boxType.codeUnits);
          writer.writeFromSync(data);
        }
      }
    } finally {
      reader.closeSync();
      writer.closeSync();
    }

    tempFile.renameSync(file.path);
  }

  void _copyBytes(RandomAccessFile reader, RandomAccessFile writer, int length) {
    const chunkSize = 65536; // 64 KB chunks
    var remaining = length;
    while (remaining > 0) {
      final toRead = remaining < chunkSize ? remaining : chunkSize;
      final bytes = reader.readSync(toRead);
      if (bytes.isEmpty) {
        throw FileSystemException("Unexpected end of file while copying box payload");
      }
      writer.writeFromSync(bytes);
      remaining -= bytes.length;
    }
  }

  Uint8List intToUint64(int value) {
    final result = Uint8List(8);
    result[0] = (value >> 56) & 0xFF;
    result[1] = (value >> 48) & 0xFF;
    result[2] = (value >> 40) & 0xFF;
    result[3] = (value >> 32) & 0xFF;
    result[4] = (value >> 24) & 0xFF;
    result[5] = (value >> 16) & 0xFF;
    result[6] = (value >> 8) & 0xFF;
    result[7] = value & 0xFF;
    return result;
  }

  Uint8List _processBox(Uint8List data) {
    int offset = 0;
    const recursiveBoxes = {
      "moov",
      "udta",
      "meta",
      "ilst",
    };
    final byteBuilder = BytesBuilder();

    while (offset < data.length) {
      final headerBytes = data.sublist(offset, offset + 8);
      final box = _readBox(headerBytes);
      offset += 8;

      Uint8List boxData = data.sublist(offset, offset + box.size - 8);
      offset += box.size - 8;

      if (box.type == "ilst") {
        final newMetadataData = _replaceMetadata(boxData);

        byteBuilder.add(intToUint32(newMetadataData.length + 8));
        byteBuilder.add(box.type.codeUnits);
        byteBuilder.add(newMetadataData);
      } else if (recursiveBoxes.contains(box.type)) {
        if (box.type == "meta") {
          offset += 4;
          final subData = boxData.sublist(4);
          final recursiveBoxData = _processBox(subData);

          byteBuilder.add(intToUint32(recursiveBoxData.length + 12));
          byteBuilder.add(box.type.codeUnits);
          byteBuilder.add(boxData.sublist(0, 4));
          byteBuilder.add(recursiveBoxData);
        } else {
          final recursiveBoxData = _processBox(boxData);
          byteBuilder.add(intToUint32(recursiveBoxData.length + 8));
          byteBuilder.add(box.type.codeUnits);
          byteBuilder.add(recursiveBoxData);
        }
      } else {
        byteBuilder.add(intToUint32(boxData.length + 8));
        byteBuilder.add(box.type.codeUnits);
        byteBuilder.add(boxData);
      }
    }

    return byteBuilder.toBytes();
  }

  Uint8List _replaceMetadata(Uint8List data) {
    final ilstBuilder = BytesBuilder();

    if (mp4metadata.title != null) {
      ilstBuilder.add(_buildStringTag("©nam", mp4metadata.title!));
    }
    if (mp4metadata.artist != null) {
      ilstBuilder.add(_buildStringTag("©ART", mp4metadata.artist!));
    }
    if (mp4metadata.album != null) {
      ilstBuilder.add(_buildStringTag("©alb", mp4metadata.album!));
    }
    if (mp4metadata.genre != null) {
      ilstBuilder.add(_buildStringTag("©gen", mp4metadata.genre!));
    }
    if (mp4metadata.year != null) {
      ilstBuilder
          .add(_buildStringTag("©day", mp4metadata.year!.year.toString()));
    }
    if (mp4metadata.lyrics != null) {
      ilstBuilder.add(_buildStringTag("©lyr", mp4metadata.lyrics!));
    }

    if (mp4metadata.picture != null) {
      final covrTag = _buildCovrTag(mp4metadata.picture!);
      if (covrTag != null) {
        ilstBuilder.add(covrTag);
      }
    }

    if (mp4metadata.trackNumber != null) {
      ilstBuilder.add(_buildIntegerTag(
          "trkn", mp4metadata.trackNumber!, mp4metadata.totalTracks));
    }
    if (mp4metadata.discNumber != null) {
      ilstBuilder.add(_buildIntegerTag(
          "disk", mp4metadata.discNumber!, mp4metadata.totalDiscs));
    }

    return ilstBuilder.toBytes();
  }

  Uint8List _buildStringTag(String tagType, String value) {
    final valueBytes = utf8.encode(value);

    // --- Build the inner 'data' box ---
    // size (4 bytes) + 'data' (4 bytes) + version/flags (4 bytes) + locale (4 bytes) + value
    final dataBoxSize = 8 + 4 + 4 + valueBytes.length;
    final dataBuilder = BytesBuilder();
    dataBuilder.add(intToUint32(dataBoxSize)); // data box size
    dataBuilder.add("data".codeUnits); // data box type
    dataBuilder.add(intToUint32(1)); // version=0, flags=1 (UTF-8)
    dataBuilder.add(intToUint32(0)); // locale=0
    dataBuilder.add(valueBytes); // the actual string data

    // --- Build the outer tag box (e.g., ©nam) ---
    final dataBoxBytes = dataBuilder.toBytes();
    final tagBoxSize = 8 + dataBoxBytes.length;
    final tagBuilder = BytesBuilder();
    tagBuilder.add(intToUint32(tagBoxSize));
    tagBuilder.add(tagType.codeUnits);
    tagBuilder.add(dataBoxBytes);

    return tagBuilder.toBytes();
  }

  Uint8List? _buildCovrTag(Picture picture) {
    int dataTypeFlag;
    if (picture.mimetype.toLowerCase() == 'image/jpeg') {
      dataTypeFlag = 13; // JPEG data type
    } else if (picture.mimetype.toLowerCase() == 'image/png') {
      dataTypeFlag = 14; // PNG data type
    } else {
      print(
          "Warning: Unsupported picture mime type for 'covr' tag: ${picture.mimetype}. Skipping cover art.");
      return null; // Unsupported type
    }

    final valueBytes = picture.bytes;

    // --- Build the inner 'data' box ---
    // size (4) + 'data' (4) + version/flags (4, contains type) + locale (4) + value
    final dataBoxSize = 8 + 4 + 4 + valueBytes.length;
    final dataBuilder = BytesBuilder();
    dataBuilder.add(intToUint32(dataBoxSize)); // data box size
    dataBuilder.add("data".codeUnits);
    dataBuilder.add(intToUint32(dataTypeFlag)); // version=0, flags=dataTypeFlag
    dataBuilder.add(intToUint32(0)); // locale=0
    dataBuilder.add(valueBytes);

    // --- Build the outer 'covr' tag box ---
    final dataBoxBytes = dataBuilder.toBytes();
    final tagBoxSize = 8 + dataBoxBytes.length;
    final tagBuilder = BytesBuilder();
    tagBuilder.add(intToUint32(tagBoxSize));
    tagBuilder.add("covr".codeUnits);
    tagBuilder.add(dataBoxBytes);

    return tagBuilder.toBytes();
  }

  Uint8List _buildIntegerTag(String tagType, int current, [int? total]) {
    final dataBuilder = BytesBuilder();

    final valueBytes = BytesBuilder();
    valueBytes.add([0x00, 0x00]); // reserved
    valueBytes.add(intToUint16(current));
    valueBytes.add(intToUint16(total ?? 0));
    valueBytes.add([0x00, 0x00]); // reserved

    final fullData = valueBytes.toBytes();

    final dataBoxSize = 8 + 4 + 4 + fullData.length;
    dataBuilder.add(intToUint32(dataBoxSize));
    dataBuilder.add("data".codeUnits);
    dataBuilder.add(intToUint32(0)); // version=0, flags=0 (binary)
    dataBuilder.add(intToUint32(0)); // locale
    dataBuilder.add(fullData);

    final dataBox = dataBuilder.toBytes();
    final tagBoxSize = 8 + dataBox.length;

    final tagBuilder = BytesBuilder();
    tagBuilder.add(intToUint32(tagBoxSize));
    tagBuilder.add(tagType.codeUnits);
    tagBuilder.add(dataBox);

    return tagBuilder.toBytes();
  }

  /// A box (or atom) header uses 8 bytes
  ///
  /// [0...3] -> box size (header + body)
  /// [4...7] -> box name (ASCII)
  BoxHeader _readBox(Uint8List headerBytes) {
    final boxSize = getUint32(headerBytes.sublist(0, 4));
    final boxNameBytes = headerBytes.sublist(4);

    return BoxHeader(boxSize, String.fromCharCodes(boxNameBytes));
  }
}
