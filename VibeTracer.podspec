Pod::Spec.new do |s|
  s.name             = 'VibeTracer'
  s.version          = '1.1.3'
  s.summary          = 'Agent-native analytics SDK for Apple platforms.'
  s.description      = <<-DESC
    Vibe Tracer is the analytics SDK for vibe coders — install via the
    vibe-tracer-swift Claude Code skill, configure with one line, track
    events from anywhere. Persistent on-disk queue with exponential
    backoff, auto-tracked session events, Apple privacy manifest.
  DESC
  s.homepage         = 'https://github.com/vibetracer/vibetracer-sdk-swift'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Vibe Tracer' => 'dev@vibetracer.xyz' }
  s.source           = { :git => 'https://github.com/vibetracer/vibetracer-sdk-swift.git', :tag => s.version.to_s }

  s.swift_version = '5.9'
  s.ios.deployment_target     = '17.0'
  s.osx.deployment_target     = '14.0'
  s.tvos.deployment_target    = '17.0'
  s.watchos.deployment_target = '10.0'
  s.visionos.deployment_target = '1.0'

  s.source_files = 'Sources/VibeTracer/**/*.swift'
  s.resource_bundles = {
    'VibeTracer' => ['Sources/VibeTracer/PrivacyInfo.xcprivacy']
  }
  s.frameworks = 'Foundation', 'Network'
end
