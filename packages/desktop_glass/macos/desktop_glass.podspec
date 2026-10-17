Pod::Spec.new do |s|
  s.name = 'desktop_glass'
  s.version = '0.1.0'
  s.summary = 'Session-owned desktop backdrop textures.'
  s.description = s.summary
  s.homepage = 'https://github.com/AndyYJF/glassusage'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'GlassUsage' => 'glassusage' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.3'
  s.swift_version = '5.0'
  s.frameworks = 'ScreenCaptureKit', 'CoreMedia', 'CoreVideo'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
