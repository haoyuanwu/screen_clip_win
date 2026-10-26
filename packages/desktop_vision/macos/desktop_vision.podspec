#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint desktop_vision.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'desktop_vision'
  s.version          = '0.0.1'
  s.summary          = 'Desktop (macOS/Windows) native OCR with text bounding boxes for Flutter.'
  s.description      = <<-DESC
Flutter plugin that runs OCR fully on device: Apple Vision on macOS and
Windows.Media.Ocr on Windows, returning line/word level bounding boxes.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'desktop_vision/Sources/desktop_vision/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'desktop_vision_privacy' => ['desktop_vision/Sources/desktop_vision/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
