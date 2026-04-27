import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_metadata_reader/src/metadata/base.dart';
import 'package:audio_metadata_reader/src/writers/base_writer.dart';

enum _OggFlavor {
  vorbis,
  opus,
}

class _OggPage {
  final Uint8List rawBytes;
  final int headerType;
  final int granulePosition;
  final int streamSerial;
  final int sequenceNumber;
  final List<int> segments;
  final Uint8List content;

  _OggPage({
    required this.rawBytes,
    required this.headerType,
    required this.granulePosition,
    required this.streamSerial,
    required this.sequenceNumber,
    required this.segments,
    required this.content,
  });

  bool get isContinuation => headerType & 0x01 == 0x01;

  Uint8List rebuild({
    required int sequenceNumber,
    required int? headerTypeOverride,
    required int? granulePositionOverride,
  }) {
    final builder = BytesBuilder();
    final headerTypeValue = headerTypeOverride ?? headerType;
    final granuleValue = granulePositionOverride ?? granulePosition;

    builder.add('OggS'.codeUnits);
    builder.addByte(0); // version
    builder.addByte(headerTypeValue);
    builder.add(_uint64LE(granuleValue));
    builder.add(_uint32LE(streamSerial));
    builder.add(_uint32LE(sequenceNumber));
    builder.add(_uint32LE(0)); // checksum placeholder
    builder.addByte(segments.length);
    builder.add(segments);
    builder.add(content);

    final bytes = builder.toBytes();
    final checksum = _oggCrc32(bytes);
    final byteData = ByteData.sublistView(bytes);
    byteData.setUint32(22, checksum, Endian.little);
    return bytes;
  }
}

class _ParsedStream {
  final List<Uint8List> packets;
  final Map<int, int> packetGranules;
  final int streamSerial;
  final _OggFlavor flavor;

  _ParsedStream({
    required this.packets,
    required this.packetGranules,
    required this.streamSerial,
    required this.flavor,
  });
}

class OggWriter extends BaseMetadataWriter<VorbisMetadata> {
  @override
  void write(File file, VorbisMetadata metadata) {
    final reader = file.openSync();
    try {
      reader.setPositionSync(0);
      final bytes = reader.readSync(reader.lengthSync());
      final parsed = _parseStream(bytes);
      final packets = List<Uint8List>.from(parsed.packets);

      if (packets.length < 2) {
        throw StateError('Unable to locate OGG comment packet');
      }

      packets[1] = _buildCommentPacket(metadata, parsed.flavor);

      final rebuilt = _buildPagesFromPackets(
        packets,
        parsed.packetGranules,
        parsed.streamSerial,
      );

      file.writeAsBytesSync(rebuilt, flush: true);
    } finally {
      reader.closeSync();
    }
  }

  _OggFlavor _detectFlavor(List<Uint8List> packets) {
    final firstPacket = packets.first;
    if (firstPacket.length >= 8 &&
        String.fromCharCodes(firstPacket.sublist(0, 8)) == 'OpusHead') {
      return _OggFlavor.opus;
    }
    return _OggFlavor.vorbis;
  }

  _ParsedStream _parseStream(Uint8List bytes) {
    final pages = _parsePages(bytes);
    if (pages.isEmpty) {
      throw StateError('Not a valid OGG file');
    }

    final packets = <Uint8List>[];
    final packetGranules = <int, int>{};
    final currentPacket = <int>[];
    var packetIndex = 0;

    for (final page in pages) {
      var contentOffset = 0;

      for (final segmentLength in page.segments) {
        currentPacket.addAll(
          page.content.sublist(contentOffset, contentOffset + segmentLength),
        );
        contentOffset += segmentLength;

        if (segmentLength < 255) {
          packets.add(Uint8List.fromList(currentPacket));
          packetGranules[packetIndex] = page.granulePosition;
          packetIndex += 1;
          currentPacket.clear();
        }
      }
    }

    if (packets.isEmpty) {
      throw StateError('Unable to parse OGG packets');
    }

    return _ParsedStream(
      packets: packets,
      packetGranules: packetGranules,
      streamSerial: pages.first.streamSerial,
      flavor: _detectFlavor(packets),
    );
  }

