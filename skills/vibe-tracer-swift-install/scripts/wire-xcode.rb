#!/usr/bin/env ruby
# frozen_string_literal: true
#
# wire-xcode.rb — Wire Vibe Tracer into an Xcode project.
# Performs the pbxproj surgery that the skill text describes as "manual Xcode clicks":
#   - Adds the SPM package dependency (upToNextMajorVersion from <sdk-version>)
#   - Links the VibeTracer product to the target
#   - Adds Config/Secrets.xcconfig + .example as project file references
#   - Sets baseConfigurationReference on project-level Debug + Release configs
#   - Adds INFOPLIST_KEY_VibeTracerApiKey build setting on the target
#
# Idempotent: re-running is a no-op if everything is already wired.
# Exits non-zero with a clear error on any failure.
#
# Usage: ruby wire-xcode.rb <project-path> <target-name> <sdk-version>
#   <project-path>  path to either the .xcodeproj directory or its project.pbxproj
#   <target-name>   name of the target to wire (e.g. DateCalculator)
#   <sdk-version>   SPM minimum version (e.g. 2.0.1) — taken from skill frontmatter

require 'xcodeproj'

PKG_URL = 'https://github.com/vibetracer/vibetracer-sdk-swift'
PKG_PRODUCT = 'VibeTracer'

def die(msg)
  warn "error: #{msg}"
  exit 1
end

def resolve_xcodeproj_dir(arg)
  path = File.expand_path(arg)
  path = File.dirname(path) if path.end_with?('project.pbxproj')
  die "not a .xcodeproj directory: #{path}" unless path.end_with?('.xcodeproj') && File.directory?(path)
  path
end

project_arg, target_name, sdk_version = ARGV
die "usage: wire-xcode.rb <project-path> <target-name> <sdk-version>" unless project_arg && target_name && sdk_version
die "sdk-version must be semver X.Y.Z, got '#{sdk_version}'" unless sdk_version =~ /\A\d+\.\d+\.\d+\z/

xcodeproj_dir = resolve_xcodeproj_dir(project_arg)
project = Xcodeproj::Project.open(xcodeproj_dir)

target = project.targets.find { |t| t.name == target_name }
die "target '#{target_name}' not found in #{xcodeproj_dir}. available: #{project.targets.map(&:name).join(', ')}" unless target

changes = []

# ─── 1. XCRemoteSwiftPackageReference ──────────────────────────────────────────
pkg_ref = project.root_object.package_references.find do |p|
  p.respond_to?(:repositoryURL) && p.repositoryURL == PKG_URL
end

wanted_requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => sdk_version }

if pkg_ref
  if pkg_ref.requirement != wanted_requirement
    old_min = pkg_ref.requirement['minimumVersion']
    pkg_ref.requirement = wanted_requirement
    if old_min && old_min != sdk_version
      changes << "Updated SPM requirement: upToNextMajorVersion #{old_min} → #{sdk_version}"
    else
      changes << "Updated SPM requirement → upToNextMajorVersion #{sdk_version}"
    end
  end
else
  pkg_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg_ref.repositoryURL = PKG_URL
  pkg_ref.requirement = wanted_requirement
  project.root_object.package_references << pkg_ref
  changes << "Added SPM package #{PKG_URL} (upToNextMajorVersion #{sdk_version})"
end

# ─── 2. XCSwiftPackageProductDependency on the target ──────────────────────────
prod_dep = target.package_product_dependencies.find do |p|
  p.product_name == PKG_PRODUCT && p.package && p.package.uuid == pkg_ref.uuid
end

unless prod_dep
  prod_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  prod_dep.package = pkg_ref
  prod_dep.product_name = PKG_PRODUCT
  target.package_product_dependencies << prod_dep
  changes << "Linked product '#{PKG_PRODUCT}' to target '#{target_name}'"
end

# Ensure it's in the Frameworks build phase (so the linker sees it)
frameworks_phase = target.frameworks_build_phase
already_linked = frameworks_phase.files.any? { |bf| bf.product_ref && bf.product_ref.uuid == prod_dep.uuid }
unless already_linked
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = prod_dep
  frameworks_phase.files << build_file
  changes << "Added '#{PKG_PRODUCT}' to Frameworks build phase"
end

# ─── 3. Config/Secrets.xcconfig + .example file references ─────────────────────
config_group = project.main_group.find_subpath('Config', true)
config_group.set_source_tree('<group>')
config_group.set_path('Config') unless config_group.path == 'Config'

def ensure_xcconfig_ref(group, filename)
  existing = group.files.find { |f| f.path == filename }
  return [existing, false] if existing
  ref = group.new_reference(filename)
  ref.last_known_file_type = 'text.xcconfig'
  [ref, true]
end

secrets_ref, secrets_added = ensure_xcconfig_ref(config_group, 'Secrets.xcconfig')
_example_ref, example_added = ensure_xcconfig_ref(config_group, 'Secrets.xcconfig.example')
changes << 'Added Config/Secrets.xcconfig file reference' if secrets_added
changes << 'Added Config/Secrets.xcconfig.example file reference' if example_added

# ─── 4. baseConfigurationReference on project-level Debug + Release ────────────
project.build_configurations.each do |bc|
  next if bc.base_configuration_reference == secrets_ref

  bc.base_configuration_reference = secrets_ref
  changes << "Set baseConfigurationReference on project's #{bc.name} config"
end

# ─── 5. INFOPLIST_KEY_VibeTracerApiKey on the target ───────────────────────────
target.build_configurations.each do |bc|
  wanted = '$(VIBETRACER_API_KEY)'
  if bc.build_settings['INFOPLIST_KEY_VibeTracerApiKey'] != wanted
    bc.build_settings['INFOPLIST_KEY_VibeTracerApiKey'] = wanted
    changes << "Set INFOPLIST_KEY_VibeTracerApiKey on target's #{bc.name} config"
  end
end

# Warn (not fail) if the target isn't using generated Info.plist — INFOPLIST_KEY_*
# only applies when GENERATE_INFOPLIST_FILE=YES. Older projects need a manual edit
# to their Info.plist file.
warns = []
target.build_configurations.each do |bc|
  gen = bc.build_settings['GENERATE_INFOPLIST_FILE'] || bc.resolve_build_setting('GENERATE_INFOPLIST_FILE')
  if gen && gen.to_s.upcase != 'YES'
    warns << "target '#{target_name}' config '#{bc.name}' has GENERATE_INFOPLIST_FILE=#{gen} — INFOPLIST_KEY_VibeTracerApiKey will be ignored. Add VibeTracerApiKey = $(VIBETRACER_API_KEY) to your Info.plist manually."
  end
end

project.save

if changes.empty?
  puts "✓ No changes needed — project already wired for Vibe Tracer."
else
  puts "✓ Wired Vibe Tracer into #{target_name}:"
  changes.each { |c| puts "  - #{c}" }
end

unless warns.empty?
  puts ""
  warns.each { |w| warn "warning: #{w}" }
end
