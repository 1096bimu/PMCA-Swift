#!/bin/bash
set -euo pipefail
SOURCE="$SRCROOT/Engine/Runtime/PMCAEngine.app"
TARGET="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/PMCAEngine.app"
if [ ! -x "$SOURCE/Contents/MacOS/pmca-engine" ]; then
  echo 'error: Bundled PMCA engine is missing. Run Scripts/build-engine.sh with the Python environment described in README.md.'
  exit 1
fi
mkdir -p "$TARGET"
/usr/bin/rsync -a --delete "$SOURCE/" "$TARGET/"
# Finder metadata from synced source folders is not executable content.
/usr/bin/xattr -dr com.apple.FinderInfo "$TARGET_BUILD_DIR/$WRAPPER_NAME" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$TARGET_BUILD_DIR/$WRAPPER_NAME" 2>/dev/null || true
# PyInstaller signs the helper and its libraries ad hoc. Re-sign the helper tree
# with Xcode's identity for signed local builds; the outer app is signed by Xcode.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --deep --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$TARGET"
fi
