# coalton-mine-podman

A `Containerfile` that builds and runs [**mine**](https://github.com/coalton-lang/coalton/tree/main/mine) — the TUI-based IDE for Coalton and Common Lisp that lives in the [coalton-lang/coalton](https://github.com/coalton-lang/coalton) repository under `mine/`.

The image builds a modern SBCL from source (`--fancy --with-sb-core-compression`, so the `sb-perf` contrib and zstd core compression that mine's executable builder needs are available), installs Quicklisp, clones Coalton, and dumps the standalone `mine` executable as the entrypoint via the project's own build recipe (`ql:quickload "mine"` → `mine/app/executable:build`).

## Requirements

- [Podman](https://podman.io/) (tested with 5.x). Docker should also work — substitute `docker` for `podman` and `--build-arg`/`-f Containerfile` as usual.

## Build

```sh
podman build -t coalton-mine .
```

The build compiles SBCL and all of Coalton from source, so expect it to take roughly 10–15 minutes and to download Quicklisp dependencies.

### Build args

Both versions to clone are parameterized with `--build-arg`. Each value is a **git tag or branch**.

| Build arg         | Default  | What it pins                                                                 | Example values                         |
| ----------------- | -------- | ---------------------------------------------------------------------------- | -------------------------------------- |
| `SBCL_VERSION`    | `master` | The SBCL git ref to clone and build (cloned from `github.com/sbcl/sbcl`).     | `sbcl-2.5.11`, `sbcl-2.6.5`, `master`  |
| `COALTON_VERSION` | `main`   | The Coalton/mine git ref to clone (cloned from `github.com/coalton-lang/coalton`). | `main`, `mine-v0.1.6`             |

Example — pin both to specific releases:

```sh
podman build -t coalton-mine \
    --build-arg SBCL_VERSION=sbcl-2.5.11 \
    --build-arg COALTON_VERSION=main \
    .
```

Notes:

- The clone is shallow (`git clone --depth 1 --branch <ref>`), so `<ref>` must be a branch name or a tag — not an arbitrary commit SHA.
- When `SBCL_VERSION` is a **tag**, SBCL's `make.sh` derives its version via `git describe`. When it's a plain **branch** (no tags in the shallow history), the build writes a synthetic `version.lisp-expr` so `make.sh` doesn't abort.
- Changing a build arg invalidates the build cache from the affected step onward.

## Run

`mine` is a full-screen TUI, so it needs an interactive terminal (`-it`):

```sh
podman run --rm -it coalton-mine
```

On first run, open **F6:Site → Setup Wizard** to configure. Quit with **Ctrl+q**.

### Terminal requirements

`mine` requires a terminal that supports the **kitty keyboard protocol** (e.g. Ghostty, kitty ≥ 0.21, WezTerm, Alacritty ≥ 0.14) with true-color and a Unicode font, and `Alt` usable as a modifier. On an unsupported terminal it prints a suggestions list and exits. To bypass that check (some features may not work):

```sh
podman run --rm -it coalton-mine --best-effort
```

Any trailing arguments after the image name are passed straight to the `mine` binary (e.g. `--best-effort`, `--setup`).

### Editing host files

To edit files from your machine inside `mine`, bind-mount a directory **and** add
`--userns=keep-id`. With rootless podman a plain `-v` mount makes your files show up
under an unmapped UID (effectively read-only); `--userns=keep-id` maps your host user
to the container's `coalton` user (uid 1000) so the mount is read-write and files you
create are owned by you on the host:

```sh
podman run --rm -it --userns=keep-id \
    -v "$PWD:/home/dev" \
    localhost/coalton-mine
```

Inside the IDE, use **Ctrl+o** to open files under `/home/dev`. Don't mount over
`/home/coalton` — that would shadow the `mine` binary and Quicklisp and break the
container; `mine` keeps its own config and cache there.

A convenient zsh function (mount the given dir, defaulting to the current one):

```zsh
# Usage: mine [dir] [mine-args...]
#   mine ~/projects/foo     # open that dir
#   mine . --best-effort    # current dir, skip the kitty-keyboard check
mine() {
  podman run --rm -it --userns=keep-id \
    -v "${1:-$PWD}:/home/dev" \
    localhost/coalton-mine "${@:2}"
}
```

To persist `mine`'s own config across `--rm` runs, also bind a host file onto
`~/.mine`, e.g. `-v "$HOME/.config/mine/dotmine:/home/coalton/.mine"`, and set
`:project-roots "/home/dev"` in it so mounted folders auto-populate the project tree.

## License

The `mine` IDE and Coalton are MIT-licensed by the Coalton contributors. This repository only contains packaging (the `Containerfile`).
