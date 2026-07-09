require_relative "UrlResolver"
require_relative "Icons"

class CopyDownloadStrategy < AbstractFileDownloadStrategy
  def initialize(url, name, version, **meta)
    super
    @cached_location = Pathname.new url
  end
end

class EmacsBase < Formula
  def self.init version
    @@urlResolver = UrlResolver.new(version, ENV["HOMEBREW_EMACS_PLUS_MODE"] || "remote")
  end

  def self.local_patch(name, sha:)
    patch do
      url (@@urlResolver.patch_url name), :using => CopyDownloadStrategy
      sha256 sha
    end
  end

  def self.inject_icon_options
    ICONS_CONFIG.each do |icon, sha|
      option "with-#{icon}-icon", "Using Emacs #{icon} icon"
      next if build.without? "#{icon}-icon"
      resource "#{icon}-icon" do
        url (@@urlResolver.icon_url icon), :using => CopyDownloadStrategy
        sha256 sha
      end
    end
  end

  def path_injection_snippet
    path = PATH.new(ORIGINAL_PATHS)

    # Escape single quotes for use within single-quoted shell string
    # Replace ' with '\'' (end quote, escaped quote, start quote)
    escaped_path = path.to_s.gsub("'", "'\\''")

    <<~EOS
      if [ -z "$EMACS_PLUS_NO_PATH_INJECTION" ]; then
        export PATH='#{escaped_path}'
      fi
    EOS
  end

  # Find the versioned gcc driver (gcc-16 etc.) under the gcc opt prefix.
  # Returns nil when the gcc formula is not installed.
  def find_gcc_executable
    Dir.glob("#{HOMEBREW_PREFIX}/opt/gcc/bin/gcc-*")
       .select { |p| File.basename(p).match?(/\Agcc-\d+\z/) && File.executable?(p) }
       .max_by { |p| File.basename(p).delete_prefix("gcc-").to_i }
  end

  # Directory containing libemutls_w.a, which libgccjit's linker needs to
  # native-compile user packages at runtime.
  #
  # Ask gcc itself via -print-file-name: that is the mechanism the libgccjit
  # driver uses internally, so it is authoritative. A Cellar-wide glob can
  # pick a stale directory when multiple gcc versions are installed; it
  # remains only as a last-resort fallback.
  def find_emutls_dir
    if (gcc = find_gcc_executable)
      path = IO.popen([gcc, "-print-file-name=libemutls_w.a"], err: File::NULL, &:read).strip
      return File.expand_path(File.dirname(path)) if path.include?("/") && File.file?(path)
    end

    gcc_cellar = "#{HOMEBREW_PREFIX}/Cellar/gcc"
    return nil unless File.directory?(gcc_cellar)

    emutls_files = Dir.glob("#{gcc_cellar}/**/libemutls_w.a")
    return nil if emutls_files.empty?

    File.dirname(emutls_files.first)
  end

  # LIBRARY_PATH so GUI-launched Emacs (which has no shell environment) can
  # native-compile user packages: libgccjit's linker needs libemutls_w.a.
  def build_library_path
    [
      find_emutls_dir,
      "#{HOMEBREW_PREFIX}/lib/gcc/current",
      "#{HOMEBREW_PREFIX}/opt/libgccjit/lib/gcc/current",
      "#{HOMEBREW_PREFIX}/lib",
    ].compact.join(":")
  end

  def inject_path
    ohai "Injecting PATH via wrapper script in Emacs.app/Contents/MacOS/Emacs"
    app = "#{prefix}/Emacs.app"
    emacs_binary = "#{app}/Contents/MacOS/Emacs"
    emacs_real = "#{app}/Contents/MacOS/Emacs-real"
    path = PATH.new(ORIGINAL_PATHS)

    puts "Creating wrapper script with following PATH value:"
    path.each_entry { |x|
      puts x
    }

    # LIBRARY_PATH for native compilation: libgccjit's linker needs
    # libemutls_w.a when GUI-launched Emacs native-compiles user packages.
    # Ungated on purpose — native comp needs it regardless of the PATH-injection
    # toggle, and leaking it to child processes is benign (it only extends the
    # linker search path, unlike CC which forced a different compiler).
    library_path = build_library_path
    library_path_line = library_path.empty? ? "" : "export LIBRARY_PATH='#{library_path.gsub("'", "'\\''")}'"

    # Rename original binary
    File.rename(emacs_binary, emacs_real) unless File.exist?(emacs_real)

    # Create wrapper script with relative path for relocatability
    File.open(emacs_binary, "w") do |f|
      f.write <<~EOS
        #!/bin/sh
        #{path_injection_snippet.chomp}
        #{library_path_line}
        exec "$(dirname "$0")/Emacs-real" "$@"
      EOS
    end

    # Make executable
    File.chmod(0755, emacs_binary)
    system "touch '#{app}'"
  end

  def print_env
    ohai "Environment"
    ["CC",
     "CXX",
     "OBJC",
     "OBJCXX",
     "CFLAGS",
     "CXXFLAGS",
     "CPPFLAGS",
     "LDFLAGS",
     "SDKROOT",
     "MAKEFLAGS",
     "CMAKE_PREFIX_PATH",
     "CMAKE_FRAMEWORK_PATH",
     "PKG_CONFIG_PATH",
     "PKG_CONFIG_LIBDIR",
     "HOMEBREW_GIT",
     "ACLOCAL_PATH",
     "PATH",
     "CPATH",
    ].each { |key|
      puts "#{key}: #{ENV[key]}"
    }
  end

  def inject_plist_extras
    ohai "Injecting Info.plist extras"
    app = "#{prefix}/Emacs.app"
    plist = "#{app}/Contents/Info.plist"

    system "/usr/libexec/PlistBuddy -c 'Add NSCameraUsageDescription string' '#{plist}'"
    system "/usr/libexec/PlistBuddy -c 'Set NSCameraUsageDescription Emacs requires permission to access the Camera.' '#{plist}'"
    system "/usr/libexec/PlistBuddy -c 'Add NSMicrophoneUsageDescription string' '#{plist}'"
    system "/usr/libexec/PlistBuddy -c 'Set NSMicrophoneUsageDescription Emacs requires permission to access the Microphone.' '#{plist}'"
    system "/usr/libexec/PlistBuddy -c 'Add NSSpeechRecognitionUsageDescription string' '#{plist}' || true"
    system "/usr/libexec/PlistBuddy -c 'Set NSSpeechRecognitionUsageDescription Emacs requires permission to handle any speech recognition.' '#{plist}' || true"

    plist_set plist, "NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac", "bool", true

    system "touch '#{app}'"
  end

  # Helper method to add or set a plist key (handles both cases)
  def plist_set(plist, key, type, value)
    # Try to add first; if it exists, set it instead
    # Use double quotes for the command to allow proper escaping
    escaped_value = value.to_s.gsub('"', '\\"')
    system "/usr/libexec/PlistBuddy -c \"Add :#{key} #{type} #{escaped_value}\" \"#{plist}\" 2>/dev/null || /usr/libexec/PlistBuddy -c \"Set :#{key} #{escaped_value}\" \"#{plist}\""
  end

  def create_emacs_client_app(icons_dir)
    ohai "Creating Emacs Client.app"

    # Prepare PATH for injection into AppleScript
    path = PATH.new(ORIGINAL_PATHS)
    escaped_path = path.to_s.gsub("'", "'\\''")

    # Create AppleScript source
    client_script = buildpath/"emacs-client.applescript"
    client_script.write <<~EOS
      -- Emacs Client AppleScript Application
      -- Handles opening files from Finder, drag-and-drop, and launching from Spotlight/Dock

      on open theDropped
        repeat with oneDrop in theDropped
          set dropPath to quoted form of POSIX path of oneDrop
          set pathInjection to system attribute "EMACS_PLUS_NO_PATH_INJECTION"
          if pathInjection is "" then
            set pathEnv to "PATH='#{escaped_path}' "
          else
            set pathEnv to ""
          end if
          try
            do shell script pathEnv & "#{prefix}/bin/emacsclient -c -a '' -n " & dropPath
          end try
        end repeat
        tell application "Emacs" to activate
      end open

      -- Handle launch without files (from Spotlight, Dock, or Finder)
      on run
        set pathInjection to system attribute "EMACS_PLUS_NO_PATH_INJECTION"
        if pathInjection is "" then
          set pathEnv to "PATH='#{escaped_path}' "
        else
          set pathEnv to ""
        end if
        try
          do shell script pathEnv & "#{prefix}/bin/emacsclient -c -a '' -n"
        end try
        tell application "Emacs" to activate
      end run
    EOS

    # Compile AppleScript to application bundle
    system "osacompile", "-o", buildpath/"nextstep/Emacs Client.app", client_script

    # Update Info.plist with proper metadata
    client_plist = buildpath/"nextstep/Emacs Client.app/Contents/Info.plist"
    plist_set client_plist, "CFBundleIdentifier", "string", "org.gnu.EmacsClient"
    plist_set client_plist, "CFBundleName", "string", "Emacs Client"
    plist_set client_plist, "CFBundleDisplayName", "string", "Emacs Client"
    plist_set client_plist, "CFBundleGetInfoString", "string", "Emacs Client #{version}"
    plist_set client_plist, "CFBundleVersion", "string", "#{version}"
    plist_set client_plist, "CFBundleShortVersionString", "string", "#{version}"
    plist_set client_plist, "LSApplicationCategoryType", "string", "public.app-category.productivity"
    plist_set client_plist, "NSHumanReadableCopyright", "string", "Copyright © 1989-#{Time.now.year} Free Software Foundation, Inc."

    # Add document types for file associations
    # CFBundleDocumentTypes might already exist from osacompile, delete and recreate
    system "/usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' '#{client_plist}' 2>/dev/null || true"
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes array", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0 dict", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Editor", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Text Document'", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes array", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.text", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes:1 string public.plain-text", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes:2 string public.source-code", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes:3 string public.script", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes:4 string public.shell-script", client_plist
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleDocumentTypes:0:LSItemContentTypes:5 string public.data", client_plist

    # Install custom icon (replace osacompile's default droplet icon)
    client_resources_dir = buildpath/"nextstep/Emacs Client.app/Contents/Resources"

    # Use a simple filename without spaces to avoid quoting issues
    system "cp", icons_dir/"Emacs.icns", client_resources_dir/"applet.icns"

    # Remove default droplet resources created by osacompile
    system "rm", "-f", client_resources_dir/"droplet.icns"
    system "rm", "-f", client_resources_dir/"droplet.rsrc"

    # Remove Assets.car file - on macOS 26+, the system prioritizes icon images
    # from Assets.car over .icns files, so we must remove it to use our custom icon
    system "rm", "-f", client_resources_dir/"Assets.car"

    # Set icon file reference (use simple name without spaces)
    # Try Delete first in case osacompile set it, then Add
    system "/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' '#{client_plist}' 2>/dev/null || true"
    system "/usr/libexec/PlistBuddy", "-c", "Add :CFBundleIconFile string applet", client_plist

    # Verify the icon was set correctly
    icon_check = `/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' '#{client_plist}' 2>&1`.strip
    ohai "Emacs Client.app icon set to: #{icon_check}"
  end
end
