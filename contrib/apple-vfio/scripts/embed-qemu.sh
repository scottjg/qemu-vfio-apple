#!/bin/bash
#
# Xcode Run Script build phase: embed qemu-system-aarch64, qemu-img, and their
# dylibs + share data into the host app, signing each item.
#
# qemu-vfio-apple is built as a separate Xcode target ("qemu-vfio-apple") and
# embedded via the host app's "Embed CLI Tools" Copy Files build phase, so
# this script no longer touches it.
#
# Inputs (env):
#   QEMU_DIST_DIR     explicit dist directory override; if its qemu binary
#                     is present it wins over the in-tree and fetched paths
#   TARGET_BUILD_DIR  set by Xcode  (e.g. .../Build/Products/Debug)
#   WRAPPER_NAME      set by Xcode  (e.g. VFIOUserHostApp.app)
#   EXPANDED_CODE_SIGN_IDENTITY[_NAME]  set by Xcode (resolved cert)
#   CONFIGURATION     set by Xcode  (Debug | Release)
#
# Resolution order for the dist directory:
#   1. $QEMU_DIST_DIR (if set and contains qemu-system-aarch64)
#   2. $SRCROOT/../../dist                (in-tree build via
#                                          ./contrib/apple-vfio/scripts/make-dist.sh)
#   3. fetch-qemu-dist.sh — downloads + verifies the pinned tarball into
#      build-cache/qemu-dist/dist (clean checkout / forker without a local
#      qemu source tree)
# If all three fail we still produce a usable UI-only .app, just without
# the qemu binaries embedded.
#
# Layout produced inside the bundle:
#
#   Contents/MacOS/qemu-system-aarch64       (signed w/ hypervisor entitlement)
#   Contents/MacOS/qemu-img                  (signed)
#   Contents/MacOS/lib/*.dylib               (bundled dylibs, signed)
#   Contents/Resources/share/qemu/*          (firmware + descriptors + keymaps)

set -euo pipefail

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${WRAPPER_NAME:-}" ]; then
    echo "error: TARGET_BUILD_DIR / WRAPPER_NAME not set; run from Xcode" >&2
    exit 1
fi

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
MACOS_DIR="$APP/Contents/MacOS"
LIB_DIR="$MACOS_DIR/lib"
SHARE_DIR="$APP/Contents/Resources/share/qemu"
ENTITLEMENTS="$SRCROOT/../../accel/hvf/entitlements.plist"

# pci.ids is consumed by `qemu-vfio-apple list-devices`, which is independent
# of the qemu binary and useful even on dev builds with no dist/. Fetch + copy
# first so we don't skip it via the no-qemu early exit below.
mkdir -p "$APP/Contents/Resources"
PCI_IDS_FETCH="$SRCROOT/scripts/fetch-pci-ids.sh"
PCI_IDS_DEST="$APP/Contents/Resources/pci.ids"
if [ -x "$PCI_IDS_FETCH" ] && "$PCI_IDS_FETCH" "$SRCROOT/build-cache/pci.ids"; then
    cp -f "$SRCROOT/build-cache/pci.ids" "$PCI_IDS_DEST"
    echo "embed-qemu: copied pci.ids ($(wc -c <"$PCI_IDS_DEST" | tr -d ' ') bytes)"
else
    echo "embed-qemu: warning: pci.ids unavailable; list-devices will fall back to hex-only output" >&2
fi

# Resolve the dist directory. Order: env override -> in-tree build -> pinned
# tarball via fetch-qemu-dist.sh.
DIST=""
if [ -n "${QEMU_DIST_DIR:-}" ] && [ -f "${QEMU_DIST_DIR}/qemu-system-aarch64" ]; then
    DIST="$QEMU_DIST_DIR"
    echo "embed-qemu: using QEMU_DIST_DIR override at $DIST"
elif [ -f "$SRCROOT/../../dist/qemu-system-aarch64" ]; then
    DIST="$SRCROOT/../../dist"
    echo "embed-qemu: using in-tree dist at $DIST"
elif [ -x "$SRCROOT/scripts/fetch-qemu-dist.sh" ]; then
    echo "embed-qemu: no local dist; trying pinned tarball via fetch-qemu-dist.sh"
    if FETCHED_DIST="$("$SRCROOT/scripts/fetch-qemu-dist.sh")"; then
        DIST="$FETCHED_DIST"
    else
        echo "embed-qemu: fetch-qemu-dist.sh failed (continuing UI-only)" >&2
    fi
