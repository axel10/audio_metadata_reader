import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_metadata_reader/src/constants/id3_genres.dart';
import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/utils/bit_manipulator.dart';
import 'package:audio_metadata_reader/src/utils/buffer.dart';
import 'package:charset/charset.dart';
import 'tag_parser.dart';

const utf8Decoder = Utf8Decoder();
const utf16Decoder = Utf16Decoder();
const latin1Decoder = Latin1Decoder();

class _Id3Header {
  final int majorVersion;
  final int flags;
  final int size;

  const _Id3Header({
    required this.majorVersion,
    required this.flags,
    required this.size,
  });
}

class _TagCursor {
  final Uint8List bytes;
  int position = 0;

  _TagCursor(this.bytes);

  int get remaining => bytes.length - position;

  bool get isEof => remaining <= 0;

  Uint8List read(int size) {
    final end = position + size;
    if (end > bytes.length) {
      throw RangeError('Attempted to read beyond the end of the ID3 tag');
    }

    final result = bytes.sublist(position, end);
    position = end;
    return result;
  }

  Uint8List readAtMost(int size) {
    final end = (position + size > bytes.length) ? bytes.length : position + size;
    final result = bytes.sublist(position, end);
    position = end;
    return result;
  }

  void skip(int size) {
    position = (position + size > bytes.length) ? bytes.length : position + size;
  }

  Uint8List peek(int size) {
    final end = (position + size > bytes.length) ? bytes.length : position + size;
    return bytes.sublist(position, end);
  }
}

class ID3v3Frame {
  final String id;
  final int size;
  final Uint8List flags;
  final int headerSize;

  ID3v3Frame(this.id, this.size, this.flags, this.headerSize);
}

///
/// Metadata frame defined in the ID3 tag
///
int _delimiterLength(int encoding) {
  return encoding == 1 || encoding == 2 ? 2 : 1;
}

int _synchsafeToInt(Uint8List bytes) {
  if (bytes.length < 4) {
    return 0;
  }

  return (bytes[3] & 0x7F) |
      ((bytes[2] & 0x7F) << 7) |
      ((bytes[1] & 0x7F) << 14) |
      ((bytes[0] & 0x7F) << 21);
}

Uint8List _decodeUnsynchronization(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  int i = 0;

  while (i < bytes.length) {
    final byte = bytes[i];
    out.add([byte]);

    if (byte == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
      i += 2;
      continue;
    }

    i++;
  }

  return out.toBytes();
}

bool _isSupportedHeaderFlags(int majorVersion, int flags) {
  if (majorVersion == 4) {
    return (flags & 0x0F) == 0;
  }

  return (flags & 0x1F) == 0;
}

_Id3Header? _parseHeader(Uint8List headerBytes) {
  if (headerBytes.length < 10) {
    return null;
  }

  if (headerBytes[0] != 0x49 || headerBytes[1] != 0x44 || headerBytes[2] != 0x33) {
    return null;
  }

  final majorVersion = headerBytes[3];
  if (majorVersion != 2 && majorVersion != 3 && majorVersion != 4) {
    return null;
  }

  final flags = headerBytes[5];
  if (!_isSupportedHeaderFlags(majorVersion, flags)) {
    return null;
  }

  return _Id3Header(
    majorVersion: majorVersion,
    flags: flags,
    size: _synchsafeToInt(headerBytes.sublist(6, 10)),
  );
}

int _findDelimiter(Uint8List bytes, int start, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (int i = start; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) {
        return i;
      }
    }
    return -1;
  }

  return bytes.indexOf(0, start);
}

String _decodeUtf16Bytes(Uint8List bytes, {required bool bigEndianDefault}) {
  if (bytes.isEmpty) {
    return "";
  }

  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return utf16Decoder.decodeUtf16Le(bytes.sublist(2));
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return utf16Decoder.decodeUtf16Be(bytes.sublist(2));
    }
  }

  final primary = bigEndianDefault
      ? utf16Decoder.decodeUtf16Be(bytes)
      : utf16Decoder.decodeUtf16Le(bytes);
  final secondary = bigEndianDefault
      ? utf16Decoder.decodeUtf16Le(bytes)
      : utf16Decoder.decodeUtf16Be(bytes);

  if (primary.contains('\uFFFD') && !secondary.contains('\uFFFD')) {
    return secondary;
  }

  return primary;
}

