#!/usr/bin/env bash
#
# Push a prebaked qcow2 artifact + its manifest to GHCR as an OCI
# artifact. Intended to be run after `build-image.sh <profile>`
# emits $ARTIFACT_DIR/<name>.qcow2 and <name>.manifest.json.
#
# The artifact ends up at:
#
#   ghcr.io/scottjg/qemu-vfio-apple-images:<name>           (immutable)
#   ghcr.io/scottjg/qemu-vfio-apple-images:<rolling>        (rolling alias)
#
# The rolling alias is derived from the manifest's profile so a docker
# publish can never clobber the desktop's :latest by accident:
#
#   desktop -> latest
#   docker  -> docker-latest
#
# Override with ROLLING_TAG=..., or skip it with ALSO_TAG_LATEST=0.
#
# qemu-vfio-apple speaks the OCI registry API directly (no oras runtime
# needed on the client) but `oras` is by far the simplest way to *push*
# a single blob as a single-layer manifest on the publish side, so we
# require it here.
#
# Usage:
#   GH_TOKEN=ghp_xxx \
#   ./contrib/apple-vfio/image-builder/scripts/publish-to-ghcr.sh \
#       [artifact-dir]
#
# With defaults:
#   artifact-dir = contrib/apple-vfio/image-builder/out/ubuntu-desktop-image/artifacts
#
# Environment:
#   GH_USER            GitHub username (default: scottjg)
#   GH_TOKEN           PAT with write:packages scope (required for push)
#   GHCR_REPO          registry path (default: ghcr.io/scottjg/qemu-vfio-apple-images)
#   SOURCE_REPO_URL    OCI annotation linking the artifact to a source repo
#                      (default: https://github.com/scottjg/qemu-vfio-apple)
#   ALSO_TAG_LATEST    set to 0 to skip the rolling alias push
#   ROLLING_TAG        override the profile-derived rolling alias
#
# Intentionally *not* shipping base+delta qcow2 layering yet — each
# release gets a single-blob manifest. The layering can be added later
# without breaking the manifest layout the launcher parses.

set -euo pipefail

ARTIFACT_DIR="${1:-contrib/apple-vfio/image-builder/out/ubuntu-desktop-image/artifacts}"

GH_USER="${GH_USER:-scottjg}"
GH_TOKEN="${GH_TOKEN:-}"
GHCR_REPO="${GHCR_REPO:-ghcr.io/scottjg/qemu-vfio-apple-images}"
SOURCE_REPO_URL="${SOURCE_REPO_URL:-https://github.com/scottjg/qemu-vfio-apple}"
ALSO_TAG_LATEST="${ALSO_TAG_LATEST:-1}"

log() { printf '[publish-to-ghcr] %s\n' "$*"; }
die() { printf '[publish-to-ghcr] error: %s\n' "$*" >&2; exit 1; }

[ -d "$ARTIFACT_DIR" ] || die "artifact dir not found: $ARTIFACT_DIR"

GH_TOKEN_SOURCE="env"
if [ -z "$GH_TOKEN" ]; then
    GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    GH_TOKEN_SOURCE="gh"
fi
[ -n "$GH_TOKEN" ]     || die "GH_TOKEN is required (PAT with write:packages)"

command -v oras >/dev/null 2>&1 || die "oras not installed. brew install oras"
command -v jq   >/dev/null 2>&1 || die "jq not installed. brew install jq"

# gh auth login requests the default CLI scopes (repo, read:org, gist,
# workflow) and does NOT include write:packages. A token coming out of
# `gh auth token` therefore fails at push time with the very unhelpful
# "denied: permission_denied: The token provided does not match
# expected scopes." error from ghcr.io. Fail fast with a clear fix
# message instead of spending minutes on a blob upload that will be
# rejected at the end.
#
# Fine-grained PATs don't expose x-oauth-scopes, so an empty header is
# not conclusive — we only *warn* on missing header, and only *die* if
# we have a header but it lacks write:packages.
check_token_scopes() {
    local hdr scopes
    hdr="$(curl -fsS -I -H "Authorization: token $GH_TOKEN" \
            https://api.github.com/user 2>/dev/null || true)"
    scopes="$(printf '%s' "$hdr" \
              | awk -F': ' 'tolower($1)=="x-oauth-scopes" {sub(/\r$/,"",$2); print $2; exit}')"

    if [ -z "$scopes" ]; then
        log "could not read x-oauth-scopes from api.github.com"
        log "  (fine-grained PATs omit this header; proceeding)"
        return 0
    fi

    # GitHub returns scopes comma+space separated ("gist, read:org, ...").
    # Normalize to a comma-only list before pattern matching so the case
    # statement doesn't need to care about whitespace.
    local normalized
    normalized="$(printf '%s' "$scopes" | tr -d '[:space:]')"
    case ",$normalized," in
        *,write:packages,*) return 0 ;;
    esac

    printf '[publish-to-ghcr] error: token is missing the write:packages scope\n' >&2
    printf '[publish-to-ghcr]        current scopes: %s\n' "$scopes" >&2
    if [ "$GH_TOKEN_SOURCE" = "gh" ]; then
        printf '[publish-to-ghcr]        fix: gh auth refresh -h github.com -s write:packages,read:packages\n' >&2
    else
        printf '[publish-to-ghcr]        fix: regenerate your PAT with write:packages (and read:packages)\n' >&2
    fi
    exit 1
}
check_token_scopes

