#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'
require 'rexml/document'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'ios', 'Runner.xcodeproj')
SCHEME_DIRECTORY = File.join(PROJECT_PATH, 'xcshareddata', 'xcschemes')
FLAVORS = %w[community cnViewer cnPro globalStore].freeze
BASE_CONFIGURATIONS = {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release
}.freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
flutter_group = project.main_group.find_subpath('Flutter', false)
raise 'Missing Flutter Xcode group' unless flutter_group

def clone_configuration(owner, source_name, target_name, type)
  existing = owner.build_configurations.find { |configuration| configuration.name == target_name }
  return existing if existing

  source = owner.build_configurations.find { |configuration| configuration.name == source_name }
  raise "Missing base Xcode configuration #{source_name}" unless source

  created = owner.add_build_configuration(target_name, type)
  created.build_settings = source.build_settings.dup
  created.base_configuration_reference = source.base_configuration_reference
  created
end

FLAVORS.each do |flavor|
  scheme_path = File.join(SCHEME_DIRECTORY, "#{flavor}.xcscheme")
  unless File.exist?(scheme_path)
    FileUtils.cp(File.join(SCHEME_DIRECTORY, 'community.xcscheme'), scheme_path)
  end

  BASE_CONFIGURATIONS.each do |base_name, type|
    flavored_name = "#{base_name}-#{flavor}"
    clone_configuration(project, base_name, flavored_name, type)
    project.targets.each do |target|
      configuration = clone_configuration(target, base_name, flavored_name, type)
      if target.name == 'Runner'
        pod_configuration = base_name.downcase
        xcconfig_name = "#{base_name}-#{flavor}.xcconfig"
        xcconfig_path = File.join(ROOT, 'ios', 'Flutter', xcconfig_name)
        File.write(
          xcconfig_path,
          "#include? \"Pods/Target Support Files/Pods-Runner/Pods-Runner.#{pod_configuration}-#{flavor.downcase}.xcconfig\"\n" \
          "#include \"Generated.xcconfig\"\n" \
          "PATH=$(PROJECT_DIR)/../scripts/xcode-bin:$(HOME)/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$(inherited)\n"
        )
        reference_path = "Flutter/#{xcconfig_name}"
        reference = project.files.find { |file| file.path == reference_path }
        reference ||= flutter_group.new_file(reference_path)
        configuration.base_configuration_reference = reference
      end
      next unless target.name == 'Runner' && flavor == 'globalStore'

      release_configuration = base_name == 'Release'
      configuration.build_settings['CADVIEW_ADMOB_IOS_APP_ID'] =
        ENV.fetch(
          'CADVIEW_ADMOB_IOS_APP_ID',
          release_configuration ? '' : 'ca-app-pub-3940256099942544~1458002511'
        )
      configuration.build_settings['CADVIEW_ADMOB_IOS_BANNER_ID'] =
        ENV.fetch(
          'CADVIEW_ADMOB_IOS_BANNER_ID',
          release_configuration ? '' : 'ca-app-pub-3940256099942544/2435281174'
        )
    end
  end

  document = REXML::Document.new(File.read(scheme_path))
  {
    'TestAction' => 'Debug',
    'LaunchAction' => 'Debug',
    'AnalyzeAction' => 'Debug',
    'ProfileAction' => 'Profile',
    'ArchiveAction' => 'Release'
  }.each do |element_name, base_name|
    document.elements.each("Scheme/#{element_name}") do |element|
      element.attributes['buildConfiguration'] = "#{base_name}-#{flavor}"
    end
  end
  formatter = REXML::Formatters::Pretty.new(2)
  formatter.compact = true
  File.open(scheme_path, 'w') do |file|
    file.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    formatter.write(document.root, file)
    file.write("\n")
  end
end

runner_target = project.targets.find { |target| target.name == 'Runner' }
raise 'Missing Runner target' unless runner_target
runner_group = project.main_group.find_subpath('Runner', false)
raise 'Missing Runner Xcode group' unless runner_group
privacy_reference = project.files.find { |file| file.path == 'PrivacyInfo.xcprivacy' }
privacy_reference ||= runner_group.new_file('PrivacyInfo.xcprivacy')
unless runner_target.resources_build_phase.files_references.include?(privacy_reference)
  runner_target.resources_build_phase.add_file_reference(privacy_reference)
end
release_gate = runner_target.shell_script_build_phases.find do |phase|
  phase.name == 'Validate globalStore advertising IDs'
end
release_gate ||= runner_target.new_shell_script_build_phase('Validate globalStore advertising IDs')
release_gate.shell_script = <<~'SH'
  if [ "$CONFIGURATION" = "Release-globalStore" ]; then
    if [ -z "$CADVIEW_ADMOB_IOS_APP_ID" ] || [ -z "$CADVIEW_ADMOB_IOS_BANNER_ID" ]; then
      echo "error: globalStore release requires CADVIEW_ADMOB_IOS_APP_ID and CADVIEW_ADMOB_IOS_BANNER_ID; test IDs must never ship." >&2
      exit 1
    fi
  fi
SH

project.save
puts 'Configured iOS distribution build configurations and schemes.'
