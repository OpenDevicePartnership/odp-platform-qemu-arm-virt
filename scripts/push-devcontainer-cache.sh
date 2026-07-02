#!/usr/bin/env bash
# Rebuild and push the devcontainer image cache to GHCR
#
# SPDX-License-Identifier: MIT
#
# Rebuilds and pushes the devcontainer image cache to GHCR using the
# devcontainer CLI. This ensures the pushed cache uses the same Dockerfile
# wrapper (Dockerfile-with-features) and stage names that the devcontainers/ci
# GitHub Action uses, so CI gets cache hits.
#
# Two-phase approach:
#   1. `devcontainer build --output type=cacheonly` generates the wrapper
#      Dockerfile and populates the local BuildKit cache.
#   2. `docker buildx build --push` rebuilds from local cache, pushes :latest
#      (with inline cache metadata) and writes registry cache to :cache
#      (mode=max, all intermediate layers).
#
# CRITICAL: Step 2 must pass --build-arg BUILDKIT_INLINE_CACHE=1 to match
# what devcontainers/ci does in CI. Without this, the pushed image lacks
# inline cache metadata, and CI's cache chain breaks at COPY instructions.
#
# Prerequisites:
#   - npm i -g @devcontainers/cli
#   - docker login ghcr.io (e.g. via: gh auth token | docker login ghcr.io -u <user> --password-stdin)
#   - docker buildx (with a builder that supports multi-platform)
#
# Usage:
#   ./scripts/push-devcontainer-cache.sh [IMAGE_NAME]
#
# IMAGE_NAME defaults to ghcr.io/<gh-user>/odp-platform-qemu-arm-virt-devcontainer.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve image name: argument > GH_USER env > git config
if [[ -n "${1:-}" ]]; then
    IMAGE_NAME="$1"
else
    GH_USER="${GH_USER:-$(gh api user --jq .login 2>/dev/null || git config github.user || echo "")}"
    if [[ -z "$GH_USER" ]]; then
        echo "ERROR: Could not determine GitHub username." >&2
        echo "Set GH_USER env var, pass IMAGE_NAME as argument, or run 'gh auth login'." >&2
        exit 1
    fi
    # GHCR requires lowercase
    GH_USER="$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]')"
    IMAGE_NAME="ghcr.io/${GH_USER}/odp-platform-qemu-arm-virt-devcontainer"
fi

echo "==> Image name: ${IMAGE_NAME}"
echo "==> Workspace:  ${REPO_ROOT}"

# Derive a Docker-safe tag from the current branch name
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
BRANCH_TAG="$(echo "$BRANCH" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"

echo "==> Branch:     ${BRANCH}"
echo "==> Branch tag:  ${BRANCH_TAG}"

# Step 1: Run devcontainer build to generate the Dockerfile-with-features
# wrapper, populate local BuildKit cache, and push the image to the registry.
echo "==> Generating Dockerfile-with-features via devcontainer build..."
devcontainer build \
    --workspace-folder "$REPO_ROOT" \
    --image-name "${IMAGE_NAME}:${BRANCH_TAG}" \
    --image-name "${IMAGE_NAME}:latest" \
    --platform linux/amd64,linux/arm64 \
    --push true