# Find the single manifest.json in the artifact dir. The builder only
# produces one per run; if there are several we bail rather than guess.
manifest_count=$(find "$ARTIFACT_DIR" -maxdepth 1 -name '*.manifest.json' | wc -l | tr -d ' ')
[ "$manifest_count" -eq 1 ] \
    || die "expected exactly one *.manifest.json in $ARTIFACT_DIR, found $manifest_count"

MANIFEST_JSON=$(find "$ARTIFACT_DIR" -maxdepth 1 -name '*.manifest.json')
IMAGE_NAME=$(jq -r '.name'     "$MANIFEST_JSON")
ARTIFACT_FN=$(jq -r '.artifact' "$MANIFEST_JSON")
ARTIFACT_PATH="$ARTIFACT_DIR/$ARTIFACT_FN"
SHA256=$(jq -r '.sha256'       "$MANIFEST_JSON")

# Profile-derived rolling alias. The desktop image owns bare :latest
# (it's the launcher's default --image); every other profile gets its
# own <profile>-latest so publishing it can't hijack desktop users.
PROFILE=$(jq -r '.features // {}
    | if .docker == true then "docker"
      elif .desktop == true then "desktop"
      else "unknown" end' "$MANIFEST_JSON")
if [ -z "${ROLLING_TAG:-}" ]; then
    case "$PROFILE" in
        desktop) ROLLING_TAG="latest" ;;
        docker)  ROLLING_TAG="docker-latest" ;;
        *)       ROLLING_TAG="" ;;
    esac
fi
if [ "$ALSO_TAG_LATEST" = "1" ] && [ -z "$ROLLING_TAG" ]; then
    log "manifest has no recognizable profile; skipping the rolling alias"
    log "  (pass ROLLING_TAG=... to set one explicitly)"
fi

[ -f "$ARTIFACT_PATH" ] || die "artifact missing: $ARTIFACT_PATH"

# Re-verify the sha256 so we don't push a corrupt image that happens to
# have a stale manifest pointing at it.
log "verifying sha256 of $ARTIFACT_FN"
actual_sha=$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')
[ "$actual_sha" = "$SHA256" ] \
    || die "sha256 mismatch: manifest=$SHA256, file=$actual_sha"

log "logging in to ghcr.io as $GH_USER"
echo "$GH_TOKEN" | oras login ghcr.io -u "$GH_USER" --password-stdin

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stage the files with readable names inside the OCI manifest. oras
# uses the on-disk filename as the layer title annotation by default.
cp "$ARTIFACT_PATH"  "$work/"
cp "$MANIFEST_JSON"  "$work/manifest.json"

pushd "$work" >/dev/null

artifact_type="application/vnd.scottjg.qemu-vfio.image.v1"

# Push once under the immutable name, then use `oras tag` to alias
# :latest to the same manifest. We can't just push twice: oras stamps
# `org.opencontainers.image.created` into the manifest annotations on
# every push, so two back-to-back pushes of the same content produce
# two manifests with different digests (same blob digests, but the
# manifest bytes differ by a few seconds in the timestamp). That's
# confusing on the registry UI and breaks any consumer that pins by
# manifest digest. Aliasing keeps :latest and :<name> pointing at the
# byte-identical manifest.
log "pushing $GHCR_REPO:$IMAGE_NAME"
oras push "$GHCR_REPO:$IMAGE_NAME" \
    --artifact-type "$artifact_type" \
    --annotation "org.opencontainers.image.source=$SOURCE_REPO_URL" \
    --annotation "org.opencontainers.image.title=$IMAGE_NAME" \
    --annotation "org.opencontainers.image.description=apple-vfio prebaked Ubuntu aarch64, $PROFILE profile (qcow2, single blob)" \
    --annotation "org.opencontainers.image.licenses=GPL-2.0" \
    "$ARTIFACT_FN:application/vnd.scottjg.qemu-vfio.qcow2" \
    "manifest.json:application/vnd.scottjg.qemu-vfio.image.manifest.v1+json"

if [ "$ALSO_TAG_LATEST" = "1" ] && [ -n "$ROLLING_TAG" ]; then
    log "aliasing $GHCR_REPO:$ROLLING_TAG -> $GHCR_REPO:$IMAGE_NAME"
    oras tag "$GHCR_REPO:$IMAGE_NAME" "$ROLLING_TAG"
fi

popd >/dev/null

log "done. pull with:"
log "  qemu-vfio-apple pull --image $GHCR_REPO:$IMAGE_NAME"
if [ "$ALSO_TAG_LATEST" = "1" ] && [ -n "$ROLLING_TAG" ]; then
    log "  qemu-vfio-apple pull --image $GHCR_REPO:$ROLLING_TAG"
fi