String _decodeFrameText(Uint8List bytes, int encoding) {
  switch (encoding) {
    case 0:
      return latin1Decoder.convert(bytes);
    case 1:
      return _decodeUtf16Bytes(bytes, bigEndianDefault: false);
    case 2:
      return _decodeUtf16Bytes(bytes, bigEndianDefault: true);
    case 3:
      return utf8Decoder.convert(bytes);
    default:
      return "";
  }
}

String _decodeTextFrame(Uint8List information) {
  if (information.isEmpty) {
    return "";
  }

  final encoding = information.first;
  final content = information.sublist(1);
  final nullCharacterPosition = _findDelimiter(content, 0, encoding);
  final end = (nullCharacterPosition >= 0) ? nullCharacterPosition : content.length;

  return _decodeFrameText(content.sublist(0, end), encoding);
}

String getTextFromFrame(Uint8List information) {
  return _decodeTextFrame(information);
}

/// Custom metadata frame
/// Can be used my MusicBrainz for instance
class TXXXFrame {
  late final int encoding;
  late final String description;
  late final String information;

  TXXXFrame(Uint8List information) {
    int offset = 0;
    encoding = information[offset++];

    final descriptionEnd = _findDelimiter(information, offset, encoding);
    final descriptionBytes = information.sublist(
      offset,
      descriptionEnd >= 0 ? descriptionEnd : information.length,
    );
    offset = (descriptionEnd >= 0)
        ? descriptionEnd + _delimiterLength(encoding)
        : information.length;

    description = _decodeFrameText(descriptionBytes, encoding);
    this.information = _decodeFrameText(information.sublist(offset), encoding);
  }
}

///
/// Parser for the ID3 tags
///
///
/// https://teslabs.com/openplayer/docs/docs/specs/id3v2.3.0%20-%20ID3.org.pdf
///
class ID3v2Parser extends TagParser {
  final Mp3Metadata metadata = Mp3Metadata();
  late final Buffer buffer;

  static final _discRegex = RegExp(r"(\d+)/(\d+)");
  static final _trackRegex = RegExp(r"(\d+)/(\d+)");

  ID3v2Parser({fetchImage = false}) : super(fetchImage: fetchImage);