  Uint8List _buildCommentPacket(VorbisMetadata metadata, _OggFlavor flavor) {
    final builder = BytesBuilder();
    final commentSignature = switch (flavor) {
      _OggFlavor.opus => 'OpusTags'.codeUnits,
      _OggFlavor.vorbis => [0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73],
    };

    builder.add(commentSignature);

    final vendor = metadata.vendor.isNotEmpty ? metadata.vendor.first : '';
    final vendorBytes = utf8.encode(vendor);
    builder.add(_uint32LE(vendorBytes.length));
    builder.add(vendorBytes);

    final comments = <List<int>>[];
    void addComment(String key, String value) {
      if (value.isNotEmpty) {
        comments.add(utf8.encode('$key=$value'));
      }
    }

    void addRepeated(String key, Iterable<String> values) {
      for (final value in values) {
        addComment(key, value);
      }
    }

    void addRepeatedInts(String key, Iterable<int> values) {
      for (final value in values) {
        addComment(key, value.toString());
      }
    }

    addRepeated('TITLE', metadata.title);
    addRepeated('VERSION', metadata.version);
    addRepeated('ALBUM', metadata.album);
    addRepeatedInts('TRACKNUMBER', metadata.trackNumber);
    if (metadata.trackTotal != null) {
      addComment('TRACKTOTAL', metadata.trackTotal.toString());
    }
    addRepeated('ARTIST', metadata.artist);
    addRepeated('PERFORMER', metadata.performer);
    addRepeated('COPYRIGHT', metadata.copyright);
    addRepeated('LICENSE', metadata.license);
    addRepeated('ORGANIZATION', metadata.organization);
    addRepeated('DESCRIPTION', metadata.description);
    addRepeated('GENRE', metadata.genres);
    addRepeated(
      'DATE',
      metadata.date.map(
        (d) =>
            '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}',
      ),
    );
    addRepeated('LOCATION', metadata.location);
    addRepeated('CONTACT', metadata.contact);
    addRepeated('ISRC', metadata.isrc);
    addRepeated('ACTOR', metadata.actor);
    addRepeated('COMPOSER', metadata.composer);
    addRepeated('COMMENT', metadata.comment);
    addRepeated('LANGUAGE', metadata.language);
    addRepeated('DIRECTOR', metadata.director);
    addRepeated('ENCODED_BY', metadata.encodedBy);
    addRepeated('ENCODED_USING', metadata.encodedUsing);
    addRepeated('ENCODER', metadata.encoder);
    addRepeated('ENCODER_OPTIONS', metadata.encoderOptions);
    addRepeated('PRODUCER', metadata.producer);
    addRepeated('REPLAYGAIN_ALBUM_GAIN', metadata.replayGainAlbumGain);
    addRepeated('REPLAYGAIN_ALBUM_PEAK', metadata.replayGainAlbumPeak);
    addRepeated('REPLAYGAIN_TRACK_GAIN', metadata.replayGainTrackGain);
    addRepeated('REPLAYGAIN_TRACK_PEAK', metadata.replayGainTrackPeak);
    if (metadata.discNumber != null) {
      addComment('DISCNUMBER', metadata.discNumber.toString());
    }
    if (metadata.discTotal != null) {
      addComment('DISCTOTAL', metadata.discTotal.toString());
    }
    if (metadata.lyric != null && metadata.lyric!.isNotEmpty) {
      addComment('LYRICS', metadata.lyric!);
    }
    if (metadata.duration != null) {
      addComment('LENGTH', metadata.duration!.inMilliseconds.toString());
    }
    metadata.unknowns.forEach(addComment);

    for (final picture in metadata.pictures) {
      final pictureBytes = base64Encode(
        _buildPictureBlock(picture),
      );
      comments.add(utf8.encode('METADATA_BLOCK_PICTURE=$pictureBytes'));
    }

    builder.add(_uint32LE(comments.length));
    for (final comment in comments) {
      builder.add(_uint32LE(comment.length));
      builder.add(comment);
    }

    if (flavor == _OggFlavor.vorbis) {
      builder.addByte(1);
    }

    return builder.toBytes();
  }

