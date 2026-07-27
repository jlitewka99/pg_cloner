#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
release_version=${RELEASE_VERSION:-}
private_key=${SPARKLE_ED25519_PRIVATE_KEY:-}
generator=${SPARKLE_GENERATE_APPCAST:-}
output_path=${1:-"$project_dir/dist/appcast.xml"}

if [[ -z "$release_version" || ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Set RELEASE_VERSION to MAJOR.MINOR.PATCH before generating the appcast."
  exit 2
fi
if [[ -z "$private_key" ]]; then
  print -u2 "SPARKLE_ED25519_PRIVATE_KEY is required and must be supplied through the environment."
  exit 2
fi
if [[ -z "$generator" || ! -x "$generator" ]]; then
  print -u2 "Set SPARKLE_GENERATE_APPCAST to Sparkle's generate_appcast executable."
  exit 2
fi

archive="$project_dir/dist/PG-Cloner-v${release_version}.zip"
if [[ ! -f "$archive" ]]; then
  print -u2 "Update archive not found: $archive"
  exit 2
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/pgcloner-appcast.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
cp "$archive" "$stage/${archive:t}"

download_prefix="https://github.com/jlitewka99/pg_cloner/releases/download/v${release_version}/"
printf '%s' "$private_key" | "$generator" \
  --ed-key-file - \
  --download-url-prefix "$download_prefix" \
  --maximum-deltas 0 \
  --maximum-versions 1 \
  -o "$output_path" \
  "$stage"

print "Created signed appcast: $output_path"