  @override
  ParserTag parse(RandomAccessFile reader) {
    reader.setPositionSync(0);
    buffer = Buffer(randomAccessFile: reader);

    try {
      final headerBytes = buffer.readAtMost(10);
      final header = _parseHeader(headerBytes);

      if (header == null) {
        return metadata;
      }

      final rawTagBytes = buffer.readAtMost(header.size);
      final tagBytes = getBit(header.flags, 7) == 1
          ? _decodeUnsynchronization(rawTagBytes)
          : rawTagBytes;
      final cursor = _TagCursor(tagBytes);

      if (header.majorVersion == 3 || header.majorVersion == 4) {
        // Extended headers are optional and can be malformed in the wild.
        if (getBit(header.flags, 6) == 1) {
          final extHeaderSizeBytes = cursor.readAtMost(4);
          if (extHeaderSizeBytes.length < 4) {
            return metadata;
          }

          final extendedHeaderSize = header.majorVersion == 4
              ? _synchsafeToInt(extHeaderSizeBytes)
              : getUint32(extHeaderSizeBytes);

          if (extendedHeaderSize <= 4) {
            return metadata;
          }

          cursor.skip(extendedHeaderSize - 4);
        }
      }

      while (!cursor.isEof) {
        final frame = getFrame(cursor, header.majorVersion);

        if (frame == null) {
          break;
        }

        if (frame.size <= 0 || frame.size > cursor.remaining) {
          break;
        }

        try {
          processFrame(cursor, frame.id, frame.size, header.majorVersion);
        } catch (_) {
          // The frame has already been consumed in most failure cases, so move
          // on and keep the rest of the tag readable.
        }
      }

      if (metadata.duration == null || metadata.duration == Duration.zero) {
        final mp3FrameHeader = _findFirstMp3Frame(buffer);

        if (mp3FrameHeader == null) {
          return metadata;
        }

        final mpegVersion = switch ((mp3FrameHeader[1] >> 3) & 0x3) {
          0x00 => 3,
          0x01 => -1,
          0x02 => 2,
          0x03 => 1,
          _ => -1
        };
        final mpegLayer = switch ((mp3FrameHeader[1] >> 1) & 0x3) {
          0 => -1,
          1 => 3,
          2 => 2,
          3 => 1,
          _ => -1,
        };

        final bitrateIndex = mp3FrameHeader[2] >> 4;
        final samplerateIndex = mp3FrameHeader[2] & 12 >> 0x3;

        metadata.samplerate = _getSampleRate(mpegVersion, samplerateIndex);
        metadata.bitrate = _getBitrate(mpegVersion, mpegLayer, bitrateIndex);

        // arbitrary choice.  Usually the `Xing` header is located after ~30 bytes
        // then the header size is about ~150 bytes.
        final possibleXingHeader = buffer.readAtMost(1500);

        int i = 0;
        while (i < possibleXingHeader.length && possibleXingHeader[i] == 0) {
          i++;
        }

        if ((i < possibleXingHeader.length - 11) &&
            possibleXingHeader[i] == 0x58 &&
            possibleXingHeader[i + 1] == 0X69 &&
            possibleXingHeader[i + 2] == 0x6E &&
            possibleXingHeader[i + 3] == 0x67) {
          // it's a VBR file (Variable Bit Rate)
          final xingFrameFlag = possibleXingHeader[i + 7] & 0x1;

          if (xingFrameFlag == 1) {
            final numberOfFrames =
                getUint32(possibleXingHeader.sublist(i + 8, i + 12));
            final samplesPerFrame =
                _getSamplePerFrame(mpegVersion, mpegLayer) ?? 0;
            final sampleRate = metadata.samplerate;

            if (sampleRate != null && sampleRate > 0 && samplesPerFrame > 0) {
              final totalSamples = numberOfFrames * samplesPerFrame;
              final durationInSeconds = totalSamples / sampleRate;

              final durationInMicroseconds =
                  (durationInSeconds * 1000000).toInt();
              metadata.duration = Duration(microseconds: durationInMicroseconds);
            }
          }
        } else {
          // it's a CBR file (Constant Bit Rate)
          if (metadata.bitrate != null && metadata.bitrate! > 0) {
            final fileSizeWithoutMetadata = reader.lengthSync() - rawTagBytes.length - 10;
            final durationInSeconds =
                (8 * fileSizeWithoutMetadata) / metadata.bitrate!;

            // Convert to microseconds
            final durationInMicroseconds = (durationInSeconds * 1000000).toInt();
            metadata.duration = Duration(microseconds: durationInMicroseconds);
          }
        }
      }

      return metadata;
    } finally {
      reader.closeSync();
    }
  }

  /// Search and return the first MP3 frame header.
  /// Returns null if none has been found.
  ///
  /// The MP3 frame has a magic word : 0xFFF or 0xFFE
  ///
  /// Sometimes the MP3 files contains blocks of 0x00 or 0xFF and relying on the magic word
  /// is not reliable anymore.
  ///
  /// To prevent false positives, we need to verify that the bytes after the potential
  /// valid word are correct. The MP3 specs specify several flags that must be set or not.
  ///
  /// Credit to [exiftool](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/MPEG.pm#L464)
  Uint8List? _findFirstMp3Frame(Buffer buffer) {
    Uint8List frameHeader = buffer.readAtMost(4);

    while (frameHeader.length == 4) {
      // Look for frame sync (0xFF followed by 3 bytes)
      if (frameHeader[0] == 0xFF) {
        int word = (frameHeader[0] << 24) |
            (frameHeader[1] << 16) |
            (frameHeader[2] << 8) |
            (frameHeader[3]);

        if ((word & 0xFFE00000) != 0xFFE00000) {
          frameHeader[0] = frameHeader[1];
          frameHeader[1] = frameHeader[2];
          frameHeader[2] = frameHeader[3];
          frameHeader[3] = buffer.read(1)[0];
          continue;
        }

        // Check for invalid MPEG version (01), layer (00), bitrate index (0000 or 1111),
        // reserved sampling frequency (11), reserved emphasis (10), and not Layer III if MP3
        if ((word & 0x180000) == 0x080000 || // reserved version ID
            (word & 0x060000) == 0x000000 || // reserved layer
            (word & 0x00F000) == 0x000000 || // free bitrate
            (word & 0x00F000) == 0x00F000 || // bad bitrate
            (word & 0x000C00) == 0x000C00 || // reserved sampling rate
            (word & 0x000003) == 0x000002) {
          frameHeader[0] = frameHeader[1];
          frameHeader[1] = frameHeader[2];
          frameHeader[2] = frameHeader[3];
          frameHeader[3] = buffer.read(1)[0];
          continue;
        }

        return frameHeader;
      }

      frameHeader[0] = frameHeader[1];
      frameHeader[1] = frameHeader[2];
      frameHeader[2] = frameHeader[3];
      frameHeader[3] = buffer.read(1)[0];
    }

    return null;
  }

