import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/utils/bit_manipulator.dart';
import 'package:audio_metadata_reader/src/writers/base_writer.dart';

/// Writer for APEv2 metadata tags.
///
/// APEv2 tags are written at the end of the audio file, optionally followed by an ID3v1 trailer.
/// This writer:
/// 1. Finds and strips any existing APEv2 tag (header + items + footer) and trailing ID3v1 tag.
/// 2. Serializes updated ApeMetadata fields into APEv2 item blocks (UTF-8 strings or binary picture bytes).
/// 3. Appends a 32-byte APEv2 header, the compiled items, and a 32-byte APEv2 footer.
/// 4. Re-appends the ID3v1 tag if it originally existed in the file.
class ApeWriter extends BaseMetadataWriter<ApeMetadata> {
  @override
  void write(File file, ApeMetadata metadata) {
    final reader = file.openSync();

    try {
      final length = reader.lengthSync();
      int? footerOffset = _findFooterOffset(reader, length);

      int tagStartOffset = length;
      Uint8List? id3v1Trailer;

      // Check for ID3v1 trailer at the very end of the file
      if (length >= 128 && _isId3v1At(reader, length - 128)) {
        reader.setPositionSync(length - 128);
        id3v1Trailer = reader.readSync(128);
        tagStartOffset = length - 128;
      }

      if (footerOffset != null) {
        // Read APEv2 footer to identify the tag size and if a header is present
        reader.setPositionSync(footerOffset);
        final footerBytes = reader.readSync(32);

        final tagSize = getUint32LE(footerBytes.sublist(12, 16));
        final flags = getUint32LE(footerBytes.sublist(20, 24));
        final headerPresent = (flags & 0x80000000) != 0;

        // tagStartOffset is where the APEv2 tag begins
        int oldTagStart = footerOffset - (tagSize - 32);
        if (headerPresent) {
          final candidateHeaderOffset = footerOffset - tagSize;
          if (candidateHeaderOffset >= 0 &&
              _isApeFooterAt(reader, candidateHeaderOffset)) {
            oldTagStart = candidateHeaderOffset;
          }
        }
        tagStartOffset = oldTagStart;
      }

      // Extract the audio payload (original file minus old APE/ID3 tags)
      reader.setPositionSync(0);
      final audioPayload = reader.readSync(tagStartOffset);
      reader.closeSync();

      // Compile the new APEv2 items list
      final itemChunks = BytesBuilder();
      int itemCount = 0;

      void addText(String key, String? value) {
        if (value != null && value.isNotEmpty) {
          itemChunks.add(_buildTextItem(key, value));
          itemCount++;
        }
      }

      void addMultiText(String key, List<String> values) {
        final filtered = values.where((v) => v.isNotEmpty).toList();
        if (filtered.isNotEmpty) {
          itemChunks.add(_buildMultiTextItem(key, filtered));
          itemCount++;
        }
      }

      // Standard ApeMetadata text mappings
      addText('Title', metadata.title);
      addText('Artist', metadata.artist);
      addText('Album', metadata.album);
      addText('Album Artist', metadata.albumArtist);
      addText('Lyrics', metadata.lyric);
      addText('Comment', metadata.comment);
      addText('Composer', metadata.composer);
      addText('Copyright', metadata.copyright);
      addText('EncodedBy', metadata.encodedBy);

      // Track configuration
      if (metadata.trackNumber != null && metadata.trackTotal != null) {
        addText('Track', '${metadata.trackNumber}/${metadata.trackTotal}');
      } else if (metadata.trackNumber != null) {
        addText('Track', '${metadata.trackNumber}');
      } else if (metadata.trackTotal != null) {
        addText('TrackTotal', '${metadata.trackTotal}');
      }

      // Disc configuration
      if (metadata.discNumber != null && metadata.discTotal != null) {
        addText('Disc', '${metadata.discNumber}/${metadata.discTotal}');
      } else if (metadata.discNumber != null) {
        addText('Disc', '${metadata.discNumber}');
      } else if (metadata.discTotal != null) {
        addText('DiscTotal', '${metadata.discTotal}');
      }

      // Date configuration
      if (metadata.date != null) {
        addText('Year', '${metadata.date!.year}');
      }

      // Repeated lists
      addMultiText('Genre', metadata.genres);
      addMultiText('Performer', metadata.performer);
      addMultiText('Language', metadata.language);

      // Custom/Unknown mappings
      metadata.unknowns.forEach((key, value) {
        final normalized = key.trim().toUpperCase();
        // Prevent rewriting standard fields
        if (normalized != 'TITLE' &&
            normalized != 'ARTIST' &&
            normalized != 'ALBUM' &&
            normalized != 'ALBUM_ARTIST' &&
            normalized != 'ALBUMARTIST' &&
            normalized != 'TRACK' &&
            normalized != 'TRACKNUMBER' &&
            normalized != 'TRACKTOTAL' &&
            normalized != 'TOTALTRACKS' &&
            normalized != 'DISC' &&
            normalized != 'DISCNUMBER' &&
            normalized != 'DISCTOTAL' &&
            normalized != 'TOTALDISCS' &&
            normalized != 'YEAR' &&
            normalized != 'DATE' &&
            normalized != 'GENRE' &&
            normalized != 'LYRIC' &&
            normalized != 'LYRICS' &&
            normalized != 'COMMENT' &&
            normalized != 'COMPOSER' &&
            normalized != 'COPYRIGHT' &&
            normalized != 'ENCODEDBY' &&
            normalized != 'ENCODED_BY' &&
            normalized != 'PERFORMER' &&
            normalized != 'LANGUAGE' &&
            normalized != 'LANG') {
          addText(key, value);
        }
      });

      // Binary items (pictures)
      for (final picture in metadata.pictures) {
        if (picture.bytes.isNotEmpty) {
          final isBack = picture.pictureType == PictureType.coverBack;
          final key = isBack ? 'Cover Art (Back)' : 'Cover Art (Front)';
          final filename = picture.mimetype == 'image/png' ? 'cover.png' : 'cover.jpg';
          itemChunks.add(_buildBinaryItem(key, filename, picture.bytes));
          itemCount++;
        }
      }

      final itemsBytes = itemChunks.toBytes();
      // Tag size includes all items and footer (excludes the 32-byte header itself)
      final tagSize = itemsBytes.length + 32;

      // 32-byte header
      final headerBuilder = BytesBuilder();
      headerBuilder.add(ascii.encode('APETAGEX'));
      headerBuilder.add(intToUint32LE(2000)); // Version 2.000
      headerBuilder.add(intToUint32LE(tagSize));
      headerBuilder.add(intToUint32LE(itemCount));
      headerBuilder.add(intToUint32LE(0xA0000000)); // Has header + Has footer + Is header
      headerBuilder.add(List.filled(8, 0));

      // 32-byte footer
      final footerBuilder = BytesBuilder();
      footerBuilder.add(ascii.encode('APETAGEX'));
      footerBuilder.add(intToUint32LE(2000));
      footerBuilder.add(intToUint32LE(tagSize));
      footerBuilder.add(intToUint32LE(itemCount));
      footerBuilder.add(intToUint32LE(0x80000000)); // Has header + Has footer + Is footer (not header)
      footerBuilder.add(List.filled(8, 0));

      // Combine all payload sections
      final finalBuilder = BytesBuilder();
      finalBuilder.add(audioPayload);
      finalBuilder.add(headerBuilder.toBytes());
      finalBuilder.add(itemsBytes);
      finalBuilder.add(footerBuilder.toBytes());
      if (id3v1Trailer != null) {
        finalBuilder.add(id3v1Trailer);
      }

      file.writeAsBytesSync(finalBuilder.toBytes(), flush: true);
    } catch (e) {
      try {
        reader.closeSync();
      } catch (_) {}
      rethrow;
    }
  }

