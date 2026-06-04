import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';

void main() {
  // Set up logging to display details in console/IDE debug window
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint(
      '[${record.level.name}] ${record.loggerName}: ${record.message}',
    );
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Metadata Reader Demo',
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF6366F1), // Modern Indigo 500
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        cardColor: const Color(0xFF1E293B), // Slate 800
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981), // Emerald 500
          surface: Color(0xFF1E293B),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF334155), // Slate 700
          labelStyle: TextStyle(color: Colors.grey.shade300),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
          ),
        ),
      ),
      home: const MetadataEditorScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MetadataEditorScreen extends StatefulWidget {
  const MetadataEditorScreen({super.key});

  @override
  State<MetadataEditorScreen> createState() => _MetadataEditorScreenState();
}

class _MetadataEditorScreenState extends State<MetadataEditorScreen> {
  // File details
  String? _filePath;
  String? _fileName;
  String? _fileDirectoryPath;
  
  // iOS Security-scoped bookmarks variables
  PickedAudioFile? _pickedAudioFile;
  AuthorizedDirectory? _authorizedDirectory;
  bool _hasDirectoryWriteAccess = true;
  bool _isCheckingDirectoryAccess = false;
  bool _isAuthorizingDirectory = false;

  // Metadata information
  AudioMetadata? _audioMetadata;
  String? _errorMessage;
  bool _isSaving = false;

  // Form field controllers
  final titleController = TextEditingController();
  final artistController = TextEditingController();
  final albumController = TextEditingController();
  final genreController = TextEditingController();
  final yearController = TextEditingController();
  final trackController = TextEditingController();

  // Cover image art state
  Uint8List? _coverBytes;
  String? _coverMimeType;
  bool _coverChanged = false;

  @override
  void initState() {
    super.initState();
    _loadDemoAsset();
  }

  /// Attempts to find and copy the project's test MP3 file as a default demo
  void _loadDemoAsset() {
    final paths = [
      '../test/mp3/caress-your-soul-cleaned.mp3',
      'test/mp3/caress-your-soul-cleaned.mp3',
      '../test/mp3/track.mp3',
      'test/mp3/track.mp3',
    ];
    for (final localPath in paths) {
      final localFile = File(localPath);
      if (localFile.existsSync()) {
        try {
          final tempDir = Directory.systemTemp.createTempSync('audio_metadata_demo');
          final tempMp3File = File('${tempDir.path}/demo_song.mp3');
          localFile.copySync(tempMp3File.path);
          _loadFile(tempMp3File.path);
          break;
        } catch (e) {
          debugPrint('Failed to copy default demo asset: $e');
        }
      }
    }
  }

  @override
  void dispose() {
    unawaited(_releaseDirectoryAccess());
    titleController.dispose();
    artistController.dispose();
    albumController.dispose();
    genreController.dispose();
    yearController.dispose();
    trackController.dispose();
    super.dispose();
  }

  /// Opens the picked audio file and loads its metadata.
  /// Also handles iOS-specific Security-Scoped bookmark restoration checks.
  Future<void> _loadFile(
    String path, {
    String? name,
    PickedAudioFile? pickedAudioFile,
  }) async {
    debugPrint('Loading file path=$path, name=$name');
    
    AudioMetadata? metadata;
    try {
      // Use audio_metadata_reader's high-level helper to read metadata with cover art
      metadata = readMetadata(File(path), getImage: true);
    } catch (e) {
      debugPrint('Failed to parse metadata: $e');
      setState(() {
        _filePath = null;
        _fileName = null;
        _fileDirectoryPath = null;
        _pickedAudioFile = null;
        _audioMetadata = null;
        _errorMessage = 'Failed to parse file: $e';
        _hasDirectoryWriteAccess = true;
        _authorizedDirectory = null;
      });
      return;
    }

    final sourcePath = pickedAudioFile?.originalPath ?? path;
    final directoryPath = Platform.isIOS && !sourcePath.startsWith('content://')
        ? File(sourcePath).parent.path
        : null;
    AuthorizedDirectory? restoredDirectoryAccess;

    // iOS check: Restore security-scoped folder access if previously bookmarked
    if (Platform.isIOS && directoryPath != null) {
      try {
        restoredDirectoryAccess = await AudioMetadataReaderPermissions.restoreAuthorizedDirectory(
          directoryPath,
        );
      } catch (e) {
        debugPrint('Failed to restore directory access for $directoryPath: $e');
      }
    }

    // Release old directory handle if the folder has changed
    if (_authorizedDirectory != null &&
        directoryPath != null &&
        !_isSameDirectoryOrAncestor(_authorizedDirectory!.path, directoryPath)) {
      await _releaseDirectoryAccess();
    }

    setState(() {
      _filePath = path;
      _pickedAudioFile = pickedAudioFile;
      _fileName = name ?? File(path).path.split(Platform.pathSeparator).last;
      _fileDirectoryPath = directoryPath;
      _audioMetadata = metadata;
      _errorMessage = null;
      _coverChanged = false;
      _coverBytes = metadata!.pictures.isNotEmpty ? metadata.pictures.first.bytes : null;
      _coverMimeType = metadata.pictures.isNotEmpty ? metadata.pictures.first.mimetype : 'image/jpeg';
      _hasDirectoryWriteAccess = restoredDirectoryAccess != null || !Platform.isIOS || directoryPath == null;
      _authorizedDirectory = restoredDirectoryAccess;
      _isCheckingDirectoryAccess = Platform.isIOS && directoryPath != null;

      // Populate text fields
      titleController.text = metadata.title ?? '';
      artistController.text = metadata.artist ?? '';
      albumController.text = metadata.album ?? '';
      genreController.text = metadata.genres.isNotEmpty ? metadata.genres.first : '';
      yearController.text = metadata.year != null ? metadata.year!.year.toString() : '';
      trackController.text = metadata.trackNumber != null ? metadata.trackNumber.toString() : '';
    });

    // Check directory write capability on iOS
    if (directoryPath != null) {
      final hasAccess = await _checkDirectoryWriteAccess(directoryPath);
      if (!mounted || _filePath != path) return;
      setState(() {
        _hasDirectoryWriteAccess = hasAccess;
        _isCheckingDirectoryAccess = false;
        if (!hasAccess) {
          _errorMessage = 'iOS original directory has no write permission. Please authorize directory first.';
        }
      });
    }
  }

