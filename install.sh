#!/bin/sh
# Installs the latest Audio Adjuster release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/clement880101/audio-adjuster-mac/main/install.sh | sh
#
# Downloads the release asset, checks it, and installs it. It will tell you exactly what
# it is about to do with Gatekeeper and ask first.

set -eu

REPO="clement880101/audio-adjuster-mac"
APP="AudioAdjuster.app"
DEST="/Applications"
ASSET="AudioAdjuster-macos.zip"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- macOS version -----------------------------------------------------------------
# Core Audio process taps are macOS 14.2+. Without them the app has no mechanism at all.
os=$(sw_vers -productVersion 2>/dev/null) || die "this installer is for macOS"
major=${os%%.*}
# A bare "15" has no minor part, and ${os#*.} would hand back the whole string. Testing
# for the dot separates that from "14.2", where the minor genuinely is everything after
# it — conflating the two rejected every macOS 14.2 through 14.9, the exact range this
# check exists to admit.
case "$os" in
    *.*) rest=${os#*.}; minor=${rest%%.*} ;;
    *)   minor=0 ;;
esac
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 2 ]; }; then
    die "macOS 14.2 or later required (found $os)"
fi

# macOS 15 removed the Control-click override for quarantined software that is not
# notarized: the decision moved into System Settings. Both paths are still live because
# this installer supports 14.2 upwards, so pick the one that matches the machine rather
# than the one that used to be true everywhere.
if [ "$major" -ge 15 ]; then
    first_open='try to open it once, then allow it in System Settings > Privacy & Security'
else
    first_open='open it the first time with right-click > Open'
fi

# --- download ----------------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Finding the latest release..."
# Fetched once: the asset URL and its published checksum both come out of this.
release=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") \
    || die "could not reach the GitHub releases API"
url=$(printf '%s' "$release" \
      | grep -o "https://github.com/$REPO/releases/download/[^\"]*/$ASSET" \
      | head -1)
[ -n "$url" ] || die "no published release yet — build from source instead (see the README)"
expected=$(printf '%s' "$release" | grep -oE 'SHA-256[^a-f0-9]{1,8}[a-f0-9]{64}' \
           | grep -oE '[a-f0-9]{64}' | head -1)

say "Downloading $url"
curl -fsSL "$url" -o "$tmp/$ASSET" || die "download failed"

# The checksum published in the release notes. This is not a signature — notes and asset
# come from the same place, so it proves nothing about who built them. It does catch a
# truncated, corrupted or swapped download, which is the failure that actually happens.
if [ -n "$expected" ]; then
    actual=$(shasum -a 256 "$tmp/$ASSET" | cut -d' ' -f1)
    if [ "$expected" != "$actual" ]; then
        die "checksum mismatch — refusing to install
  expected $expected
  got      $actual"
    fi
    say "SHA-256 matches the published release."
else
    say "note: this release published no checksum, so the download was not verified."
fi

say "Unpacking..."
ditto -x -k "$tmp/$ASSET" "$tmp/unpacked" || die "the archive could not be expanded"
[ -d "$tmp/unpacked/$APP" ] || die "the archive did not contain $APP"

# Verifies the bundle still matches the signature sealed into it at build time, so a
# bundle altered after signing is refused. The signature is ad-hoc, so this says nothing
# about who produced it — only that it has not been edited since it was sealed.
codesign --verify --strict "$tmp/unpacked/$APP" 2>/dev/null \
    || die "the app failed its own signature check — refusing to install"

# --- install -----------------------------------------------------------------------
if [ -d "$DEST/$APP" ]; then
    say "Replacing the existing $DEST/$APP"
    pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
    rm -rf "$DEST/$APP"
fi
ditto "$tmp/unpacked/$APP" "$DEST/$APP" || die "could not write to $DEST"
say "Installed $DEST/$APP"

# --- Gatekeeper --------------------------------------------------------------------
# The build is ad-hoc signed rather than notarized, because the project has no Apple
# Developer ID. What that means in practice depends on how the archive arrived: files
# fetched by curl carry no quarantine attribute, so the app simply opens, while a zip
# downloaded through a browser is quarantined and macOS will refuse it until you allow it.
# Check rather than assume, so the advice matches the situation.
if xattr -p com.apple.quarantine "$DEST/$APP" >/dev/null 2>&1; then
    cat <<EXPLAIN

This build is ad-hoc signed, not notarized — the project has no Apple Developer ID,
so macOS cannot verify who built it, and this copy is quarantined.

Two ways forward:
  1. Leave it quarantined and $first_open,
     which lets you read macOS's warning and decide for yourself.
  2. Remove the quarantine flag now, which skips that prompt.

Only choose 2 if you trust where this came from.
EXPLAIN
    if [ -t 0 ] && [ -t 1 ]; then
        printf 'Remove the quarantine flag? [y/N] '
        read -r answer </dev/tty || answer=n
        case "$answer" in
            [Yy]*)
                xattr -d -r com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
                say "Quarantine flag removed."
                ;;
            *) say "Left in place. To run it, $first_open." ;;
        esac
    else
        # Piped from curl, so there is no terminal to ask at. Never strip it silently.
        say "To run it, $first_open."
    fi
else
    say ""
    say "This build is ad-hoc signed rather than notarized, because the project has no"
    say "Apple Developer ID. This copy is not quarantined, so it will open normally."
fi

say ""
say "Launch it with:  open -a $APP"
say "On first use it will ask for audio-recording permission. Process taps are gated"
say "behind it, and without it a tap returns silence rather than an error."
