#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_path=${1:-"$project_dir/dist/PG Cloner.app"}
output_dir="$project_dir/dist"
release_version=${RELEASE_VERSION:-}

if [[ -n "$release_version" && ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "RELEASE_VERSION must use MAJOR.MINOR.PATCH, got: $release_version"
  exit 2
fi

artifact_name="PG-Cloner"
if [[ -n "$release_version" ]]; then
  artifact_name="${artifact_name}-v${release_version}"
fi

dmg_path="$output_dir/${artifact_name}.dmg"
checksum_path="$output_dir/${artifact_name}.dmg.sha256"

if [[ ! -d "$app_path" ]]; then
  print -u2 "Application not found: $app_path"
  print -u2 "Run scripts/build_release.sh first."
  exit 2
fi

architectures=$(lipo -archs "$app_path/Contents/MacOS/PGClonerApp")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  print -u2 "Refusing to package a non-Universal app: $architectures"
  exit 1
fi

mkdir -p "$output_dir"
stage=$(mktemp -d "${TMPDIR:-/tmp}/pgcloner-dmg.XXXXXX")
temporary_dmg="${stage}.dmg"
trap 'rm -rf "$stage"; rm -f "$temporary_dmg"' EXIT INT TERM

ditto "$app_path" "$stage/PG Cloner.app"
ln -s /Applications "$stage/Applications"
cp "$project_dir/distribution/First Run.txt" "$stage/First Run.txt"

hdiutil create \
  -volname "PG Cloner" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$temporary_dmg"

if [[ -e "$dmg_path" ]]; then
  mv "$dmg_path" "$output_dir/${artifact_name}.previous.$(date +%Y%m%d%H%M%S).dmg"
fi
mv "$temporary_dmg" "$dmg_path"

checksum=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
print "${checksum}  ${artifact_name}.dmg" > "$checksum_path"

print "Created: $dmg_path"
print "SHA-256: $checksum"
