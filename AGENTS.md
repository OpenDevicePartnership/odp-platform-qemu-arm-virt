# Agent Instructions

## Submodule Workflow

This repo uses git submodules (see `.gitmodules`). CI checks out submodules
recursively, so any commit referenced by a submodule must be publicly
accessible on GitHub. The upstream org repos
(`OpenDevicePartnership/<repo>`) only allow merges via PR, so during
development you must push submodule branches to a **public fork** (or other
fork accessible to CI) and temporarily point `.gitmodules` at that fork.

### Making changes in a submodule

1. **Enter the submodule** and create a branch:

   ```sh
   cd secure-services/odp-secure-services   # or bios/patina-qemu
   git checkout -b <branch-name>
   ```

2. **Make commits** on that branch as normal.

3. **Add a fork remote** (if it doesn't already exist). The fork owner
   should match the developer's GitHub username:

   ```sh
   # Check existing remotes
   git remote -v

   # Add fork if missing (use the developer's GitHub username)
   git remote add fork https://github.com/<username>/<repo>.git
   ```

4. **Push the branch to the fork**:

   ```sh
   git push fork <branch-name>
   ```

5. **Go back to the parent repo** and update `.gitmodules` to point at the
   fork so CI can fetch the commit:

   ```sh
   cd /path/to/odp-platform-qemu-arm-virt

   # Edit .gitmodules — change the url for the submodule
   # From: https://github.com/OpenDevicePartnership/<repo>.git
   # To:   https://github.com/<username>/<repo>.git

   git submodule sync
   ```

   Also add a comment above the changed URL in `.gitmodules` as a
   reminder that it must be restored before the PR can merge:

   ```ini
   [submodule "secure-services/odp-secure-services"]
           path = secure-services/odp-secure-services
           # TODO: restore to OpenDevicePartnership URL before merging
           url = https://github.com/<username>/odp-secure-services.git
   ```

6. **Stage both the submodule ref and `.gitmodules`** change in the parent
   repo:

   ```sh
   git add .gitmodules secure-services/odp-secure-services
   git commit  # or amend into the appropriate commit
   ```

7. **Open a PR** against the upstream submodule repo
   (`OpenDevicePartnership/<repo>`) from the fork branch.

### After the upstream submodule PR merges

Once the submodule PR is merged into the upstream repo's default branch:

1. Enter the submodule, fetch upstream, and point to the merged commit:

   ```sh
   cd secure-services/odp-secure-services
   git fetch origin
   git checkout origin/main   # or the specific merged commit
   ```

2. Switch `.gitmodules` back to the upstream URL:

   ```sh
   cd /path/to/odp-platform-qemu-arm-virt
   # Restore: https://github.com/OpenDevicePartnership/<repo>.git
   git submodule sync
   git add .gitmodules secure-services/odp-secure-services
   git commit  # or amend
   ```

### Tips

- Always run `git submodule sync` after editing `.gitmodules` so the local
  `.git/config` picks up the new URL.
- Use `git submodule status` to verify which commit each submodule is
  pinned to.
- When amending submodule changes into earlier commits via interactive
  rebase, watch for conflicts in `.gitmodules` or `Cargo.toml` files that
  reference path dependencies within the submodule.

### CI merge guard

The `check-submodules.yml` workflow verifies that every URL in
`.gitmodules` belongs to `https://github.com/OpenDevicePartnership/`. PRs
that still point to a personal fork will show a failing check and cannot
be merged until the URLs are restored to the official org.
