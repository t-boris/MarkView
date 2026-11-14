#!/bin/bash
# Build the local Temporal helpers and package pinned PostgreSQL distributions for the app.
set -euo pipefail
cd "$(dirname "$0")/../../.."
: "${TARGET_BUILD_DIR:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
: "${CONFIGURATION:?}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v go >/dev/null || { echo "Go is required to build the Cockpit runtime" >&2; exit 1; }
export CGO_ENABLED=0
export GOTOOLCHAIN=auto
CACHE_DIR="${TMPDIR:-/tmp}/markview-cockpit-dependencies"
DEST_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Cockpit"
mkdir -p "$CACHE_DIR" "$DEST_DIR"

# The app and its release currently target Apple Silicon only.
architectures=""
for requested in ${ARCHS:-}; do
    case "$requested" in arm64) architectures="$architectures arm64" ;; *) echo "Only the Apple Silicon architecture is supported: $requested" >&2; exit 1 ;; esac
done
if [ -z "$architectures" ]; then architectures="arm64"; fi
for arch in $architectures; do
    case "$arch" in
        arm64) expected="cdd4023c68cd0a21b8de6ac7c6e325097182a44e60ab037531ba5ac713274661" ;;
    esac
    # Postgres.app's PostgreSQL 16 binaries support macOS 11 and later. Its
    # newer PostgreSQL builds require a newer macOS than MarkView supports.
    archive="Postgres-2.9.7-16.dmg"
    cached="$CACHE_DIR/$archive"
    if [ ! -f "$cached" ] || [ "$(shasum -a 256 "$cached" | awk '{print $1}')" != "$expected" ]; then
        temporary=$(mktemp "$CACHE_DIR/.download.XXXXXX")
        curl --fail --location --silent --show-error --retry 2 -o "$temporary" "https://github.com/PostgresApp/PostgresApp/releases/download/v2.9.7/$archive"
        if [ "$(shasum -a 256 "$temporary" | awk '{print $1}')" != "$expected" ]; then rm -f "$temporary"; echo "PostgreSQL archive checksum mismatch" >&2; exit 1; fi
        mv -f "$temporary" "$cached"
    fi
    output="$DEST_DIR/$arch"
    # Do not leave binaries from a previous PostgreSQL distribution in the app.
    rm -rf "$output/postgres"
    mkdir -p "$output/postgres" "$output/bin"
    mountpoint=$(mktemp -d "${TMPDIR:-/tmp}/markview-pg.XXXXXX")
    cleanup_mount() { hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true; rmdir "$mountpoint" 2>/dev/null || true; }
    trap cleanup_mount EXIT
    hdiutil attach -nobrowse -readonly -mountpoint "$mountpoint" "$cached" -quiet
    for directory in bin lib share; do
        ditto --arch arm64 "$mountpoint/Postgres.app/Contents/Versions/16/$directory" "$output/postgres/$directory"
    done
    cleanup_mount
    trap - EXIT
    # Fail packaging if a future upstream binary raises the deployment target.
    check_minimum_os() {
        awk '/LC_BUILD_VERSION/ { build = 1; next } build && /minos/ { if (($2 + 0) > 13) { print "PostgreSQL binary requires macOS " $2 > "/dev/stderr"; bad = 1 } build = 0 } END { exit bad }'
    }
    /usr/bin/otool -arch arm64 -l "$output/postgres/bin/postgres" "$output/postgres/bin/initdb" "$output/postgres/bin/pg_ctl" | check_minimum_os
    find "$output/postgres/lib" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | xargs -0 /usr/bin/otool -arch arm64 -l | check_minimum_os
    (
        cd tools/cockpit-temporal
        for command in server worker control terminal-watchdog; do
            GOOS=darwin GOARCH="$arch" go build -mod=readonly -p 2 -trimpath -ldflags='-s -w' -o "$output/bin/$command" "./cmd/$command"
        done
        GOOS=darwin GOARCH="$arch" go build -mod=readonly -p 2 -trimpath -ldflags='-s -w' -o "$output/bin/postgres-supervisor" github.com/fergusstrange/embedded-postgres/v2/cmd/embedded-postgres
    )
done
