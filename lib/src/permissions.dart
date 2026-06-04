import 'dart:io';
import 'package:flutter/services.dart';

/// Represents a picked audio file on iOS.
///
/// On iOS, the plugin provides a writable temporary copy path as well as the
/// original file path. Call [commit] after saving metadata to copy the working
/// copy back to the original file.
class PickedAudioFile {
  /// The local file path of the temporary writable copy.
  final String path;

  /// The original picked file path or resource URI.
  final String originalPath;

  /// The original filename or display name, if available.
  final String? name;

  PickedAudioFile._({
    required this.path,
    required this.originalPath,
    required this.name,
  });

  /// Returns `true` when the working copy differs from the original file path.
  bool get needsCommit => path != originalPath;

  /// Commits the working copy back to the original picked file.
  Future<void> commit() {
    return AudioMetadataReaderPermissions._channel.invokeMethod<void>('commitPickedFile', {
      'workingPath': path,
      'originalPath': originalPath,
    });
  }
}

/// Represents a security-scoped directory access handle on iOS.
///
/// Dispose this object when the directory is no longer needed to stop
/// security-scoped access.
class AuthorizedDirectory {
  /// The path of the authorized security-scoped directory.
  final String path;
  bool _isDisposed = false;

  AuthorizedDirectory._(this.path);

  /// Stops accessing the authorized directory.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await AudioMetadataReaderPermissions._channel.invokeMethod<void>('stopAccessingDirectory', {
      'path': path,
    });
  }
}

/// Exposes static functions to handle Scoped Storage on Android and Security-Scoped Bookmarks on iOS.
class AudioMetadataReaderPermissions {
  static const MethodChannel _channel = MethodChannel('audio_metadata_reader');

  /// Requests write permission for the given URI on Android.
  ///
  /// Returns the URI with write access granted, or `null` if permission was denied.
  static Future<String?> requestWritePermission(String uri) async {
    if (!Platform.isAndroid) return uri;
    try {
      return await _channel.invokeMethod<String>('requestWritePermission', {
        'uri': uri,
      });
    } catch (e) {
      return null;
    }
  }

  /// Opens an Android File Descriptor for a Content URI in the specified mode (e.g. 'r', 'w', 'rw').
  ///
  /// Returns the integer file descriptor on success, or `null` on failure.
  static Future<int?> openAndroidFileDescriptor(String uri, {String mode = 'r'}) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('openFileDescriptor', {
        'uri': uri,
        'mode': mode,
      });
    } catch (e) {
      return null;
    }
  }

  /// (iOS only) Lets the user pick an audio file for editing.
  ///
  /// The returned [PickedAudioFile] tracks the working copy and can commit changes back
  /// to the original file.
  static Future<PickedAudioFile?> pickAudioFileForEditing() async {
    if (!Platform.isIOS) {
      throw UnsupportedError('pickAudioFileForEditing is only supported on iOS.');
    }

    final result = await _channel.invokeMapMethod<String, String>('pickAudioFile');
    if (result == null) return null;

    final path = result['path'];
    final originalPath = result['originalPath'];
    if (path == null || path.isEmpty || originalPath == null || originalPath.isEmpty) {
      return null;
    }

    return PickedAudioFile._(
      path: path,
      originalPath: originalPath,
      name: result['name'],
    );
  }

  /// (iOS only) Lets the user pick a directory and returns a handle that can
  /// be disposed to stop security-scoped access.
  ///
  /// The plugin already starts access for the selected directory before this
  /// method returns.
  static Future<AuthorizedDirectory?> pickAuthorizedDirectory() async {
    if (!Platform.isIOS) {
      throw UnsupportedError('pickAuthorizedDirectory is only supported on iOS.');
    }

    final result = await _channel.invokeMapMethod<String, String>('pickAndAuthorizeDirectory');
    final path = result?['path'];
    if (path == null || path.isEmpty) return null;

    return AuthorizedDirectory._(path);
  }

  /// (iOS only) Restores a previously authorized directory bookmark for [path]
  /// or one of its ancestor directories.
  static Future<AuthorizedDirectory?> restoreAuthorizedDirectory(String path) async {
    if (!Platform.isIOS) return null;

    final result = await _channel.invokeMapMethod<String, dynamic>(
      'restoreDirectoryAccess',
      {'path': path},
    );
    final authorizedPath = result?['path'] as String?;
    if (authorizedPath == null || authorizedPath.isEmpty) return null;

    return AuthorizedDirectory._(authorizedPath);
  }

  /// (Android only) Copies a content URI to a temporary writable file path
  /// and returns a [PickedAudioFile] wrapping it.
  static Future<PickedAudioFile?> copyContentUriToTemp(String uri, String name) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('copyContentUriToTemp is only supported on Android.');
    }
    try {
      final tempPath = await _channel.invokeMethod<String>('copyContentUriToTemp', {
        'uri': uri,
        'name': name,
      });
      if (tempPath == null || tempPath.isEmpty) return null;
      return PickedAudioFile._(
        path: tempPath,
        originalPath: uri,
        name: name,
      );
    } catch (e) {
      return null;
    }
  }
}
