#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_path=${1:-"$project_dir/dist/PG Cloner.app"}
output_dir="$project_dir/dist"
release_version=${RELEASE_VERSION:-}

if [[ -z "$release_version" ]]; then
  print -u2 "RELEASE_VERSION is required when creating a Sparkle update archive."
  exit 2
fi
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "RELEASE_VERSION must use MAJOR.MINOR.PATCH, got: $release_version"
  exit 2
fi
if [[ ! -d "$app_path" ]]; then
  print -u2 "Application not found: $app_path"
  exit 2
fi

architectures=$(lipo -archs "$app_path/Contents/MacOS/PGClonerApp")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  print -u2 "Refusing to package a non-Universal app: $architectures"
  exit 1
fi

mkdir -p "$output_dir"
archive_name="PG-Cloner-v${release_version}.zip"
archive_path="$output_dir/$archive_name"
checksum_path="$output_dir/${archive_name}.sha256"
stage=$(mktemp -d "${TMPDIR:-/tmp}/pgcloner-update.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

ditto "$app_path" "$stage/PG Cloner.app"
ditto -c -k --sequesterRsrc --keepParent "$stage/PG Cloner.app" "$archive_path"
checksum=$(shasum -a 256 "$archive_path" | awk '{print $1}')
print "${checksum}  ${archive_name}" > "$checksum_path"

print "Created: $archive_path"
print "SHA-256: $checksum"
