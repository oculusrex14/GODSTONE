#!/usr/bin/env bash
# Provision the Android command-line tools from an EXACT pinned archive into a
# VERSION-ADDRESSED directory, and install the SDK packages this project's build
# declares.
#
#   tools/supplychain/provision_android_cmdline_tools.sh [--verify-only] [--quiet]
#
# WHY THIS EXISTS
# ---------------
# The workflow used to fetch a tarball by URL, `unzip` it on the strength of that
# URL alone, and install it at `$ANDROID_HOME/cmdline-tools/latest` -- a SHARED,
# unversioned name that a legitimate but DIFFERENT tool version may already own.
# A URL is a location, not an identity; a preexisting directory is not the pinned
# archive merely because it is there; and "latest" is a name two versions cannot
# both hold. This script:
#
#   1. Reads the HOST-ADDRESSED pin (docs/supplychain/TOOLCHAIN.pins.json): the
#      archive's exact bytes and its sha256 (measured, agreeing with the sha1 and
#      size Google's own repository2-1.xml declareth), and the VERSION-ADDRESSED
#      install subdirectory that pin names. The pin is selected from the ACTUAL
#      host OS (`uname -s`), never guessed and never overridden by a flag.
#   2. Installs into `$ANDROID_HOME/cmdline-tools/<install_subdir>` (e.g.
#      `11076708`), NEVER into a shared `latest`. A user's own `latest` is left
#      byte-identical -- nothing is deleted, nothing is overwritten.
#   3. Verifies a fresh download against the pin BEFORE it is unzipped, then
#      verifies the bytes that landed on disk AGAIN, by content.
#   4. On every use, verifies the version-addressed subtree BY CONTENT against the
#      pinned extracted-tree digest. An existing mismatched directory is refused,
#      never deleted or silently replaced.
#   5. Runs `sdkmanager --licenses` under strict status accounting: the
#      CONSUMER's own status must be 0 (the old `|| true` swallowed a real
#      failure). Confirmations are a checked FINITE file of 64 `y\n` lines
#      handed over on stdin; it EOFs, so the prompt consumes what it needs
#      and the licence scanner never waits on an endless stream. `y`
#      confirms; `/dev/zero` feeds NUL bytes -- not `y` -- which the
#      newline-hungry scanner cannot consume.
#   6. Retains the verified archive outside the checkout and exports its path and
#      the exact installed tree, so the terminal gates verify the bytes actually used.
#
# No `latest` path is ever read or written.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${REPO_ROOT}/docs/supplychain/TOOLCHAIN.pins.json"
VERIFY="${REPO_ROOT}/tools/supplychain/verify_toolchain_download.py"

# Select the measured host archive and its conventional SDK root.
case "$(uname -s)" in
  Darwin)
    ID="android-commandlinetools-macos"
    ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    ;;
  Linux)
    ID="android-commandlinetools-linux"
    ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
    ;;
  *)
    echo "::error::unsupported host $(uname -s): the pinned command-line tools are provisioned only on Darwin and Linux" >&2
    exit 1
    ;;
esac
VERIFY_ONLY=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --verify-only) VERIFY_ONLY=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

# The packages the build itself declares (compileSdk 35; the NDK and the older
# build-tools the AGP wants) -- provisioned OUTSIDE any timed step, so a lazy
# download cannot become a timeout that looks like a broken product.
PACKAGES=("platform-tools" "platforms;android-35" "build-tools;35.0.0"
          "build-tools;34.0.0" "ndk;27.0.12077973")
NDK="27.0.12077973"

command -v python3 >/dev/null || { echo "::error::python3 is required"; exit 1; }
[ -f "$PIN" ] || { echo "::error::the pin is absent: $PIN"; exit 1; }

# The version-addressed subdirectory the pin names; a pin without one is refused.
SUBDIR="$(python3 -c "import json,sys
a=next(x for x in json.load(open(sys.argv[1]))['archives'] if x['id']==sys.argv[2])
print(a.get('install_subdir') or '')" "$PIN" "$ID")"
[ -n "$SUBDIR" ] || { echo "::error::the pin names no version-addressed install_subdir"; exit 1; }
DEST="${ANDROID_HOME}/cmdline-tools/${SUBDIR}"

