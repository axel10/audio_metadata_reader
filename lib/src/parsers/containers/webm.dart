import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/parsers/tags/tag_parser.dart';

/// A parser for WebM / Matroska (MKV/MKA) audio containers.
///
/// WebM and Matroska files are structured using the EBML (Extensible Binary Meta Language)
/// format, which is a binary XML-like format. Each element in EBML consists of:
/// 1. Element ID (Variable-Length Integer)
/// 2. Element Size (Variable-Length Integer)
/// 3. Element Payload/Data
///
/// This parser reads elements sequentially and skips blocks we don't care about
/// (like `Cluster` containing actual audio frames) to quickly extract:
/// - Segment Info (ID 0x1549A966) -> TimecodeScale & Duration
/// - Tracks (ID 0x1654AE6B) -> Audio properties (Sample rate, Channels, Bit depth)
/// - Tags (ID 0x1254C367) -> Matroska metadata tags (Title, Artist, Album, etc.)
/// - Attachments (ID 0x1941A469) -> Cover art images
class WebmParser extends TagParser<WebmMetadata> {
  /// The metadata model instance that will be populated.
  final metadata = WebmMetadata();

  /// Constructor.
  WebmParser({super.fetchImage = false});

  @override
  WebmMetadata parse(RandomAccessFile reader) {
    reader.setPositionSync(0);

    // 1. Verify EBML Header (ID: 0x1A45DFA3)
    final firstId = _readId(reader);
    if (firstId != 0x1A45DFA3) {
      throw Exception("Invalid WebM/Matroska file: missing EBML header");
    }

    final headerSize = _readSize(reader);
    final headerEnd = reader.positionSync() + headerSize;

    bool isDocTypeSupported = false;
    _parseContainer(reader, headerEnd, (id, size) {
      if (id == 0x4282) { // DocType
        final docType = _readString(reader, size);
        if (docType == "webm" || docType == "matroska") {
          isDocTypeSupported = true;
        }
      }
    });

    if (!isDocTypeSupported) {
      // We will still attempt parsing but log/warn or let it proceed.
    }

    // Move to the end of the EBML header to start searching for Segment
    reader.setPositionSync(headerEnd);

    // 2. Find Segment (ID: 0x18538067)
    final segmentId = _readId(reader);
    if (segmentId != 0x18538067) {
      throw Exception("Invalid WebM/Matroska file: missing Segment");
    }

    final segmentSize = _readSize(reader);
    final segmentEnd = segmentSize == -1 ? reader.lengthSync() : (reader.positionSync() + segmentSize);

    final audioTrackInfo = <String, dynamic>{};
    final tags = <String, String>{};

    // 3. Scan the elements inside the Segment
    _parseContainer(reader, segmentEnd, (id, size) {
      if (id == 0x1549A966) { // Info (Segment Information)
        int timecodeScale = 1000000; // Default: 1ms (1,000,000 ns)
        double durationVal = 0.0;

        _parseContainer(reader, reader.positionSync() + size, (infoId, infoSize) {
          if (infoId == 0x2AD7B1) { // TimecodeScale
            timecodeScale = _readUint(reader, infoSize);
          } else if (infoId == 0x4489) { // Duration (expressed as float multiplier of TimecodeScale)
            durationVal = _readFloat(reader, infoSize);
          } else if (infoId == 0x7BA9) { // Title
            metadata.title = _readUtf8String(reader, infoSize);
          }
        });

        if (durationVal > 0) {
          // Duration in ns = durationVal * timecodeScale
          // Duration in ms = durationVal * timecodeScale / 1,000,000
          metadata.duration = Duration(
            milliseconds: (durationVal * timecodeScale / 1000000).round(),
          );
        }
      } else if (id == 0x1654AE6B) { // Tracks
        _parseContainer(reader, reader.positionSync() + size, (tracksId, tracksSize) {
          if (tracksId == 0xAE) { // TrackEntry
            _parseTrackEntry(reader, reader.positionSync() + tracksSize, audioTrackInfo);
          }
        });
      } else if (id == 0x1254C367) { // Tags
        _parseContainer(reader, reader.positionSync() + size, (tagsId, tagsSize) {
          if (tagsId == 0x7373) { // Tag
            _parseContainer(reader, reader.positionSync() + tagsSize, (tagId, tagSize) {
              if (tagId == 0x67C8) { // SimpleTag
                _parseSimpleTag(reader, reader.positionSync() + tagSize, tags);
              }
            });
          }
        });
      } else if (id == 0x1941A469) { // Attachments
        _parseContainer(reader, reader.positionSync() + size, (attachmentsId, attachmentsSize) {
          if (attachmentsId == 0x61A7) { // AttachedFile
            _parseAttachedFile(reader, reader.positionSync() + attachmentsSize, metadata.pictures);
          }
        });
      }
    });

    // 4. Map collected tags to WebmMetadata properties
    _mapTags(tags);

    // 5. Fill Audio Properties
    if (audioTrackInfo['samplingFrequency'] != null) {
      metadata.sampleRate = (audioTrackInfo['samplingFrequency'] as double).round();
    }

    // Estimate/determine bitrate
    if (metadata.duration != null && metadata.duration != Duration.zero) {
      if (tags.containsKey("BITRATE")) {
        metadata.bitrate = int.tryParse(tags["BITRATE"]!);
      } else if (tags.containsKey("BPS")) { // Bits Per Second tag often found in Matroska files
        metadata.bitrate = int.tryParse(tags["BPS"]!);
      } else {
        // Average bitrate = (total file size in bits) / (duration in seconds)
        final sizeInBits = reader.lengthSync() * 8;
        final durationSec = metadata.duration!.inMilliseconds / 1000.0;
        if (durationSec > 0) {
          metadata.bitrate = (sizeInBits / durationSec).round();
        }
      }
    }

    metadata.hasArtwork = metadata.hasArtwork || metadata.pictures.isNotEmpty;

    return metadata;
  }