  /// Process a frame.
  ///
  /// If the frame ID is not defined in the id3vX specs, then its content is dropped.
  void processFrame(_TagCursor cursor, String frameId, int size, int majorVersion) {
    // why do we duplicate the content in every block?
    // it's because the biggest thing to get in the cover
    // sometimes, we don't want to read so we have to read the content
    // at the very last time

    final isV22 = majorVersion == 2;

    final handlers = switch (frameId) {
      "APIC" || "PIC" => () {
          if (fetchImage) {
            final content = cursor.read(size);
            final picture = getPicture(content, isV22: isV22);
            metadata.pictures.add(picture);
          } else {
            cursor.skip(size);
          }
        },
      "TALB" || "TAL" => () {
          final content = cursor.read(size);
          metadata.album = getTextFromFrame(content);
        },
      "TBPM" => () {
          final content = cursor.read(size);
          metadata.bpm = getTextFromFrame(content);
        },
      "TCOP" || "TCP" => () {
          final content = cursor.read(size);
          metadata.copyrightMessage = getTextFromFrame(content);
        },
      "TCON" || "TCO" => () {
          final content = cursor.read(size);
          metadata.contentType = getTextFromFrame(content);
          final regex = RegExp(r"(\d+).*");
          final containRegex = RegExp(r";|/|\||,");

          if (metadata.contentType!.contains(containRegex)) {
            metadata.genres.addAll(metadata.contentType!
                .split(containRegex)
                .map((e) => e.trim())
                .toList());
          } else if (regex.hasMatch(metadata.contentType!)) {
            metadata.genres.add(id3Genres[
                    regex.allMatches(metadata.contentType!).first.group(0)!] ??
                "");
          } else if (metadata.contentType!.isNotEmpty) {
            metadata.genres.add(metadata.contentType!);
          }
        },
      "TCOM" || "TCM" => () {
          final content = cursor.read(size);
          metadata.composer = getTextFromFrame(content);
        },
      "TDAT" || "TDA" => () {
          final content = cursor.read(size);
          metadata.date = getTextFromFrame(content);
        },
      "TDLY" => () {
          final content = cursor.read(size);
          metadata.playlistDelay = getTextFromFrame(content);
        },
      "TENC" || "TEN" => () {
          final content = cursor.read(size);
          metadata.encodedBy = getTextFromFrame(content);
        },
      "TFLT" => () {
          final content = cursor.read(size);
          metadata.fileType = getTextFromFrame(content);
        },
      "TIME" || "TIM" => () {
          final content = cursor.read(size);
          metadata.time = getTextFromFrame(content);
        },
      "TIT1" || "TT1" => () {
          final content = cursor.read(size);
          metadata.contentGroupDescription = getTextFromFrame(content);
        },
      "TIT2" || "TT2" => () {
          final content = cursor.read(size);
          metadata.songName = getTextFromFrame(content);
        },
      "TIT3" || "TT3" => () {
          final content = cursor.read(size);
          metadata.subtitle = getTextFromFrame(content);
        },
      "TKEY" || "TKE" => () {
          final content = cursor.read(size);
          metadata.initialKey = getTextFromFrame(content);
        },
      "TLAN" || "TLA" => () {
          final content = cursor.read(size);
          metadata.languages = getTextFromFrame(content);
        },
      "TLEN" || "TLE" => () {
          final content = cursor.read(size);
          final time = int.tryParse(getTextFromFrame(content));

          if (time != null) {
            if ((time / 1000) < 1) {
              metadata.duration = Duration(seconds: time);
            } else {
              metadata.duration = Duration(milliseconds: time);
            }
          }
        },
      "TMED" || "TMT" => () {
          final content = cursor.read(size);
          metadata.mediatype = getTextFromFrame(content);
        },
      "TOAL" || "TOL" => () {
          final content = cursor.read(size);
          metadata.originalAlbum = getTextFromFrame(content);
        },
      "TOFN" || "TOF" => () {
          final content = cursor.read(size);
          metadata.originalFilename = getTextFromFrame(content);
        },
      "TOLY" => () {
          final content = cursor.read(size);
          metadata.originalTextWriter = getTextFromFrame(content);
        },
      "TOPE" || "TOR" => () {
          final content = cursor.read(size);
          metadata.originalArtist = getTextFromFrame(content);
        },
      "TORY" || "TYE" => () {
          final content = cursor.read(size);
          metadata.originalReleaseYear = _parseYear(getTextFromFrame(content));
        },
      "TOWN" || "TWP" => () {
          final content = cursor.read(size);
          metadata.fileOwner = getTextFromFrame(content);
        },
      "TDRC" || "TYR" => () {
          final content = cursor.read(size);
          metadata.year = _parseYear(getTextFromFrame(content));
        },
      "TYER" => () {
          final content = cursor.read(size);
          metadata.year = _parseYear(getTextFromFrame(content));
        },
      "TRDA" => () {
          final content = cursor.read(size);
          metadata.year = _parseYear(getTextFromFrame(content));
        },
      "TPE1" || "TP1" => () {
          final content = cursor.read(size);
          metadata.leadPerformer = getTextFromFrame(content);
        },
      "TPE2" || "TP2" => () {
          final content = cursor.read(size);
          metadata.bandOrOrchestra = getTextFromFrame(content);
        },
      "TPE3" || "TP3" => () {
          final content = cursor.read(size);
          metadata.conductor = getTextFromFrame(content);
        },
      "TPE4" || "TP4" => () {
          final content = cursor.read(size);
          metadata.interpreted = getTextFromFrame(content);
        },
      "TEXT" || "TXT" => () {
          final content = cursor.read(size);
          metadata.textWriter = getTextFromFrame(content);
        },
      "TPOS" || "TPA" => () {
          final content = cursor.read(size);
          final value = getTextFromFrame(content);
          metadata.partOfSet = value;

          final match = _discRegex.firstMatch(value);

          if (match != null) {
            metadata.discNumber = int.parse(match.group(1)!);
            metadata.totalDics = int.parse(match.group(2)!);
          } else {
            metadata.discNumber = int.tryParse(value);
          }
        },
      "TPUB" || "TPB" => () {
          final content = cursor.read(size);
          metadata.publisher = getTextFromFrame(content);
        },
      "TRCK" || "TRK" => () {
          final content = cursor.read(size);
          final trackInfo = getTextFromFrame(content);

          if (trackInfo.isEmpty) {
            return;
          }

          final match = _trackRegex.firstMatch(trackInfo);

          if (match != null) {
            metadata.trackNumber = int.parse(match.group(1)!);
            metadata.trackTotal = int.parse(match.group(2)!);
          } else {
            metadata.trackNumber = int.parse(trackInfo);
          }
        },
      "TRSN" || "TRN" => () {
          final content = cursor.read(size);
          metadata.internetRadioStationName = getTextFromFrame(content);
        },
      "TRSO" || "TRO" => () {
          final content = cursor.read(size);
          metadata.internetRadioStationOwner = getTextFromFrame(content);
        },
      "TSIZ" => () {
          final content = cursor.read(size);
          metadata.size = getTextFromFrame(content);
        },
      "TSRC" || "TRC" => () {
          final content = cursor.read(size);
          metadata.isrc = getTextFromFrame(content);
        },
      "TXXX" || "TXX" => () {
          final content = cursor.read(size);
          final frame = TXXXFrame(content);
          metadata.customMetadata[frame.description] = frame.information;
        },
      "USLT" || "ULT" => () {
          final content = cursor.read(size);
          metadata.lyric = getUnsynchronisedLyric(content);
        },
      "TSSE" => () {
          final content = cursor.read(size);
          metadata.encoderSoftware = getTextFromFrame(content);
        },
      _ => () {
          cursor.skip(size);
        }
    };

    handlers.call();
  }

