# CocoaPods Specification for audio_metadata_reader iOS platform delegate.
# It defines source files, dependencies, platform constraints, and compiler options.
Pod::Spec.new do |s|
  s.name             = 'audio_metadata_reader'
  s.version          = '1.6.0'
  s.summary          = 'Android and iOS permission handling delegate for audio_metadata_reader.'
  s.description      = 'Handles iOS security-scoped bookmark permissions and Android Scoped Storage file descriptors.'
  s.homepage         = 'https://github.com/ClementBeal/audio_metadata_reader'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Clement Beal' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