  /// Parses a TrackEntry element to locate the first audio track's properties.
  void _parseTrackEntry(RandomAccessFile reader, int endOffset, Map<String, dynamic> audioTrackInfo) {
    int? trackType;
    String? codecId;
    int? channels;
    double? samplingFrequency;
    int? bitDepth;

    _parseContainer(reader, endOffset, (id, size) {
      if (id == 0x83) { // TrackType (1: video, 2: audio, 3: complex, etc.)
        trackType = _readUint(reader, size);
      } else if (id == 0x86) { // CodecID
        codecId = _readString(reader, size);
      } else if (id == 0xE1) { // Audio
        _parseContainer(reader, reader.positionSync() + size, (audioId, audioSize) {
          if (audioId == 0xB5) { // SamplingFrequency
            samplingFrequency = _readFloat(reader, audioSize);
          } else if (audioId == 0x9F) { // Channels
            channels = _readUint(reader, audioSize);
          } else if (audioId == 0x6264) { // BitDepth
            bitDepth = _readUint(reader, audioSize);
          }
        });
      }
    });

    // Only collect info if it is an audio track
    if (trackType == 2) {
      audioTrackInfo['codecId'] = codecId;
      audioTrackInfo['channels'] = channels;
      audioTrackInfo['samplingFrequency'] = samplingFrequency ?? 8000.0; // default standard if missing
      audioTrackInfo['bitDepth'] = bitDepth;
    }
  }

  /// Recursively parses SimpleTag elements.
  /// SimpleTags contain a `TagName` and a `TagString` or `TagBinary`.
  void _parseSimpleTag(RandomAccessFile reader, int endOffset, Map<String, String> tags) {
    String? currentName;
    String? currentString;

    _parseContainer(reader, endOffset, (id, size) {
      if (id == 0x45A3) { // TagName
        currentName = _readString(reader, size).trim().toUpperCase();
      } else if (id == 0x4487) { // TagString (UTF-8 encoded value)
        currentString = _readUtf8String(reader, size);
      } else if (id == 0x67C8) { // Nested SimpleTag (recursively parse)
        _parseSimpleTag(reader, reader.positionSync() + size, tags);
      }
    });

    if (currentName != null && currentString != null) {
      tags[currentName!] = currentString!;
    }
  }