  /// Lets the user select an audio file.
  /// On iOS: Uses `pickAudioFileForEditing` to safely open from security-scoped document pickers.
  /// On other platforms: Uses standard FilePicker.
  Future<void> _pickAudioFile() async {
    try {
      if (Platform.isIOS) {
        final result = await AudioMetadataReaderPermissions.pickAudioFileForEditing();
        if (result != null) {
          await _loadFile(
            result.path,
            name: result.name,
            pickedAudioFile: result,
          );
        }
        return;
      }

      final result = await FilePicker.pickFiles(type: FileType.audio);
      if (result != null) {
        final file = result.files.single;
        final path = (Platform.isAndroid && file.identifier != null)
            ? file.identifier!
            : file.path;
        if (path != null) {
          if (Platform.isAndroid && path.startsWith('content://')) {
            final picked = await AudioMetadataReaderPermissions.copyContentUriToTemp(path, file.name);
            if (picked != null) {
              await _loadFile(
                picked.path,
                name: file.name,
                pickedAudioFile: picked,
              );
            }
          } else {
            await _loadFile(path, name: file.name);
          }
        }
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      setState(() {
        _errorMessage = 'Error picking file: $e';
      });
    }
  }

  /// Probes directory write access on iOS
  Future<bool> _checkDirectoryWriteAccess(String directoryPath) async {
    if (!Platform.isIOS) return true;
    try {
      final directory = Directory(directoryPath);
      if (!await directory.exists()) return false;

      final probeFile = File(
        '${directory.path}${Platform.pathSeparator}.write_probe_${DateTime.now().microsecondsSinceEpoch}',
      );
      await probeFile.writeAsBytes(const <int>[], flush: true);
      await probeFile.delete();
      return true;
    } catch (e) {
      debugPrint('Directory write check failed: $e');
      return false;
    }
  }

  /// Requests iOS directory permissions using UIDocumentPickerViewController
  Future<void> _authorizeOriginalDirectory() async {
    if (!Platform.isIOS || _fileDirectoryPath == null) return;

    setState(() {
      _isAuthorizingDirectory = true;
    });

    try {
      final directoryAccess = await AudioMetadataReaderPermissions.pickAuthorizedDirectory();
      if (directoryAccess == null) return;

      final authorizedPath = directoryAccess.path;
      if (authorizedPath.isEmpty) {
        throw StateError('Failed to parse authorized directory path.');
      }

      final matchesOriginal = _isSameDirectoryOrAncestor(authorizedPath, _fileDirectoryPath!);
      if (!mounted) return;

      if (!matchesOriginal) {
        final messenger = ScaffoldMessenger.of(context);
        await directoryAccess.dispose();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Please select the original directory containing the file or its ancestor.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      await _releaseDirectoryAccess();
      if (!mounted) return;
      setState(() {
        _authorizedDirectory = directoryAccess;
        _hasDirectoryWriteAccess = true;
        _isCheckingDirectoryAccess = false;
        _errorMessage = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Directory access authorized successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Directory authorization failed: $e'), backgroundColor: Colors.redAccent),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAuthorizingDirectory = false;
        });
      }
    }
  }

  bool _isSameDirectoryOrAncestor(String candidate, String target) {
    final normCandidate = _normalizePath(candidate);
    final normTarget = _normalizePath(target);
    if (normCandidate == normTarget) return true;
    return normTarget.startsWith('$normCandidate${Platform.pathSeparator}');
  }

  String _normalizePath(String path) {
    var normalized = path.replaceAll('\\', Platform.pathSeparator);
    while (normalized.length > 1 && normalized.endsWith(Platform.pathSeparator)) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  Future<void> _releaseDirectoryAccess() async {
    final directoryAccess = _authorizedDirectory;
    if (directoryAccess == null || !Platform.isIOS) return;

    _authorizedDirectory = null;
    try {
      await directoryAccess.dispose();
    } catch (e) {
      debugPrint('Failed to stop accessing directory: $e');
    }
  }

  /// Picks a new album cover art image
  Future<void> _pickCoverImage() async {
    if (_audioMetadata == null) return;
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final bytes = await File(path).readAsBytes();

        String mimeType = 'image/jpeg';
        if (path.toLowerCase().endsWith('.png')) {
          mimeType = 'image/png';
        } else if (path.toLowerCase().endsWith('.gif')) {
          mimeType = 'image/gif';
        }

        setState(() {
          _coverBytes = bytes;
          _coverMimeType = mimeType;
          _coverChanged = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error picking cover: $e')));
    }
  }

  /// Removes the current cover art
  void _removeCoverImage() {
    setState(() {
      _coverBytes = null;
      _coverMimeType = null;
      _coverChanged = true;
    });
  }

  /// Writes metadata updates back to the physical audio file
  Future<void> _saveChanges() async {
    if (_audioMetadata == null || _filePath == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // 1. Android Scoped Storage Permission check
      if (Platform.isAndroid) {
        final targetUri = _pickedAudioFile?.originalPath ?? _filePath!;
        final grantedUri = await AudioMetadataReaderPermissions.requestWritePermission(targetUri);
        if (grantedUri == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Save failed: Write permission denied on Android.'),
              backgroundColor: Colors.redAccent,
            ),
          );
          setState(() {
            _isSaving = false;
          });
          return;
        }
      }

      // 2. Perform write back to file using audio_metadata_reader API
      updateMetadata(
        File(_filePath!),
        (metadata) {
          metadata.setTitle(titleController.text);
          metadata.setArtist(artistController.text);
          metadata.setAlbum(albumController.text);
          if (genreController.text.isNotEmpty) {
            metadata.setGenres([genreController.text]);
          }
          final yearVal = int.tryParse(yearController.text);
          if (yearVal != null) {
            metadata.setYear(DateTime(yearVal));
          }
          final trackVal = int.tryParse(trackController.text);
          if (trackVal != null) {
            metadata.setTrackNumber(trackVal);
          }

          if (_coverChanged) {
            if (_coverBytes != null) {
              metadata.setPictures([
                Picture(_coverBytes!, _coverMimeType ?? 'image/jpeg', PictureType.coverFront)
              ]);
            } else {
              metadata.setPictures([]);
            }
          }
        },
      );

      // 3. Commit check: Write working copy back to the original picked URL/URI
      if (_pickedAudioFile != null && _pickedAudioFile!.needsCommit) {
        await _pickedAudioFile!.commit();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Metadata saved successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      // Reload metadata to update the UI with new written tags
      await _loadFile(
        _filePath!,
        name: _fileName,
        pickedAudioFile: _pickedAudioFile,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving changes: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Metadata Reader & Writer'),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open Audio File',
            onPressed: _pickAudioFile,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_errorMessage != null)
              Container(
                color: Colors.redAccent.withOpacity(0.2),
                padding: const EdgeInsets.all(16),
                width: double.infinity,
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _audioMetadata == null ? _buildEmptyState() : _buildEditorContent(),
            ),
          ],
        ),
      ),
      floatingActionButton: _audioMetadata != null
          ? FloatingActionButton.extended(
              onPressed: _isSaving ? null : _saveChanges,
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_isSaving ? 'Saving...' : 'Save Changes'),
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF334155), width: 2),
            ),
            child: Icon(Icons.music_note, size: 72, color: Colors.indigo.shade400),
          ),
          const SizedBox(height: 24),
          const Text(
            'No Audio File Loaded',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Text(
              'Select a music file (MP3, FLAC, M4A, WAV, OGG) to view and edit metadata.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _pickAudioFile,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.folder_open),
            label: const Text('Select Audio File', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFileInfoBanner(),
          const SizedBox(height: 16),
          _buildDirectoryAuthorizationBanner(),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > 700) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: _buildCoverArtSection()),
                    const SizedBox(width: 32),
                    Expanded(flex: 3, child: _buildFormSection()),
                  ],
                );
              } else {
                return Column(
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: _buildCoverArtSection(),
                      ),
                    ),
                    const SizedBox(height: 32),
                    _buildFormSection(),
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 24),
          _buildAudioPropertiesSection(),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildFileInfoBanner() {
    final fileName = _fileName ?? '';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 520;

          final fileDetails = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                _pickedAudioFile?.originalPath ?? _filePath ?? '',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                overflow: TextOverflow.fade,
              ),
            ],
          );

          final actionButton = TextButton.icon(
            onPressed: _pickAudioFile,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Change File'),
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.audio_file,
                      color: Colors.indigo.shade300,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: fileDetails),
                  ],
                ),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerLeft, child: actionButton),
              ],
            );
          }

          return Row(
            children: [
              Icon(Icons.audio_file, color: Colors.indigo.shade300, size: 28),
              const SizedBox(width: 16),
              Expanded(child: fileDetails),
              const SizedBox(width: 12),
              actionButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildDirectoryAuthorizationBanner() {
    if (!Platform.isIOS || _fileDirectoryPath == null) {
      return const SizedBox.shrink();
    }

    if (_isCheckingDirectoryAccess) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Verifying directory permissions...'),
          ],
        ),
      );
    }

    if (_hasDirectoryWriteAccess) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF3B1D1D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFB91C1C)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, color: Color(0xFFF87171)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Directory Permission Required',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFCA5A5),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'File directory: $_fileDirectoryPath\nPlease authorize this directory to save changes directly back to the original file.',
                  style: TextStyle(
                    color: Colors.red.shade100,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isAuthorizingDirectory
                      ? null
                      : _authorizeOriginalDirectory,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF97316),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: _isAuthorizingDirectory
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.folder_shared),
                  label: Text(_isAuthorizingDirectory ? 'Authorizing...' : 'Authorize Folder'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverArtSection() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 1.0,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: _coverBytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          _coverBytes!,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.album,
                            size: 80,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No Cover Art',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),
            if (_coverBytes != null) ...[
              Text(
                'Mime-Type: ${_coverMimeType ?? "Unknown"}',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
              Text(
                'Size: ${(_coverBytes!.length / 1024).toStringAsFixed(1)} KB',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _pickCoverImage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF334155),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.image, size: 18),
                  label: const Text('Change Art'),
                ),
                if (_coverBytes != null)
                  OutlinedButton.icon(
                    onPressed: _removeCoverImage,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormSection() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Metadata Info',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF818CF8),
              ),
            ),
            const Divider(color: Color(0xFF334155), height: 24),
            TextFormField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Song Title',
                prefixIcon: Icon(Icons.title),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: artistController,
              decoration: const InputDecoration(
                labelText: 'Artist',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: albumController,
              decoration: const InputDecoration(
                labelText: 'Album',
                prefixIcon: Icon(Icons.album),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: genreController,
              decoration: const InputDecoration(
                labelText: 'Genre',
                prefixIcon: Icon(Icons.category),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: yearController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Year',
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: trackController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Track #',
                      prefixIcon: Icon(Icons.music_note),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioPropertiesSection() {
    if (_audioMetadata == null) return const SizedBox.shrink();

    final props = [
      _AudioPropertyItem(
        label: 'Format',
        value: _filePath?.split('.').last.toUpperCase() ?? 'Unknown',
        icon: Icons.audio_file_outlined,
      ),
      if (_audioMetadata!.bitrate != null)
        _AudioPropertyItem(
          label: 'Bitrate',
          value: '${_audioMetadata!.bitrate} kbps',
          icon: Icons.speed_outlined,
        ),
      if (_audioMetadata!.sampleRate != null)
        _AudioPropertyItem(
          label: 'Sample Rate',
          value: '${(_audioMetadata!.sampleRate! / 1000).toStringAsFixed(1)} kHz',
          icon: Icons.graphic_eq_outlined,
        ),
      if (_audioMetadata!.duration != null)
        _AudioPropertyItem(
          label: 'Duration',
          value: _formatDuration(_audioMetadata!.duration!),
          icon: Icons.timer_outlined,
        ),
    ];

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Technical Properties',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF34D399),
              ),
            ),
            const Divider(color: Color(0xFF334155), height: 24),
            LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 360;

                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: isCompact ? constraints.maxWidth : 220,
                    mainAxisExtent: 80,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                  ),
                  itemCount: props.length,
                  itemBuilder: (context, index) {
                    final prop = props[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            prop.icon,
                            color: const Color(0xFF34D399),
                            size: 24,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  prop.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.grey.shade400,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  prop.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}

class _AudioPropertyItem {
  final String label;
  final String value;
  final IconData icon;

  _AudioPropertyItem({
    required this.label,
    required this.value,
    required this.icon,
  });
}
