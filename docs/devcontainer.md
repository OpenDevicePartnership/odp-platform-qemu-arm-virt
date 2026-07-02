# Devcontainer Image

This project uses a [devcontainer](https://containers.dev/) for CI and local
development. The image is defined in `.devcontainer/Dockerfile` and configured
by `.devcontainer/devcontainer.json`.

## How the CI cache works

The GitHub Actions workflow (`.github/workflows/build.yml`) builds the
devcontainer using the
[`devcontainers/ci`](https://github.com/devcontainers/ci) action. That action
wraps the Dockerfile in a generated `Dockerfile-with-features` which renames
the build stage to `dev_container_auto_added_stage_label`. The BuildKit cache
is keyed on the **full build graph including stage names**, so cache images must
be built with the same wrapper to get cache hits.

### Pre-seeding the cache

When the Dockerfile changes, the first CI run will rebuild every layer from
scratch. To avoid this, you can pre-seed the GHCR cache from your local
machine:

```bash
# 1. Log in to GHCR
gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin

# 2. Run the push script
./scripts/push-devcontainer-cache.sh
```

The script uses the `devcontainer build` CLI to generate the same Dockerfile
wrapper that CI uses (with the `dev_container_auto_added_stage_label` stage
name). It then runs `docker buildx build` with `--cache-to type=registry,mode=max`
to push **all** intermediate layers as registry cache. This avoids the limitations
of `BUILDKIT_INLINE_CACHE=1` (inline cache), which can silently drop cache
metadata for some layers in multi-platform builds.

By default the script pushes to
`ghcr.io/<your-gh-user>/odp-platform-qemu-arm-virt-devcontainer:cache`. You can
override this by passing an image name:

```bash
./scripts/push-devcontainer-cache.sh ghcr.io/myorg/my-image
```

### Cache lookup order

Both CI and `Common.mk` try multiple cache sources in order:

1. `ghcr.io/dymk/odp-platform-qemu-arm-virt-devcontainer:cache`
2. `ghcr.io/dymk/odp-platform-qemu-arm-virt-devcontainer:latest`
3. `ghcr.io/opendevicepartnership/odp-platform-qemu-arm-virt/devcontainer:cache`
4. `ghcr.io/opendevicepartnership/odp-platform-qemu-arm-virt/devcontainer:latest`

This means PRs from forks can benefit from the upstream org cache, and
contributors can push their own cache to speed up their PRs.

## Pinned external images

The Dockerfile copies QEMU binaries from a builder image. This image is pinned
by SHA digest (not `:latest`) to ensure deterministic builds:

```dockerfile
COPY --from=ghcr.io/dymk/qemu-builder@sha256:f82a910a... /usr/local/bin/qemu-system-aarch64 ...
```

To update the pinned digest, pull the new image and grab its digest:

```bash
docker pull ghcr.io/dymk/qemu-builder:latest
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/dymk/qemu-builder:latest
```

Then update the `COPY --from=` lines in `.devcontainer/Dockerfile`.
