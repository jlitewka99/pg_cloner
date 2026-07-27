#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
sdk_path=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
password=pgcloner
if [[ -n ${PGCLONER_POSTGRES_IMAGES:-} ]]; then
  images=(${=PGCLONER_POSTGRES_IMAGES})
else
  images=(postgres:14-alpine postgres:16-alpine postgres:18-alpine)
fi

for image in "${images[@]}"; do
  version=${image#postgres:}
  version=${version%-alpine}
  container="pgcloner-test-${version}-${RANDOM}"
  port=$((54000 + RANDOM % 1000))

  docker run --detach --name "$container" \
    --publish "127.0.0.1:${port}:5432" \
    --env "POSTGRES_PASSWORD=${password}" \
    "$image" >/dev/null

  cleanup() {
    docker rm --force "$container" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM

  ready=false
  for _ in {1..40}; do
    if docker exec "$container" pg_isready --username postgres --dbname postgres >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    docker logs "$container"
    exit 1
  fi

  print "Running PG Cloner integration tests on PostgreSQL ${version}"
  env \
    SDKROOT="$sdk_path" \
    SWIFTPM_MODULECACHE_OVERRIDE=/tmp/pg-cloner-module-cache \
    CLANG_MODULE_CACHE_PATH=/tmp/pg-cloner-clang-cache \
    PGCLONER_TEST_PORT="$port" \
    PGCLONER_TEST_PASSWORD="$password" \
    swift test \
      --disable-sandbox \
      --sdk "$sdk_path" \
      --enable-swift-testing \
      --disable-xctest \
      --filter CloneIntegrationTests

  cleanup
  trap - EXIT INT TERM
done