  Uint8List _buildPagesFromPackets(
    List<Uint8List> packets,
    Map<int, int> packetGranules,
    int streamSerial,
  ) {
    final pages = <Uint8List>[];
    final segments = <int>[];
    final content = <int>[];
    var sequenceNumber = 0;
    var pageStartsWithContinuation = false;
    var lastGranulePosition = 0;
    var packetIndex = 0;

    void flushPage({required bool isLastPage}) {
      if (segments.isEmpty) {
        if (isLastPage && pages.isNotEmpty) {
          pages[pages.length - 1] = _markPageAsEos(pages.last);
        }
        return;
      }

      final builder = BytesBuilder();
      var headerType = 0;
      if (sequenceNumber == 0) {
        headerType |= 0x02;
      }
      if (pageStartsWithContinuation) {
        headerType |= 0x01;
      }
      if (isLastPage) {
        headerType |= 0x04;
      }

      builder.add('OggS'.codeUnits);
      builder.addByte(0);
      builder.addByte(headerType);
      builder.add(_uint64LE(lastGranulePosition));
      builder.add(_uint32LE(streamSerial));
      builder.add(_uint32LE(sequenceNumber));
      builder.add(_uint32LE(0));
      builder.addByte(segments.length);
      builder.add(segments);
      builder.add(content);

      final bytes = builder.toBytes();
      final crc = _oggCrc32(bytes);
      ByteData.sublistView(bytes).setUint32(22, crc, Endian.little);
      pages.add(bytes);
      sequenceNumber += 1;
      segments.clear();
      content.clear();
    }

    for (final packet in packets) {
      var offset = 0;

      while (offset < packet.length) {
        if (segments.length == 255) {
          flushPage(isLastPage: false);
          pageStartsWithContinuation = offset < packet.length;
        }

        final remaining = packet.length - offset;
        final segmentLength = remaining >= 255 ? 255 : remaining;
        segments.add(segmentLength);
        content.addAll(packet.sublist(offset, offset + segmentLength));
        offset += segmentLength;

        if (segmentLength < 255) {
          lastGranulePosition =
              packetGranules[packetIndex] ?? lastGranulePosition;
          packetIndex += 1;

          if (packetIndex <= 2) {
            flushPage(isLastPage: false);
            pageStartsWithContinuation = false;
          }
        }

        if (segments.length == 255) {
          final packetStillContinues = offset < packet.length;
          flushPage(isLastPage: false);
          pageStartsWithContinuation = packetStillContinues;
        }
      }
    }

    flushPage(isLastPage: true);
    return Uint8List.fromList(
      pages.expand((page) => page).toList(growable: false),
    );
  }

  Uint8List _markPageAsEos(Uint8List page) {
    final bytes = Uint8List.fromList(page);
    final header = ByteData.sublistView(bytes);
    header.setUint32(22, 0, Endian.little);
    bytes[5] |= 0x04;
    final crc = _oggCrc32(bytes);
    header.setUint32(22, crc, Endian.little);
    return bytes;
  }

  Uint8List _buildPictureBlock(Picture picture) {
    final builder = BytesBuilder();
    builder.add(_uint32BE(picture.pictureType.index));
    builder.add(_uint32BE(picture.mimetype.length));
    builder.add(ascii.encode(picture.mimetype));
    builder.add(_uint32BE(0)); // description length
    builder.add(_uint32BE(0)); // width
    builder.add(_uint32BE(0)); // height
    builder.add(_uint32BE(0)); // color depth
    builder.add(_uint32BE(0)); // indexed colors
    builder.add(_uint32BE(picture.bytes.length));
    builder.add(picture.bytes);
    return builder.toBytes();
  }

  List<_OggPage> _parsePages(Uint8List bytes) {
    final pages = <_OggPage>[];
    var offset = 0;

    while (offset + 27 <= bytes.length) {
      final magic = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      if (magic != 'OggS') {
        throw StateError('Not a valid OGG file');
      }

      final version = bytes[offset + 4];
      if (version != 0) {
        throw StateError('Unsupported OGG version: $version');
      }

      final headerType = bytes[offset + 5];
      final granulePosition = _readUint64LE(bytes, offset + 6);
      final streamSerial = _readUint32LE(bytes, offset + 14);
      final sequenceNumber = _readUint32LE(bytes, offset + 18);
      final segmentCount = bytes[offset + 26];
      final headerSize = 27 + segmentCount;

      if (offset + headerSize > bytes.length) {
        throw StateError('Truncated OGG page header');
      }

      final segments = bytes.sublist(offset + 27, offset + 27 + segmentCount);
      var contentLength = 0;
      for (final segment in segments) {
        contentLength += segment;
      }

      final rawEnd = offset + headerSize + contentLength;
      if (rawEnd > bytes.length) {
        throw StateError('Truncated OGG page content');
      }

      final content = Uint8List.fromList(
        bytes.sublist(offset + headerSize, rawEnd),
      );
      final rawBytes = Uint8List.fromList(bytes.sublist(offset, rawEnd));

      pages.add(
        _OggPage(
          rawBytes: rawBytes,
          headerType: headerType,
          granulePosition: granulePosition,
          streamSerial: streamSerial,
          sequenceNumber: sequenceNumber,
          segments: List<int>.from(segments),
          content: content,
        ),
      );

      offset = rawEnd;
    }

    return pages;
  }
}

