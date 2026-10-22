#!/usr/bin/env ruby
# Generate only local provisioning build inputs. No Xcode account/device calls.
require 'json'
require 'pathname'
require 'fileutils'
require 'xcodeproj'

abort 'Usage: ruby prepare_project.rb /absolute/path/to/config.json' unless ARGV.length == 1
config = JSON.parse(File.read(ARGV.fetch(0)))
team = config.fetch('team_id')
abort 'team_id must contain 10 uppercase letters/digits' unless team.match?(/\A[A-Z0-9]{10}\z/)
abort 'Only com.fqapp.fqapp is supported' unless config.fetch('bundle_id') == 'com.fqapp.fqapp'
%w[version build].each do |key|
  abort "Invalid #{key}" unless config.fetch(key).match?(/\A[0-9A-Za-z._-]{1,40}\z/)
end
project_path = Pathname.new(config.fetch('provisioning_project'))
abort 'Use an absolute path ending ProfilePreparation.xcodeproj' unless project_path.absolute? && project_path.basename.to_s == 'ProfilePreparation.xcodeproj'
root = project_path.parent
abort 'Output directory already exists; refusing overwrite' if root.exist? || root.symlink?
File.umask(0o077)
FileUtils.mkdir_p(root.to_s, mode: 0o700)
File.write(root.join('main.c'), "int main(void) { return 0; }\n")
Xcodeproj::Plist.write_to_path({
  'keychain-access-groups' => ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)']
}, root.join('ProfilePreparation.entitlements').to_s)
project = Xcodeproj::Project.new(project_path.to_s)
target = project.new_target(:application, 'ProfilePreparation', :ios, '16.0')
target.source_build_phase.add_file_reference(project.main_group.new_file('main.c'))
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => config.fetch('bundle_id'),
    'DEVELOPMENT_TEAM' => team,
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_IDENTITY' => 'Apple Development',
    'CODE_SIGN_ENTITLEMENTS' => 'ProfilePreparation.entitlements',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Fqapp Profile Preparation',
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'IPHONEOS_DEPLOYMENT_TARGET' => '16.0',
    'CURRENT_PROJECT_VERSION' => config.fetch('build'),
    'MARKETING_VERSION' => config.fetch('version'),
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SUPPORTED_PLATFORMS' => 'iphoneos', 'SDKROOT' => 'iphoneos', 'ONLY_ACTIVE_ARCH' => 'YES'
  })
end
# Resolve the Foundation SDK reference against the selected Xcode, not a fixed SDK version.
project.files.each do |file|
  if file.path&.end_with?('/Foundation.framework')
    file.path = 'System/Library/Frameworks/Foundation.framework'
    file.source_tree = 'SDKROOT'
  end
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project.path, 'ProfilePreparation', true)
puts project_path
