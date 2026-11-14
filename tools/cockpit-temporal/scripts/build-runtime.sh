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
        arm64) target="aarch64-apple-darwin"; expected="f4b2ff0587d80b6f22bf09ec2d133a3c2949b6423318d3fed0f4ddddddf2f004" ;;
    esac
    archive="postgresql-17.11.1-$target.tar.gz"
    cached="$CACHE_DIR/$archive"
    if [ ! -f "$cached" ] || [ "$(shasum -a 256 "$cached" | awk '{print $1}')" != "$expected" ]; then
        temporary=$(mktemp "$CACHE_DIR/.download.XXXXXX")
        curl --fail --location --silent --show-error --retry 2 -o "$temporary" "https://github.com/theseus-rs/postgresql-binaries/releases/download/17.11.1/$archive"
        if [ "$(shasum -a 256 "$temporary" | awk '{print $1}')" != "$expected" ]; then rm -f "$temporary"; echo "PostgreSQL archive checksum mismatch" >&2; exit 1; fi
        mv -f "$temporary" "$cached"
    fi
    # The checksum pins the reviewed upstream archive. Reject unsafe entry names before extraction.
    if tar -tzf "$cached" | awk 'substr($0,1,1)=="/" || $0 ~ /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit bad ? 0 : 1 }'; then
        echo "Unsafe PostgreSQL archive path" >&2; exit 1
    fi
    output="$DEST_DIR/$arch"
    mkdir -p "$output/postgres" "$output/bin"
    tar -xzf "$cached" -C "$output/postgres" --strip-components 1
    (
        cd tools/cockpit-temporal
        for command in server worker control; do
            GOOS=darwin GOARCH="$arch" go build -mod=readonly -p 2 -trimpath -ldflags='-s -w' -o "$output/bin/$command" "./cmd/$command"
        done
        GOOS=darwin GOARCH="$arch" go build -mod=readonly -p 2 -trimpath -ldflags='-s -w' -o "$output/bin/postgres-supervisor" github.com/fergusstrange/embedded-postgres/v2/cmd/embedded-postgres
    )
done
