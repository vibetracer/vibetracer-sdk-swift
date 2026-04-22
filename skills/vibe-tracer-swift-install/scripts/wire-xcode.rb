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

# ─── 5. File-based Info.plist with VibeTracerApiKey ────────────────────────────
# Why a file, not INFOPLIST_KEY_*: Xcode's Info.plist auto-generator only
# promotes `INFOPLIST_KEY_<Foo>` for `<Foo>` on Apple's allowlist (CFBundle*,
# NSCamera*, UILaunchScreen_*, etc.). Custom keys are silently dropped.
# Without a file-based plist, runtime `Bundle.main.object(forInfoDictionaryKey:)`
# returns nil → `?? ""` → `configure(apiKey: "")` → every event dropped.
#
# Strategy: if the target already has INFOPLIST_FILE set on any config, patch
# THAT file (preserves user's existing key arrangement and per-config splits).
# Otherwise create `<target_dir>/Info.plist` with just the VibeTracerApiKey
# entry and set INFOPLIST_FILE on Debug + Release.  GENERATE_INFOPLIST_FILE = YES
# stays untouched — Xcode treats the file as a seed and merges Apple-recognized
# keys on top, so nothing the user expects from auto-generation is lost.

require 'rexml/document'
require 'set'

VIBETRACER_PLIST_KEY = 'VibeTracerApiKey'
VIBETRACER_PLIST_VAL = '$(VIBETRACER_API_KEY)'

# Set of INFOPLIST_FILE paths the target's configs reference (deduped).
existing_plist_paths = Set.new
target.build_configurations.each do |bc|
  raw = bc.build_settings['INFOPLIST_FILE']
  existing_plist_paths << raw if raw && !raw.empty?
end

# Resolve a build-setting-style path (may contain `$(SRCROOT)`, `$(TARGET_NAME)`)
# to an absolute filesystem path, anchored at the .xcodeproj's parent dir.
def resolve_plist_path(raw, xcodeproj_dir, target_name)
  proj_root = File.dirname(xcodeproj_dir)
  expanded = raw
    .gsub('$(SRCROOT)', proj_root)
    .gsub('$(PROJECT_DIR)', proj_root)
    .gsub('$(TARGET_NAME)', target_name)
  expanded.start_with?('/') ? expanded : File.join(proj_root, expanded)
end

# Read / mutate / write a single Info.plist. Returns true if the file changed
# (so the caller can record a change). Idempotent: if the key is already
# present with the right value, returns false without rewriting.
def ensure_vibetracer_key(path)
  if File.exist?(path)
    doc = REXML::Document.new(File.read(path))
    dict = doc.root&.elements&.[]('dict')
    die "expected <plist><dict>...</dict></plist> shape in #{path}" unless dict

    # Walk dict children pairwise: <key>...</key><value>...</value>.
    # `dict.elements` is XPath-ordered, so we can pair them by index.
    children = dict.elements.to_a
    pairs = children.each_slice(2).to_a
    target_pair = pairs.find { |k, _v| k && k.text == VIBETRACER_PLIST_KEY }

    if target_pair
      _, value_node = target_pair
      if value_node && value_node.name == 'string' && value_node.text == VIBETRACER_PLIST_VAL
        return false
      end
      # Replace value in place — preserves the key's position among siblings.
      new_value = REXML::Element.new('string')
      new_value.text = VIBETRACER_PLIST_VAL
      dict.replace_child(value_node, new_value) if value_node
    else
      # Append <key>VibeTracerApiKey</key><string>$(VIBETRACER_API_KEY)</string>
      key_node = REXML::Element.new('key')
      key_node.text = VIBETRACER_PLIST_KEY
      val_node = REXML::Element.new('string')
      val_node.text = VIBETRACER_PLIST_VAL
      dict.add_element(key_node)
      dict.add_element(val_node)
    end

    formatter = REXML::Formatters::Pretty.new(4)
    formatter.compact = true
    File.open(path, 'w') do |f|
      f.write(%(<?xml version="1.0" encoding="UTF-8"?>\n))
      f.write(%(<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n))
      formatter.write(doc.root, f)
      f.write("\n")
    end
    true
  else
    # Greenfield case — write a minimal plist containing only our key. Xcode
    # merges Apple-recognized auto-generated keys on top when GENERATE_INFOPLIST_FILE=YES.
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>#{VIBETRACER_PLIST_KEY}</key>
          <string>#{VIBETRACER_PLIST_VAL}</string>
      </dict>
      </plist>
    PLIST
    true
  end
end

require 'fileutils'

if existing_plist_paths.empty?
  # No INFOPLIST_FILE set anywhere — provision <target_dir>/Info.plist.
  # Default target dir = target name (Xcode's New Project default).
  target_dir = File.join(File.dirname(xcodeproj_dir), target_name)
  plist_rel = File.join(target_name, 'Info.plist')
  plist_abs = File.join(File.dirname(xcodeproj_dir), plist_rel)

  if ensure_vibetracer_key(plist_abs)
    changes << "Created #{plist_rel} with #{VIBETRACER_PLIST_KEY} = #{VIBETRACER_PLIST_VAL}"
  end

  target.build_configurations.each do |bc|
    next if bc.build_settings['INFOPLIST_FILE'] == plist_rel

    bc.build_settings['INFOPLIST_FILE'] = plist_rel
    changes << "Set INFOPLIST_FILE = #{plist_rel} on target's #{bc.name} config"
  end
else
  # User already has INFOPLIST_FILE set — patch each referenced file in place
  # rather than redirecting to a new one. Each path may differ across configs
  # (rare but legitimate), so we touch them all.
  existing_plist_paths.each do |raw|
    abs = resolve_plist_path(raw, xcodeproj_dir, target_name)
    if ensure_vibetracer_key(abs)
      changes << "Patched #{raw} to include #{VIBETRACER_PLIST_KEY}"
    end
  end
end

# Strip any stale INFOPLIST_KEY_VibeTracerApiKey (the silently-dropped setting
# from prior installs). Leaving it in place is harmless at runtime but makes
# future diagnosis confusing — anyone inspecting the pbxproj would assume it
# does something. The file-based Info.plist is now the source of truth.
target.build_configurations.each do |bc|
  if bc.build_settings.delete('INFOPLIST_KEY_VibeTracerApiKey')
    changes << "Removed stale INFOPLIST_KEY_VibeTracerApiKey from target's #{bc.name} config (file-based Info.plist is now the source of truth)"
  end
end

# Warn if GENERATE_INFOPLIST_FILE is explicitly OFF on any config. The
# file-based plist still works, but the user loses Xcode's auto-generation of
# Apple keys (CFBundleExecutable etc.) — they're on their own to populate
# those. Rare; surfaces as an error at first run if missing.
warns = []
target.build_configurations.each do |bc|
  gen = bc.build_settings['GENERATE_INFOPLIST_FILE'] || bc.resolve_build_setting('GENERATE_INFOPLIST_FILE')
  if gen && gen.to_s.upcase == 'NO'
    warns << "target '#{target_name}' config '#{bc.name}' has GENERATE_INFOPLIST_FILE = NO. The file-based Info.plist provisioned here only contains VibeTracerApiKey — you'll need to add CFBundleExecutable, CFBundleIdentifier, etc. yourself, or flip GENERATE_INFOPLIST_FILE back to YES so Xcode merges them in."
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
