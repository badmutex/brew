# frozen_string_literal: true

require "os/mac/version"
require "os/mac/xcode"
require "os/mac/xquartz"
require "os/mac/sdk"
require "os/mac/keg"

module OS
  module Mac
    module_function

    # rubocop:disable Naming/ConstantName
    # rubocop:disable Style/MutableConstant
    ::MacOS = self
    # rubocop:enable Naming/ConstantName
    # rubocop:enable Style/MutableConstant

    raise "Loaded OS::Mac on generic OS!" if ENV["HOMEBREW_TEST_GENERIC_OS"]

    # This can be compared to numerics, strings, or symbols
    # using the standard Ruby Comparable methods.
    def version
      @version ||= Version.new(full_version.to_s[/10\.\d+/])
    end

    # This can be compared to numerics, strings, or symbols
    # using the standard Ruby Comparable methods.
    def full_version
      @full_version ||= Version.new((ENV["HOMEBREW_MACOS_VERSION"] || ENV["HOMEBREW_OSX_VERSION"]).chomp)
    end

    def full_version=(version)
      @full_version = Version.new(version.chomp)
      @version = nil
    end

    def latest_sdk_version
      # TODO: bump version when new Xcode macOS SDK is released
      Version.new "10.15"
    end

    def latest_stable_version
      # TODO: bump version when new macOS is released and also update
      # references in docs/Installation.md and
      # https://github.com/Homebrew/install/blob/master/install
      Version.new "10.15"
    end

    def outdated_release?
      # TODO: bump version when new macOS is released and also update
      # references in docs/Installation.md and
      # https://github.com/Homebrew/install/blob/master/install
      version < "10.13"
    end

    def prerelease?
      version > latest_stable_version
    end

    def languages
      @languages ||= [
        *ARGV.value("language")&.split(","),
        *ENV["HOMEBREW_LANGUAGES"]&.split(","),
        *Open3.capture2("defaults", "read", "-g", "AppleLanguages")[0].scan(/[^ \n"(),]+/),
      ].uniq
    end

    def language
      languages.first
    end

    def active_developer_dir
      @active_developer_dir ||= Utils.popen_read("/usr/bin/xcode-select", "-print-path").strip
    end

    def sdk_root_needed?
      if MacOS::CLT.installed?
        # If there's no CLT SDK, return false
        return false unless MacOS::CLT.provides_sdk?
        # If the CLT is installed and headers are provided by the system, return false
        return false unless MacOS::CLT.separate_header_package?
      end

      true
    end

    # If a specific SDK is requested:
    #
    #   1. The requested SDK is returned, if it's installed.
    #   2. If the requested SDK is not installed, the newest SDK (if any SDKs
    #      are available) is returned.
    #   3. If no SDKs are available, nil is returned.
    #
    # If no specific SDK is requested, the SDK matching the OS version is returned,
    # if available. Otherwise, the latest SDK is returned.

    def sdk(v = nil)
      @locator ||= if CLT.installed? && CLT.provides_sdk?
        CLTSDKLocator.new
      else
        XcodeSDKLocator.new
      end

      @locator.sdk_if_applicable(v)
    end

    def sdk_for_formula(f, v = nil)
      # If the formula requires Xcode, don't return the CLT SDK
      return Xcode.sdk if f.requirements.any? { |req| req.is_a? XcodeRequirement }

      sdk(v)
    end

    # Returns the path to an SDK or nil, following the rules set by {.sdk}.
    def sdk_path(v = nil)
      s = sdk(v)
      s&.path
    end

    def sdk_path_if_needed(v = nil)
      # Prefer CLT SDK when both Xcode and the CLT are installed.
      # Expected results:
      # 1. On Xcode-only systems, return the Xcode SDK.
      # 2. On Xcode-and-CLT systems where headers are provided by the system, return nil.
      # 3. On CLT-only systems with no CLT SDK, return nil.
      # 4. On CLT-only systems with a CLT SDK, where headers are provided by the system, return nil.
      # 5. On CLT-only systems with a CLT SDK, where headers are not provided by the system, return the CLT SDK.

      return unless sdk_root_needed?

      sdk_path(v)
    end

    # See these issues for some history:
    #
    # - https://github.com/Homebrew/legacy-homebrew/issues/13
    # - https://github.com/Homebrew/legacy-homebrew/issues/41
    # - https://github.com/Homebrew/legacy-homebrew/issues/48
    def macports_or_fink
      paths = []

      # First look in the path because MacPorts is relocatable and Fink
      # may become relocatable in the future.
      %w[port fink].each do |ponk|
        path = which(ponk)
        paths << path unless path.nil?
      end

      # Look in the standard locations, because even if port or fink are
      # not in the path they can still break builds if the build scripts
      # have these paths baked in.
      %w[/sw/bin/fink /opt/local/bin/port].each do |ponk|
        path = Pathname.new(ponk)
        paths << path if path.exist?
      end

      # Finally, some users make their MacPorts or Fink directories
      # read-only in order to try out Homebrew, but this doesn't work as
      # some build scripts error out when trying to read from these now
      # unreadable paths.
      %w[/sw /opt/local].map { |p| Pathname.new(p) }.each do |path|
        paths << path if path.exist? && !path.readable?
      end

      paths.uniq
    end

    def app_with_bundle_id(*ids)
      path = mdfind(*ids)
             .reject { |p| p.include?("/Backups.backupdb/") }
             .first
      Pathname.new(path) unless path.nil? || path.empty?
    end

    def mdfind(*ids)
      (@mdfind ||= {}).fetch(ids) do
        @mdfind[ids] = Utils.popen_read("/usr/bin/mdfind", mdfind_query(*ids)).split("\n")
      end
    end

    def pkgutil_info(id)
      (@pkginfo ||= {}).fetch(id) do |key|
        @pkginfo[key] = Utils.popen_read("/usr/sbin/pkgutil", "--pkg-info", key).strip
      end
    end

    def mdfind_query(*ids)
      ids.map! { |id| "kMDItemCFBundleIdentifier == #{id}" }.join(" || ")
    end
  end
end
