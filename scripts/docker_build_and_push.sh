#!/usr/bin/env bash
#
# Build the otari Docker image and push it to a repository of your choosing.
#
# The image is built exactly the way .github/workflows/otari-docker.yml builds the
# published one (same Dockerfile, same OTARI_VERSION build arg, same multi-arch
# platform pair), only pointed at a custom repository instead of mzdotai/otari.
#
# Usage: ./scripts/docker_build_push.sh <repository> [options]
# Example: ./scripts/docker_build_push.sh ghcr.io/acme/otari -t dev
#
# Log in to the target registry first: docker login <registry>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILDER_NAME="otari-builder"
DEFAULT_PUSH_PLATFORMS="linux/amd64,linux/arm64"

usage() {
    cat <<'EOF'
Build the otari Docker image and push it to a custom repository.

Usage: ./scripts/docker_build_push.sh <repository> [options]

Arguments:
  <repository>          Target repository, without a tag. Examples:
                          acme/otari                     (Docker Hub)
                          ghcr.io/acme/otari             (GHCR)
                          registry.example.com:5000/otari

Options:
  -t, --tag TAG         Tag to publish. Repeatable. Defaults to "latest" plus the
                        short commit SHA.
  -p, --platform LIST   Comma-separated platforms. Defaults to
                        linux/amd64,linux/arm64 when pushing, and to the host
                        platform when --no-push is given.
      --version VALUE   Value for the OTARI_VERSION build arg. Defaults to
                        `git describe --tags --always --dirty`.
      --no-push         Build only, do not push. A single-platform build is
                        loaded into the local docker images.
      --no-cache        Pass --no-cache to the build.
  -h, --help            Show this help.
  --                    Everything after this is passed straight to
                        `docker buildx build`.

Examples:
  ./scripts/docker_build_push.sh ghcr.io/acme/otari
  ./scripts/docker_build_push.sh acme/otari -t 1.4.0 -t stable
  ./scripts/docker_build_push.sh localhost:5000/otari -p linux/arm64
  ./scripts/docker_build_push.sh acme/otari --no-push

Authentication is docker's own: run `docker login <registry>` (or set up a
credential helper) before this script.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

REPOSITORY=""
TAGS=()
PLATFORMS=""
VERSION=""
PUSH=true
NO_CACHE=false
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -t | --tag)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            TAGS+=("$2")
            shift 2
            ;;
        -p | --platform)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            PLATFORMS="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            VERSION="$2"
            shift 2
            ;;
        --no-push)
            PUSH=false
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --)
            shift
            PASSTHROUGH=("$@")
            break
            ;;
        -*)
            die "unknown option: $1 (see --help)"
            ;;
        *)
            [[ -z "$REPOSITORY" ]] || die "unexpected argument: $1 (repository is already \"$REPOSITORY\")"
            REPOSITORY="$1"
            shift
            ;;
    esac
done

if [[ -z "$REPOSITORY" ]]; then
    usage >&2
    exit 1
fi

# A registry host may legitimately carry a port ("localhost:5000/otari"), so only
# the last path segment is checked for a tag. Tags belong in --tag: silently
# honoring one here would make "repo:a -t b" ambiguous.
if [[ "${REPOSITORY##*/}" == *:* ]]; then
    die "give the repository without a tag (got \"$REPOSITORY\"); use --tag instead"
fi
if [[ "$REPOSITORY" == *@* ]]; then
    die "give the repository without a digest (got \"$REPOSITORY\")"
fi

command -v docker > /dev/null 2>&1 || die "docker is not on PATH"
docker buildx version > /dev/null 2>&1 || die "docker buildx is not available; install the buildx plugin"

git_or_empty() {
    git -C "$REPO_ROOT" "$@" 2> /dev/null || true
}

SHORT_SHA="$(git_or_empty rev-parse --short=7 HEAD)"