  int? _findFooterOffset(RandomAccessFile reader, int length) {
    if (length < 32) return null;

    final endOffset = length - 32;
    if (_isApeFooterAt(reader, endOffset)) {
      return endOffset;
    }

    if (length >= 160 && _isId3v1At(reader, length - 128)) {
      final beforeId3Offset = length - 160;
      if (_isApeFooterAt(reader, beforeId3Offset)) {
        return beforeId3Offset;
      }
    }
    return null;
  }

  bool _isApeFooterAt(RandomAccessFile reader, int offset) {
    if (offset < 0 || offset + 8 > reader.lengthSync()) return false;
    reader.setPositionSync(offset);
    final sig = reader.readSync(8);
    return sig.length == 8 && String.fromCharCodes(sig) == 'APETAGEX';
  }

  bool _isId3v1At(RandomAccessFile reader, int offset) {
    if (offset < 0 || offset + 3 > reader.lengthSync()) return false;
    reader.setPositionSync(offset);
    final marker = reader.readSync(3);
    return marker.length == 3 && String.fromCharCodes(marker) == 'TAG';
  }

  Uint8List _buildTextItem(String key, String value) {
    final keyBytes = ascii.encode(key);
    final valueBytes = utf8.encode(value);

    final builder = BytesBuilder();
    builder.add(intToUint32LE(valueBytes.length));
    builder.add(intToUint32LE(0)); // Flags = 0 (text, read-write)
    builder.add(keyBytes);
    builder.addByte(0); // Key NUL terminator
    builder.add(valueBytes);
    return builder.toBytes();
  }

  Uint8List _buildMultiTextItem(String key, List<String> values) {
    final joined = values.join('\u0000');
    return _buildTextItem(key, joined);
  }

  Uint8List _buildBinaryItem(String key, String filename, Uint8List imageBytes) {
    final keyBytes = ascii.encode(key);
    final filenameBytes = ascii.encode(filename);

    final payloadBuilder = BytesBuilder();
    payloadBuilder.add(filenameBytes);
    payloadBuilder.addByte(0); // NUL terminator after filename/description
    payloadBuilder.add(imageBytes);

    final payload = payloadBuilder.toBytes();

    final builder = BytesBuilder();
    builder.add(intToUint32LE(payload.length));
    builder.add(intToUint32LE(2)); // Flags = 2 (binary, read-write, bits 1..2 = 01)
    builder.add(keyBytes);
    builder.addByte(0); // Key NUL terminator
    builder.add(payload);
    return builder.toBytes();
  }
}