  ID3v3Frame? getFrame(_TagCursor cursor, int majorVersion) {
    final headerBytes = cursor.readAtMost(majorVersion == 2 ? 6 : 10);

    if (headerBytes.length < (majorVersion == 2 ? 6 : 10)) {
      return null;
    }

    if (headerBytes.every((element) => element == 0)) return null;

    int size;

    late final Uint8List flags;
    late final String id;
    late final int headerSize;

    if (majorVersion == 2) {
      size = (headerBytes[3] << 16) | (headerBytes[4] << 8) | headerBytes[5];
      flags = Uint8List(0);
      id = String.fromCharCodes(headerBytes.sublist(0, 3));
      headerSize = 6;
    } else {
      // the id3 v4 ignore the first bit of every byte from the size
      if (majorVersion == 4) {
        size = (headerBytes[7] & 0xFF) |
            ((headerBytes[6] & 0xFF) << 7) |
            ((headerBytes[5] & 0xFF) << 14) |
            ((headerBytes[4] & 0xFF) << 21);
      } else {
        size = headerBytes[7] +
            (headerBytes[6] << 8) +
            (headerBytes[5] << 16) +
            (headerBytes[4] << 24);
      }

      flags = headerBytes.sublist(8);
      id = String.fromCharCodes(headerBytes.sublist(0, 4));
      headerSize = 10;
    }

    return ID3v3Frame(
      id,
      size,
      flags,
      headerSize,
    );
  }

