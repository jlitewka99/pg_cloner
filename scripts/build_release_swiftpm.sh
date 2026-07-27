#!/bin/zsh
set -euo pipefail

# Compatibility builder for machines that only have Command Line Tools.
# The Xcode target is the canonical release path and enables @Observable.

project_dir=${0:A:h:h}
sdk_path=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
arm_release="$project_dir/.build/arm64-apple-macosx/release"
intel_release="$project_dir/.build/x86_64-apple-macosx/release"
output_dir="$project_dir/dist"
output_app="$output_dir/PG Cloner.app"

cd "$project_dir"
for architecture in arm64 x86_64; do
  env \
    SDKROOT="$sdk_path" \
    SWIFTPM_MODULECACHE_OVERRIDE=/tmp/pg-cloner-module-cache \
    CLANG_MODULE_CACHE_PATH=/tmp/pg-cloner-clang-cache \
    swift build \
      --disable-sandbox \
      --sdk "$sdk_path" \
      --triple "${architecture}-apple-macosx14.0" \
      --configuration release \
      --product PGClonerApp
done

stage=$(mktemp -d "${TMPDIR:-/tmp}/pgcloner-spm-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
app="$stage/PG Cloner.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

lipo -create \
  "$arm_release/PGClonerApp" \
  "$intel_release/PGClonerApp" \
  -output "$app/Contents/MacOS/PGClonerApp"
cp "$project_dir/distribution/Info.plist" "$app/Contents/Info.plist"

for bundle in "$arm_release"/*.bundle(N); do
  name=${bundle:t}
  ditto "$bundle" "$app/Contents/Resources/$name"
done

codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$project_dir/distribution/PGCloner.entitlements" \
  "$app"

architectures=$(lipo -archs "$app/Contents/MacOS/PGClonerApp")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  print -u2 "Expected a Universal 2 executable, got: $architectures"
  exit 1
fi
codesign --verify --deep --strict "$app"

mkdir -p "$output_dir"
if [[ -e "$output_app" ]]; then
  archive="$output_dir/PG Cloner.previous.$(date +%Y%m%d%H%M%S).app"
  mv "$output_app" "$archive"
fi
mv "$app" "$output_app"

print "Built with SwiftPM compatibility path: $output_app"
print "Architectures: $architectures"