  /// Parses an AttachedFile element to fetch cover art or attachments.
  void _parseAttachedFile(RandomAccessFile reader, int endOffset, List<Picture> pictures) {
    String? fileName;
    String? mimeType;
    Uint8List? fileData;

    _parseContainer(reader, endOffset, (id, size) {
      if (id == 0x466E) { // FileName
        fileName = _readUtf8String(reader, size);
      } else if (id == 0x4660) { // FileMimeType
        mimeType = _readString(reader, size);
      } else if (id == 0x465C) { // FileData (Binary)
        if (fetchImage) {
          fileData = _readBinary(reader, size);
        } else {
          reader.setPositionSync(reader.positionSync() + size);
        }
      }
    });

    if (mimeType != null && mimeType!.startsWith("image/")) {
      metadata.hasArtwork = true;
    }

    if (fileData != null && mimeType != null) {
      PictureType type = PictureType.coverFront;
      if (fileName != null) {
        final nameLower = fileName!.toLowerCase();
        if (nameLower.contains("back")) {
          type = PictureType.coverBack;
        }
      }
      pictures.add(Picture(fileData!, mimeType!, type));
    }
  }

  /// Maps parsed string tags from Matroska/WebM key names to typed WebmMetadata properties.
  void _mapTags(Map<String, String> tags) {
    metadata.title ??= tags['TITLE'];
    metadata.artist = tags['ARTIST'] ?? tags['LEAD_PERFORMER'];
    metadata.album = tags['ALBUM'];
    metadata.albumArtist = tags['ALBUM_ARTIST'] ?? tags['ALBUMARTIST'];
    metadata.lyric = tags['LYRICS'];
    metadata.comment = tags['COMMENT'] ?? tags['DESCRIPTION'];
    metadata.composer = tags['COMPOSER'];
    metadata.copyright = tags['COPYRIGHT'];
    metadata.encoder = tags['ENCODER'] ?? tags['ENCODED_BY'];

    final dateStr = tags['DATE_RELEASE'] ?? tags['YEAR'] ?? tags['DATE'];
    if (dateStr != null) {
      metadata.date = DateTime.tryParse(dateStr);
    }

    final trackStr = tags['TRACK_NUMBER'] ?? tags['TRACKNUMBER'] ?? tags['TRACK'] ?? tags['PART_NUMBER'];
    if (trackStr != null) {
      metadata.trackNumber = int.tryParse(trackStr);
    }

    final trackTotalStr = tags['TOTAL_TRACKS'] ?? tags['TRACKTOTAL'] ?? tags['TRACK_TOTAL'];
    if (trackTotalStr != null) {
      metadata.trackTotal = int.tryParse(trackTotalStr);
    }

    final discStr = tags['DISC_NUMBER'] ?? tags['DISCNUMBER'] ?? tags['DISC'];
    if (discStr != null) {
      metadata.discNumber = int.tryParse(discStr);
    }

    final discTotalStr = tags['TOTAL_DISCS'] ?? tags['DISCTOTAL'] ?? tags['DISC_TOTAL'];
    if (discTotalStr != null) {
      metadata.discTotal = int.tryParse(discTotalStr);
    }

    if (tags.containsKey('GENRE')) {
      metadata.genres.add(tags['GENRE']!);
    }

    if (tags.containsKey('LANGUAGE')) {
      metadata.language.add(tags['LANGUAGE']!);
    }
  }

  // --- EBML Parsing Utilities ---

  /// Determines if a file looks like an EBML container.
  /// Checking if first 4 bytes matches the EBML Header ID 0x1A45DFA3.
  static bool canUserParser(RandomAccessFile reader) {
    reader.setPositionSync(0);
    final header = reader.readSync(4);
    if (header.length < 4) return false;
    return header[0] == 0x1A && header[1] == 0x45 && header[2] == 0xDF && header[3] == 0xA3;
  }

  /// Sequentially parses sub-elements inside a parent/container element.
  void _parseContainer(RandomAccessFile reader, int endOffset, void Function(int id, int size) callback) {
    while (true) {
      if (endOffset != -1 && reader.positionSync() >= endOffset) {
        break;
      }
      int id;
      try {
        id = _readId(reader);
      } catch (e) {
        break; // EOF or read failure
      }
      if (id == -1) break;
      int size = _readSize(reader);

      final currentPos = reader.positionSync();
      callback(id, size);

      // If the callback didn't consume the element payload, skip over it.
      if (reader.positionSync() == currentPos && size > 0) {
        reader.setPositionSync(currentPos + size);
      }
    }
  }