if [[ ${#TAGS[@]} -eq 0 ]]; then
    TAGS=("latest")
    [[ -n "$SHORT_SHA" ]] && TAGS+=("$SHORT_SHA")
fi

for tag in "${TAGS[@]}"; do
    [[ -n "$tag" ]] || die "empty tag"
    [[ "$tag" == *[:/]* ]] && die "invalid tag: \"$tag\""
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(git_or_empty describe --tags --always --dirty)"
    VERSION="${VERSION:-0.0.0-dev}"
fi

if [[ -z "$PLATFORMS" ]]; then
    if [[ "$PUSH" == true ]]; then
        PLATFORMS="$DEFAULT_PUSH_PLATFORMS"
    else
        # Building the foreign arch under QEMU costs minutes and yields an image
        # that cannot be loaded locally anyway, so a local build stays native.
        PLATFORMS="$(docker buildx inspect --bootstrap 2> /dev/null | awk -F': *' '/^Platforms:/ {print $2; exit}' | cut -d, -f1 | tr -d ' ')"
        PLATFORMS="${PLATFORMS:-linux/amd64}"
    fi
fi

MULTI_PLATFORM=false
[[ "$PLATFORMS" == *,* ]] && MULTI_PLATFORM=true

# The default "docker" driver cannot build more than one platform in a single
# invocation, and cannot attach provenance or an SBOM, so a multi-platform build
# gets a dedicated docker-container builder. It is passed with --builder rather
# than `create --use`, which would repoint the user's default builder for good.
BUILDER_FLAGS=()
CONTAINER_DRIVER=false
CURRENT_DRIVER="$(docker buildx inspect 2> /dev/null | awk -F': *' '/^Driver:/ {print $2; exit}')"

if [[ "$CURRENT_DRIVER" == "docker" ]]; then
    if [[ "$MULTI_PLATFORM" == true ]]; then
        if ! docker buildx inspect "$BUILDER_NAME" > /dev/null 2>&1; then
            echo "Creating buildx builder \"$BUILDER_NAME\" (the default one cannot build $PLATFORMS)..."
            docker buildx create --name "$BUILDER_NAME" --driver docker-container > /dev/null
        fi
        BUILDER_FLAGS=(--builder "$BUILDER_NAME")
        CONTAINER_DRIVER=true
    fi
else
    CONTAINER_DRIVER=true
fi

BUILD_FLAGS=(
    --file "$REPO_ROOT/Dockerfile"
    --platform "$PLATFORMS"
    --build-arg "OTARI_VERSION=$VERSION"
    --label "org.opencontainers.image.version=$VERSION"
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
)

[[ -n "$SHORT_SHA" ]] && BUILD_FLAGS+=(--label "org.opencontainers.image.revision=$(git_or_empty rev-parse HEAD)")

SOURCE_URL="$(git_or_empty remote get-url origin)"
[[ -n "$SOURCE_URL" ]] && BUILD_FLAGS+=(--label "org.opencontainers.image.source=$SOURCE_URL")

for tag in "${TAGS[@]}"; do
    BUILD_FLAGS+=(--tag "$REPOSITORY:$tag")
done

[[ "$NO_CACHE" == true ]] && BUILD_FLAGS+=(--no-cache)

if [[ "$PUSH" == true ]]; then
    BUILD_FLAGS+=(--push)
    if [[ "$CONTAINER_DRIVER" == true ]]; then
        BUILD_FLAGS+=(--provenance=mode=max --sbom=true)
    fi
elif [[ "$MULTI_PLATFORM" == true ]]; then
    echo "Note: a multi-platform build cannot be loaded into the local image store," >&2
    echo "so the result stays in the build cache only." >&2
else
    BUILD_FLAGS+=(--load)
fi

echo "Repository: $REPOSITORY"
echo "Tags:       ${TAGS[*]}"
echo "Platforms:  $PLATFORMS"
echo "Version:    $VERSION"
echo "Push:       $PUSH"
echo

# The ${a[@]+...} guards keep an empty array from tripping `set -u` on bash 3.2,
# which is what /bin/bash still is on macOS.
set -x
docker buildx build \
    ${BUILDER_FLAGS[@]+"${BUILDER_FLAGS[@]}"} \
    "${BUILD_FLAGS[@]}" \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"} \
    "$REPO_ROOT"
{ set +x; } 2> /dev/null

echo
if [[ "$PUSH" == true ]]; then
    echo "Pushed:"
    for tag in "${TAGS[@]}"; do
        echo "  $REPOSITORY:$tag"
    done
else
    echo "Built (not pushed)."
fi