  Picture getPicture(Uint8List content, {bool isV22 = false}) {
    int offset = 0;

    final reader = ByteData.sublistView(content);
    final encoding = reader.getUint8(offset++);
    late final String mimetype;

    if (isV22) {
      final format = String.fromCharCodes(content.sublist(offset, offset + 3))
          .toLowerCase();
      offset += 3;
      mimetype = switch (format) {
        "jpg" || "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        _ => "image/$format",
      };
    } else {
      final mimetypeBytes = <int>[reader.getUint8(offset++)];

      while (mimetypeBytes.last != 0) {
        mimetypeBytes.add(reader.getUint8(offset));
        offset++;
      }
      mimetypeBytes.removeLast();
      mimetype = String.fromCharCodes(mimetypeBytes);
    }

    final pictureType = reader.getUint8(offset);

    offset++;

    final descriptionEnd = _findDelimiter(content, offset, encoding);
    if (descriptionEnd >= 0) {
      offset = descriptionEnd + _delimiterLength(encoding);
    } else {
      offset = content.length;
    }

    return Picture(
      reader.buffer.asUint8List(offset),
      mimetype,
      getPictureTypeEnum(pictureType),
    );
  }

  String getUnsynchronisedLyric(Uint8List content) {
    int offset = 1;

    final reader = ByteData.sublistView(content);
    final encoding = reader.getInt8(0);

    // skip language
    offset += 3;

    final descriptionEnd = _findDelimiter(content, offset, encoding);
    if (descriptionEnd >= 0) {
      offset = descriptionEnd + _delimiterLength(encoding);
    } else {
      offset = content.length;
    }

    final rest = reader.buffer.asUint8List(offset);
    final textEnd = _findDelimiter(rest, 0, encoding);
    final textBytes = rest.sublist(0, textEnd >= 0 ? textEnd : rest.length);

    switch (encoding) {
      case 0:
        return latin1Decoder.convert(textBytes);
      case 1:
        return _decodeUtf16Bytes(textBytes, bigEndianDefault: false);
      case 2:
        return _decodeUtf16Bytes(textBytes, bigEndianDefault: true);
      case 3:
        return utf8Decoder.convert(textBytes);
    }

    return "";
  }

  ///
  /// To detect if this file can be parsed with this parser, the first 3 bytes
  /// must be equal to `ID3`
  ///
  static bool canUserParser(RandomAccessFile reader) {
    reader.setPositionSync(0);
    final headerBytes = reader.readSync(3);
    final tagIdentity = String.fromCharCodes(headerBytes);

    return tagIdentity == "ID3";
  }