fi

if [ -z "$DIST" ] || [ ! -f "$DIST/qemu-system-aarch64" ]; then
    cat >&2 <<EOF
warning: no qemu dist available; skipping qemu embedding.
  Either:
    - run ./contrib/apple-vfio/scripts/make-dist.sh from the qemu source
      tree to produce a local dist/ at $SRCROOT/../../dist, or
    - publish the pinned tarball described in
      contrib/apple-vfio/scripts/qemu-dist.pin so fetch-qemu-dist.sh can
      pull it.
EOF
    echo "embed-qemu: skipped qemu (no dist/); pci.ids embedded above"
    exit 0
fi

QEMU_BIN="$DIST/qemu-system-aarch64"
QEMU_IMG_BIN="$DIST/qemu-img"

if [ ! -f "$QEMU_IMG_BIN" ]; then
    cat >&2 <<EOF
error: $QEMU_IMG_BIN not found in dist directory at $DIST.
  The dist looks malformed — re-run
  ./contrib/apple-vfio/scripts/make-dist.sh or refresh the pinned tarball.
EOF
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "error: $ENTITLEMENTS not found" >&2
    exit 1
fi

mkdir -p "$MACOS_DIR" "$LIB_DIR" "$SHARE_DIR"

# Pick a signing identity. Xcode provides EXPANDED_CODE_SIGN_IDENTITY
# (the hex SHA1) and EXPANDED_CODE_SIGN_IDENTITY_NAME (human readable).
# Either works for codesign.
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [ -z "$SIGN_ID" ] || [ "${CODE_SIGNING_REQUIRED:-YES}" = "NO" ]; then
    SIGN_ID="-"
fi

# Debug builds skip the timestamp server (no network); Release uses the default
# timestamp so the signature can be notarized later.
TS_OPT=()
if [ "${CONFIGURATION:-Debug}" = "Debug" ]; then
    TS_OPT=(--timestamp=none)
fi

RUNTIME_OPT=()
if [ "$SIGN_ID" != "-" ]; then
    RUNTIME_OPT=(--options runtime)
fi

echo "embed-qemu: copying qemu-system-aarch64"
cp -f "$QEMU_BIN" "$MACOS_DIR/qemu-system-aarch64"
chmod u+w "$MACOS_DIR/qemu-system-aarch64"

echo "embed-qemu: copying qemu-img"
cp -f "$QEMU_IMG_BIN" "$MACOS_DIR/qemu-img"
chmod u+w "$MACOS_DIR/qemu-img"

if [ -d "$DIST/lib" ]; then
    find "$LIB_DIR" -maxdepth 1 -type f -name '*.dylib' -delete
    # shellcheck disable=SC2066
    for src in "$DIST/lib"/*.dylib; do
        [ -f "$src" ] || continue
        cp -f "$src" "$LIB_DIR/"
    done
    chmod -R u+w "$LIB_DIR"
fi

if [ -d "$DIST/share/qemu" ]; then
    rsync -a --delete "$DIST/share/qemu/" "$SHARE_DIR/"
fi

echo "embed-qemu: signing dylibs (identity: $SIGN_ID)"
for dylib in "$LIB_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    codesign --force --sign "$SIGN_ID" ${TS_OPT[@]+"${TS_OPT[@]}"} ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} "$dylib"
done

echo "embed-qemu: signing qemu-img (identity: $SIGN_ID)"
codesign --force --sign "$SIGN_ID" ${TS_OPT[@]+"${TS_OPT[@]}"} ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} \
    "$MACOS_DIR/qemu-img"

echo "embed-qemu: signing qemu-system-aarch64 (identity: $SIGN_ID, entitlements: hypervisor)"
codesign --force --sign "$SIGN_ID" ${TS_OPT[@]+"${TS_OPT[@]}"} ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} \
    --entitlements "$ENTITLEMENTS" \
    "$MACOS_DIR/qemu-system-aarch64"

# Touch the app bundle so Xcode's outer codesign step re-walks it and
# refreshes _CodeSignature/CodeResources to include the new files.
touch "$APP"

echo "embed-qemu: done"
