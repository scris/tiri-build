# Sourced before building. On a Mac with only Apple's free Command Line Tools, makes that work.
# With Xcode there's nothing to do. Xcode is a 12 GB install, and anyone running an agent already has these tools.
#
# Their macOS 27 SDK can't be used: SwiftUI's @State is a macro there, and its plugin ships only inside Xcode. So it's
# their macOS 26 SDK, which Tiri's minimum is anyway. And the terminal library decides whether a newer standard
# library call exists by asking which compiler this is, when it's the SDK that has it, so that one test is changed
# in this checkout of the library. To remove when the library tests the SDK. See CHANGING.md.
tiri_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
case "$tiri_developer_dir" in
*CommandLineTools*)
  tiri_sdk=""
  for candidate in "$tiri_developer_dir"/SDKs/MacOSX26.sdk "$tiri_developer_dir"/SDKs/MacOSX26.*.sdk; do
    if [ -d "$candidate" ]; then tiri_sdk="$candidate"; break; fi
  done
  if [ -z "$tiri_sdk" ]; then
    echo "Building Tiri with the Command Line Tools needs their macOS 26 SDK, and it isn't here." >&2
    exit 69
  fi
  export DEVELOPER_DIR="$tiri_developer_dir" SDKROOT="$tiri_sdk"
  swift package resolve >/dev/null 2>&1
  tiri_scanner=".build/checkouts/SwiftTerm/Sources/SwiftTerm/ByteRunScanner.swift"
  if [ -f "$tiri_scanner" ] && grep -q 'compiler(>=6.4)' "$tiri_scanner"; then
    chmod u+w "$tiri_scanner"
    sed -i '' 's/compiler(>=6\.4)/compiler(>=99)/' "$tiri_scanner"
  fi
  ;;
esac