  static bool isID3v1(RandomAccessFile reader) {
    reader.setPositionSync(reader.lengthSync() - 128);

    final headerBytes = reader.readSync(3);
    final tagIdentity = String.fromCharCodes(headerBytes);

    return tagIdentity == "TAG";
  }

  int? _parseYear(String year) {
    if (year.contains("-")) {
      return int.tryParse(year.split("-").first);
    } else if (year.contains("/")) {
      return int.tryParse(year.split("/").first);
    } else {
      return int.tryParse(year);
    }
  }

  int? _getSampleRate(int mpegVersion, int sampleRateIndex) {
    if (mpegVersion == 1) {
      return switch (sampleRateIndex) {
        0 => 44100,
        1 => 48000,
        2 => 32000,
        _ => null,
      };
    }

    if (mpegVersion == 2) {
      return switch (sampleRateIndex) {
        0 => 22050,
        1 => 24000,
        2 => 16000,
        _ => null,
      };
    }

    if (mpegVersion == 3) {
      return switch (sampleRateIndex) {
        0 => 11025,
        1 => 12000,
        2 => 8000,
        _ => null,
      };
    }

    return null;
  }

  int? _getBitrate(int mpegVersion, int mpegLayer, int bitrateIndex) {
    if (mpegVersion == 1 && mpegLayer == 1) {
      return switch (bitrateIndex) {
        0 => null,
        1 => 32000,
        2 => 64000,
        3 => 96000,
        4 => 128000,
        5 => 160000,
        6 => 192000,
        7 => 224000,
        8 => 256000,
        9 => 288000,
        10 => 320000,
        11 => 352000,
        12 => 384000,
        13 => 416000,
        14 => 448000,
        _ => null,
      };
    }

    if (mpegVersion == 1 && mpegLayer == 2) {
      return switch (bitrateIndex) {
        0 => null,
        1 => 32000,
        2 => 48000,
        3 => 56000,
        4 => 64000,
        5 => 80000,
        6 => 96000,
        7 => 112000,
        8 => 128000,
        9 => 160000,
        10 => 192000,
        11 => 224000,
        12 => 256000,
        13 => 320000,
        14 => 384000,
        _ => null,
      };
    }

    if (mpegVersion == 1 && mpegLayer == 3) {
      return switch (bitrateIndex) {
        0 => null,
        1 => 32000,
        2 => 40000,
        3 => 48000,
        4 => 56000,
        5 => 64000,
        6 => 80000,
        7 => 96000,
        8 => 112000,
        9 => 128000,
        10 => 160000,
        11 => 192000,
        12 => 224000,
        13 => 256000,
        14 => 320000,
        _ => null,
      };
    }
    if (mpegVersion == 2 && mpegLayer == 1) {
      return switch (bitrateIndex) {
        0 => null,
        1 => 32000,
        2 => 48000,
        3 => 56000,
        4 => 64000,
        5 => 80000,
        6 => 96000,
        7 => 112000,
        8 => 128000,
        9 => 144000,
        10 => 160000,
        11 => 176000,
        12 => 192000,
        13 => 224000,
        14 => 256000,
        _ => null,
      };
    }

    if (mpegVersion == 2 && (mpegLayer == 2 || mpegLayer == 3)) {
      return switch (bitrateIndex) {
        0 => null,
        1 => 8000,
        2 => 16000,
        3 => 24000,
        4 => 32000,
        5 => 40000,
        6 => 48000,
        7 => 56000,
        8 => 64000,
        9 => 80000,
        10 => 96000,
        11 => 112000,
        12 => 128000,
        13 => 144000,
        14 => 160000,
        _ => null,
      };
    }

    return null;
  }

  int? _getSamplePerFrame(int mpegAudioVersion, int mpegLayer) {
    if (mpegAudioVersion == 1) {
      return switch (mpegLayer) {
        1 => 384,
        2 => 1152,
        3 => 1152,
        _ => null,
      };
    } else if (mpegAudioVersion == 2) {
      return switch (mpegLayer) {
        1 => 192,
        2 => 1152,
        3 => 576,
        _ => null,
      };
    }

    return null;
  }
}
