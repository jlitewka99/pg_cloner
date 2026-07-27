#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
developer_dir=$(xcode-select -p)

if [[ "$developer_dir" == *CommandLineTools* ]]; then
  print -u2 "Full Xcode is required. Install Xcode, then run:"
  print -u2 "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  exit 2
fi

derived_data="$project_dir/.build/XcodeRelease"
output_dir="$project_dir/dist"
product="$derived_data/Build/Products/Release/PG Cloner.app"
output_app="$output_dir/PG Cloner.app"

mkdir -p "$output_dir"

xcodebuild \
  -quiet \
  -project "$project_dir/PGCloner.xcodeproj" \
  -scheme PGClonerApp \
  -configuration Release \
  -resolvePackageDependencies

xcodebuild \
  -quiet \
  -project "$project_dir/PGCloner.xcodeproj" \
  -scheme PGClonerApp \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$product" ]]; then
  print -u2 "Release product was not created at: $product"
  exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/pgcloner-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
ditto "$product" "$stage/PG Cloner.app"

codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$project_dir/distribution/PGCloner.entitlements" \
  "$stage/PG Cloner.app"

architectures=$(lipo -archs "$stage/PG Cloner.app/Contents/MacOS/PGClonerApp")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  print -u2 "Expected a Universal 2 executable, got: $architectures"
  exit 1
fi

codesign --verify --deep --strict "$stage/PG Cloner.app"
spctl --assess --type execute "$stage/PG Cloner.app" >/dev/null 2>&1 || true

if [[ -e "$output_app" ]]; then
  archive="$output_dir/PG Cloner.previous.$(date +%Y%m%d%H%M%S).app"
  mv "$output_app" "$archive"
fi
mv "$stage/PG Cloner.app" "$output_app"

print "Built: $output_app"
print "Architectures: $architectures"