Uint8List _uint32LE(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.little);
  return bytes.buffer.asUint8List();
}

Uint8List _uint32BE(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  return bytes.buffer.asUint8List();
}

Uint8List _uint64LE(int value) {
  final bytes = ByteData(8)..setUint64(0, value, Endian.little);
  return bytes.buffer.asUint8List();
}

int _readUint32LE(Uint8List bytes, int offset) {
  final byteData = ByteData.sublistView(bytes, offset, offset + 4);
  return byteData.getUint32(0, Endian.little);
}

int _readUint64LE(Uint8List bytes, int offset) {
  final byteData = ByteData.sublistView(bytes, offset, offset + 8);
  final value = byteData.getUint64(0, Endian.little);
  if (value > 0x7FFFFFFF) {
    return value;
  }
  return value;
}

int _oggCrc32(Uint8List bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc = _oggCrcTable[((crc >> 24) ^ byte) & 0xFF] ^ ((crc << 8) & 0xFFFFFFFF);
    crc &= 0xFFFFFFFF;
  }
  return crc;
}

const List<int> _oggCrcTable = [
  0x00000000,
  0x04c11db7,
  0x09823b6e,
  0x0d4326d9,
  0x130476dc,
  0x17c56b6b,
  0x1a864db2,
  0x1e475005,
  0x2608edb8,
  0x22c9f00f,
  0x2f8ad6d6,
  0x2b4bcb61,
  0x350c9b64,
  0x31cd86d3,
  0x3c8ea00a,
  0x384fbdbd,
  0x4c11db70,
  0x48d0c6c7,
  0x4593e01e,
  0x4152fda9,
  0x5f15adac,
  0x5bd4b01b,
  0x569796c2,
  0x52568b75,
  0x6a1936c8,
  0x6ed82b7f,
  0x639b0da6,
  0x675a1011,
  0x791d4014,
  0x7ddc5da3,
  0x709f7b7a,
  0x745e66cd,
  0x9823b6e0,
  0x9ce2ab57,
  0x91a18d8e,
  0x95609039,
  0x8b27c03c,
  0x8fe6dd8b,
  0x82a5fb52,
  0x8664e6e5,
  0xbe2b5b58,
  0xbaea46ef,
  0xb7a96036,
  0xb3687d81,
  0xad2f2d84,
  0xa9ee3033,
  0xa4ad16ea,
  0xa06c0b5d,
  0xd4326d90,
  0xd0f37027,
  0xddb056fe,
  0xd9714b49,
  0xc7361b4c,
  0xc3f706fb,
  0xceb42022,
  0xca753d95,
  0xf23a8028,
  0xf6fb9d9f,
  0xfbb8bb46,
  0xff79a6f1,
  0xe13ef6f4,
  0xe5ffeb43,
  0xe8bccd9a,
  0xec7dd02d,
  0x34867077,
  0x30476dc0,
  0x3d044b19,
  0x39c556ae,
  0x278206ab,
  0x23431b1c,
  0x2e003dc5,
  0x2ac12072,
  0x128e9dcf,
  0x164f8078,
  0x1b0ca6a1,
  0x1fcdbb16,
  0x018aeb13,
  0x054bf6a4,
  0x0808d07d,
  0x0cc9cdca,
  0x7897ab07,
  0x7c56b6b0,
  0x71159069,
  0x75d48dde,
  0x6b93dddb,
  0x6f52c06c,
  0x6211e6b5,
  0x66d0fb02,
  0x5e9f46bf,
  0x5a5e5b08,
  0x571d7dd1,
  0x53dc6066,
  0x4d9b3063,
  0x495a2dd4,
  0x44190b0d,
  0x40d816ba,
  0xaca5c697,
  0xa864db20,
  0xa527fdf9,
  0xa1e6e04e,
  0xbfa1b04b,
  0xbb60adfc,
  0xb6238b25,
  0xb2e29692,
  0x8aad2b2f,
  0x8e6c3698,
  0x832f1041,
  0x87ee0df6,
  0x99a95df3,
  0x9d684044,
  0x902b669d,
  0x94ea7b2a,
  0xe0b41de7,
  0xe4750050,
  0xe9362689,
  0xedf73b3e,
  0xf3b06b3b,
  0xf771768c,
  0xfa325055,
  0xfef34de2,
  0xc6bcf05f,
  0xc27dede8,
  0xcf3ecb31,
  0xcbffd686,
  0xd5b88683,
  0xd1799b34,
  0xdc3abded,
  0xd8fba05a,
  0x690ce0ee,
  0x6dcdfd59,
  0x608edb80,
  0x644fc637,
  0x7a089632,
  0x7ec98b85,
  0x738aad5c,
  0x774bb0eb,
  0x4f040d56,
  0x4bc510e1,
  0x46863638,
  0x42472b8f,
  0x5c007b8a,
  0x58c1663d,
  0x558240e4,
  0x51435d53,
  0x251d3b9e,
  0x21dc2629,
  0x2c9f00f0,
  0x285e1d47,
  0x36194d42,
  0x32d850f5,
  0x3f9b762c,
  0x3b5a6b9b,
  0x0315d626,
  0x07d4cb91,
  0x0a97ed48,
  0x0e56f0ff,
  0x1011a0fa,
  0x14d0bd4d,
  0x19939b94,
  0x1d528623,
  0xf12f560e,
  0xf5ee4bb9,
  0xf8ad6d60,
  0xfc6c70d7,
  0xe22b20d2,
  0xe6ea3d65,
  0xeba91bbc,
  0xef68060b,
  0xd727bbb6,
  0xd3e6a601,
  0xdea580d8,
  0xda649d6f,
  0xc423cd6a,
  0xc0e2d0dd,
  0xcda1f604,
  0xc960ebb3,
  0xbd3e8d7e,
  0xb9ff90c9,
  0xb4bcb610,
  0xb07daba7,
  0xae3afba2,
  0xaafbe615,
  0xa7b8c0cc,
  0xa379dd7b,
  0x9b3660c6,
  0x9ff77d71,
  0x92b45ba8,
  0x9675461f,
  0x8832161a,
  0x8cf30bad,
  0x81b02d74,
  0x857130c3,
  0x5d8a9099,
  0x594b8d2e,
  0x5408abf7,
  0x50c9b640,
  0x4e8ee645,
  0x4a4ffbf2,
  0x470cdd2b,
  0x43cdc09c,
  0x7b827d21,
  0x7f436096,
  0x7200464f,
  0x76c15bf8,
  0x68860bfd,
  0x6c47164a,
  0x61043093,
  0x65c52d24,
  0x119b4be9,
  0x155a565e,
  0x18197087,
  0x1cd86d30,
  0x029f3d35,
  0x065e2082,
  0x0b1d065b,
  0x0fdc1bec,
  0x3793a651,
  0x3352bbe6,
  0x3e119d3f,
  0x3ad08088,
  0x2497d08d,
  0x2056cd3a,
  0x2d15ebe3,
  0x29d4f654,
  0xc5a92679,
  0xc1683bce,
  0xcc2b1d17,
  0xc8ea00a0,
  0xd6ad50a5,
  0xd26c4d12,
  0xdf2f6bcb,
  0xdbee767c,
  0xe3a1cbc1,
  0xe760d676,
  0xea23f0af,
  0xeee2ed18,
  0xf0a5bd1d,
  0xf464a0aa,
  0xf9278673,
  0xfde69bc4,
  0x89b8fd09,
  0x8d79e0be,
  0x803ac667,
  0x84fbdbd0,
  0x9abc8bd5,
  0x9e7d9662,
  0x933eb0bb,
  0x97ffad0c,
  0xafb010b1,
  0xab710d06,
  0xa6322bdf,
  0xa2f33668,
  0xbcb4666d,
  0xb8757bda,
  0xb5365d03,
  0xb1f740b4,
];
