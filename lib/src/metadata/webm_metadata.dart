part of 'base.dart';

/// Dedicated metadata model for WebM / Matroska containers.
///
/// This structure matches the standard Matroska tags specification.
/// We map standard tag keys (e.g. TITLE, ARTIST, ALBUM) to explicit typed fields
/// to help maintainers interact with metadata easily without knowledge of
/// EBML structure or raw Matroska tag mapping.
class WebmMetadata extends ParserTag {
  /// The song title (`TITLE` tag)
  String? title;

  /// The song artist (`ARTIST` or `LEAD_PERFORMER` tag)
  String? artist;

  /// The album title (`ALBUM` tag)
  String? album;

  /// The album artist (`ALBUM_ARTIST` or `ALBUMARTIST` tag)
  String? albumArtist;

  /// Embedded song lyrics (`LYRICS` tag)
  String? lyric;

  /// General description or comments (`COMMENT` or `DESCRIPTION` tag)
  String? comment;

  /// Song composer (`COMPOSER` tag)
  String? composer;

  /// Copyright text (`COPYRIGHT` tag)
  String? copyright;

  /// Software or tool used for encoding (`ENCODER` or `ENCODED_BY` tag)
  String? encoder;

  /// Release date (`DATE_RELEASE`, `YEAR` or `DATE` tag)
  DateTime? date;

  /// The track number (`TRACK_NUMBER`, `TRACKNUMBER` or `TRACK` tag)
  int? trackNumber;

  /// The total tracks count (`TOTAL_TRACKS`, `TRACKTOTAL` or `TRACK_TOTAL` tag)
  int? trackTotal;

  /// The disc/CD number (`DISC_NUMBER`, `DISCNUMBER` or `DISC` tag)
  int? discNumber;

  /// The total discs count (`TOTAL_DISCS`, `DISCTOTAL` or `DISC_TOTAL` tag)
  int? discTotal;

  /// Genres (`GENRE` tags)
  List<String> genres = [];

  /// Language code or name (`LANGUAGE` tags)
  List<String> language = [];

  /// Performers list (`PERFORMER` tags)
  List<String> performer = [];

  /// Embedded picture/artwork (parsed from Matroska Attachments)
  List<Picture> pictures = [];

  /// Playback duration parsed from Segment Info
  Duration? duration;

  /// Estimated/parsed bitrate in bits per second
  int? bitrate;

  /// Audio sample rate in Hz parsed from Track Info
  int? sampleRate;

  WebmMetadata();

  @override
  String toString() {
    return 'WebmMetadata(\n'
        '  title: $title,\n'
        '  artist: $artist,\n'
        '  album: $album,\n'
        '  albumArtist: $albumArtist,\n'
        '  lyric: $lyric,\n'
        '  comment: $comment,\n'
        '  composer: $composer,\n'
        '  copyright: $copyright,\n'
        '  encoder: $encoder,\n'
        '  date: $date,\n'
        '  trackNumber: $trackNumber,\n'
        '  trackTotal: $trackTotal,\n'
        '  discNumber: $discNumber,\n'
        '  discTotal: $discTotal,\n'
        '  genres: $genres,\n'
        '  language: $language,\n'
        '  performer: $performer,\n'
        '  pictures: $pictures,\n'
        '  duration: $duration,\n'
        '  bitrate: $bitrate,\n'
        '  sampleRate: $sampleRate\n'
        ')';
  }
}
