#!/usr/bin/env bash
set -euo pipefail
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_directory="$(cd "$script_directory/.." && pwd)"
tool_directory="$ios_directory/.tools/xcodegen-2.46.0"
archive="$ios_directory/.tools/xcodegen-2.46.0.zip"
xcodegen="$tool_directory/xcodegen/bin/xcodegen"
if [[ ! -x "$xcodegen" ]]; then
  mkdir -p "$ios_directory/.tools" "$tool_directory"
  curl --fail --location --silent --show-error https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip --output "$archive"
  actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual_sha256" == '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806' ]] || { echo 'XcodeGen checksum mismatch' >&2; exit 1; }
  ditto -x -k "$archive" "$tool_directory"
fi
"$xcodegen" generate --spec "$ios_directory/project.yml" --project "$ios_directory"