  /// Reads an EBML Variable-Length Integer (VINT) representing the Element ID.
  /// Unlike standard VINTs, the width marker bit is preserved in Element IDs.
  int _readId(RandomAccessFile reader) {
    int firstByte = reader.readByteSync();
    if (firstByte == -1) return -1;
    if (firstByte == 0) {
      throw Exception("Unsupported VINT ID length (0x00)");
    }
    int length = 1;
    int mask = 0x80;
    while ((firstByte & mask) == 0) {
      length++;
      mask >>= 1;
    }
    int id = firstByte;
    for (int i = 1; i < length; i++) {
      int b = reader.readByteSync();
      if (b == -1) throw Exception("Unexpected EOF in EBML ID");
      id = (id << 8) | b;
    }
    return id;
  }

  /// Reads an EBML Variable-Length Integer (VINT) representing the Element Size.
  /// The width marker bit is cleared to calculate the integer value.
  int _readSize(RandomAccessFile reader) {
    int firstByte = reader.readByteSync();
    if (firstByte == -1) return -1;
    if (firstByte == 0) {
      throw Exception("Unsupported VINT size length (0x00)");
    }
    int length = 1;
    int mask = 0x80;
    while ((firstByte & mask) == 0) {
      length++;
      mask >>= 1;
    }

    int val = firstByte & (mask - 1);
    bool allOnes = (firstByte & (mask - 1)) == (mask - 1);

    for (int i = 1; i < length; i++) {
      int b = reader.readByteSync();
      if (b == -1) throw Exception("Unexpected EOF in EBML Size");
      val = (val << 8) | b;
      if (b != 0xFF) {
        allOnes = false;
      }
    }

    // In EBML, if all bits of a VINT size are 1, it represents an unknown/infinite size.
    if (allOnes) {
      return -1;
    }
    return val;
  }

  /// Reads an unsigned big-endian integer of the specified size.
  int _readUint(RandomAccessFile reader, int size) {
    int val = 0;
    for (int i = 0; i < size; i++) {
      int b = reader.readByteSync();
      if (b == -1) throw Exception("Unexpected EOF in EBML uint");
      val = (val << 8) | b;
    }
    return val;
  }

  /// Reads a big-endian floating point number (4 or 8 bytes).
  double _readFloat(RandomAccessFile reader, int size) {
    final bytes = reader.readSync(size);
    if (bytes.length < size) throw Exception("Unexpected EOF in EBML float");
    final byteData = ByteData.sublistView(bytes);
    if (size == 4) {
      return byteData.getFloat32(0, Endian.big);
    } else if (size == 8) {
      return byteData.getFloat64(0, Endian.big);
    } else if (size == 0) {
      return 0.0;
    } else {
      throw Exception("Unsupported EBML float size: $size");
    }
  }

  /// Reads an ASCII string, stripping any trailing null-padding.
  String _readString(RandomAccessFile reader, int size) {
    if (size == 0) return "";
    final bytes = reader.readSync(size);
    if (bytes.length < size) throw Exception("Unexpected EOF in EBML string");
    int len = bytes.length;
    while (len > 0 && bytes[len - 1] == 0) {
      len--;
    }
    return String.fromCharCodes(bytes.sublist(0, len));
  }

  /// Reads a UTF-8 string, stripping any trailing null-padding.
  String _readUtf8String(RandomAccessFile reader, int size) {
    if (size == 0) return "";
    final bytes = reader.readSync(size);
    if (bytes.length < size) throw Exception("Unexpected EOF in EBML utf8");
    int len = bytes.length;
    while (len > 0 && bytes[len - 1] == 0) {
      len--;
    }
    return const Utf8Decoder(allowMalformed: true).convert(bytes.sublist(0, len));
  }

  /// Reads raw binary bytes.
  Uint8List _readBinary(RandomAccessFile reader, int size) {
    final bytes = reader.readSync(size);
    if (bytes.length < size) throw Exception("Unexpected EOF in EBML binary");
    return bytes;
  }
}
