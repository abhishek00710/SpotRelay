#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: bash Scripts/fix_archive_vendor_dsyms.sh [path/to/SpotRelay.xcarchive]" >&2
  exit 64
fi

if [[ $# -eq 1 ]]; then
  ARCHIVE_PATH="$1"
else
  ARCHIVE_PATH="$(find "$HOME/Library/Developer/Xcode/Archives" -name 'SpotRelay*.xcarchive' -print0 \
    | xargs -0 ls -td \
    | head -1)"
fi

if [[ -z "${ARCHIVE_PATH:-}" || ! -d "$ARCHIVE_PATH" ]]; then
  echo "No SpotRelay archive found." >&2
  exit 1
fi

APP_PATH="$ARCHIVE_PATH/Products/Applications/SpotRelay.app"
DSYM_PATH="$ARCHIVE_PATH/dSYMs"

if [[ ! -d "$APP_PATH" ]]; then
  echo "SpotRelay.app not found inside archive: $ARCHIVE_PATH" >&2
  exit 1
fi

mkdir -p "$DSYM_PATH"

frameworks=(
  "FirebaseFirestoreInternal"
  "absl"
  "grpc"
  "grpcpp"
  "openssl_grpc"
)

echo "Archive: $ARCHIVE_PATH"
echo "Generating vendor framework dSYMs..."

for framework in "${frameworks[@]}"; do
  binary="$APP_PATH/Frameworks/$framework.framework/$framework"
  output="$DSYM_PATH/$framework.framework.dSYM"

  if [[ ! -f "$binary" ]]; then
    echo "Skipping $framework: framework binary not found."
    continue
  fi

  dsymutil "$binary" -o "$output" >/dev/null 2>&1 || {
    echo "Failed to generate dSYM for $framework" >&2
    exit 1
  }

  dwarfdump --uuid "$output"
done

echo "Done. Re-upload this archive from Xcode Organizer."