# Retain the exact input archive, including on a warm install.
ARCHIVE="${GODSTONE_BOARD1_SDK_ARCHIVE:-$ANDROID_HOME/.godstone-downloads/$ID.zip}"
# Reuse one cleanup-owned directory for download, extraction and licence input.
tmp=""
if [ ! -f "$ARCHIVE" ]; then
  [ "$VERIFY_ONLY" -eq 0 ] || { echo "::error::the retained tool archive is absent: $ARCHIVE" >&2; exit 1; }
  mkdir -p "$(dirname "$ARCHIVE")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="$(python3 -c "import json,sys;print(next(a['url'] for a in json.load(open(sys.argv[1]))['archives'] if a['id']==sys.argv[2]))" "$PIN" "$ID")"
  curl -fsSL -o "$tmp/cmdline-tools.zip" "$url"
  python3 "$VERIFY" --config "$PIN" --id "$ID" "$tmp/cmdline-tools.zip"
  mv "$tmp/cmdline-tools.zip" "$ARCHIVE"
fi
python3 "$VERIFY" --config "$PIN" --id "$ID" "$ARCHIVE"

if [ -e "$DEST" ]; then
  python3 "$VERIFY" --config "$PIN" --id "$ID" --verify-tree "$DEST"
  if [ "$QUIET" -eq 0 ]; then
    echo "the pinned cmdline-tools at $DEST match the pinned contents"
  fi
elif [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "::error::the pinned cmdline-tools are absent: $DEST" >&2
  exit 1
else
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  if [ -z "${tmp:-}" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
  fi
  unzip -q "$ARCHIVE" -d "$tmp"
  python3 "$VERIFY" --config "$PIN" --id "$ID" --verify-tree "$tmp/cmdline-tools"
  mv "$tmp/cmdline-tools" "$DEST"
  python3 "$VERIFY" --config "$PIN" --id "$ID" --verify-tree "$DEST"
fi

SDKMANAGER="$DEST/bin/sdkmanager"
[ -x "$SDKMANAGER" ] || { echo "::error::sdkmanager is absent from $DEST"; exit 1; }
if [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "SDKMANAGER=$SDKMANAGER"
  exit 0
fi

# 5. Licences, under strict status accounting.
# The CONSUMER's own status is the authority: a non-zero sdkmanager exit
# reddens the step even after a licence was accepted. Supply is a FINITE file
# of 64 `y\n` confirmations handed to sdkmanager on stdin; it EOFs, so the
# prompt consumes what it needs and the scanner never waits on an endless
# stream. A checked file avoids broken-pipe producer/consumer ambiguity.
# A file that is not EXACTLY the 64 intended lines is refused: a truncated or
# failed write can never be mistaken for a full supply.
licence_yes=""
if [ -z "${tmp:-}" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
fi
licence_yes="$tmp/licence-confirmations.txt"
i=0
while [ "$i" -lt 64 ]; do printf 'y\n'; i=$((i+1)); done > "$licence_yes"
[ "$(wc -l < "$licence_yes")" -eq 64 ] \
  || { echo "::error::the confirmation file is not the full 64 lines"; exit 1; }

set +e
"$SDKMANAGER" --licenses >/dev/null < "$licence_yes"
consumer_status="$?"
set -e
[ "$consumer_status" -eq 0 ] \
  || { echo "::error::sdkmanager --licenses exited $consumer_status (consumer status is the authority)"; exit 1; }

"$SDKMANAGER" "${PACKAGES[@]}"
VERSION="$("$SDKMANAGER" --version)"

# The toolchain is ASSERTED present, so a later silent absence cannot become a
# marker timeout inside a timed step.
test -d "$ANDROID_HOME/ndk/$NDK" \
  || { echo "::error::the NDK the build declares ($NDK) is NOT installed"; exit 1; }

# 6. Persist the EXACT pinned path and version: the workflow uses THIS, never a
# `latest` fallback, so a differently-versioned local `latest` cannot shadow the
# candidate's toolchain.
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "SDKMANAGER=$SDKMANAGER"
    echo "CMDLINE_TOOLS_VERSION=$VERSION"
    echo "ANDROID_HOME=$ANDROID_HOME"
    echo "GODSTONE_BOARD1_SDK_ARCHIVE=$ARCHIVE"
    echo "GODSTONE_BOARD1_SDK_CMDLINE_TOOLS=$DEST"
  } >> "$GITHUB_ENV"
fi
echo "SDKMANAGER=$SDKMANAGER"
echo "CMDLINE_TOOLS_VERSION=$VERSION"
echo "ANDROID_HOME=$ANDROID_HOME"
echo "GODSTONE_BOARD1_SDK_ARCHIVE=$ARCHIVE"
echo "GODSTONE_BOARD1_SDK_CMDLINE_TOOLS=$DEST"
