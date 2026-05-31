# Containerfile for "mine" — the TUI-based IDE for Coalton and Common Lisp
# that lives in coalton-lang/coalton under mine/.
#
#   Build:  podman build -t coalton-mine .
#   Run:    podman run --rm -it coalton-mine
#
# Pin the SBCL and Coalton versions to clone via build args (each is a git
# tag or branch). Defaults track the upstream tip:
#
#   podman build -t coalton-mine \
#       --build-arg SBCL_VERSION=sbcl-2.5.11 \
#       --build-arg COALTON_VERSION=main \
#       .
#
# mine is a full-screen TUI, so it MUST be run with an interactive terminal
# (`-it`). Mount a host directory if you want your projects/config to persist:
#
#   podman run --rm -it \
#       -v "$PWD/work:/home/coalton/work:Z" \
#       coalton-mine
#
# Notes on terminal: mine targets modern terminals with true-color, a Unicode
# font, and `Alt` usable as a modifier — make sure your host terminal qualifies.

FROM debian:bookworm-slim

# ---- System dependencies --------------------------------------------------
# We need a NEWER SBCL than Debian ships: mine's executable builder dumps a
# *compressed* core (save-lisp-and-die :compression t), which requires an SBCL
# built with zstd core-compression. Debian's sbcl 2.2.9 has neither that nor
# the sb-perf contrib, so we build SBCL from source below (Debian's sbcl is
# only the bootstrap host) and remove the bootstrap afterwards.
#
#   sbcl (bootstrap)  : host Lisp used to compile the new SBCL, then removed
#   build-essential   : C toolchain for SBCL + native Quicklisp deps
#   libzstd-dev       : core compression support (build + runtime libzstd1)
#   zlib1g-dev        : SBCL build dependency
#   git, curl         : fetch SBCL/Coalton sources and Quicklisp
#   ca-certificates   : TLS for https
#   locales           : a UTF-8 locale so the TUI's Unicode/box-drawing renders
#
# Big-float support uses :coalton-portable-bigfloat (set at build time), so
# GNU MPFR is intentionally NOT required.
RUN apt-get update && apt-get install -y --no-install-recommends \
        sbcl \
        build-essential \
        libzstd-dev \
        zlib1g-dev \
        git \
        curl \
        ca-certificates \
        locales \
    && sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TERM=xterm-256color

# ---- Build a modern SBCL with core compression ----------------------------
# Built with --fancy (threads, contribs incl. sb-perf) and
# --with-sb-core-compression (zstd). Installs to /usr/local, which precedes
# /usr/bin on PATH, so `sbcl` resolves to this build. Then drop the Debian
# bootstrap sbcl to avoid confusion.
#
# SBCL_VERSION is the git tag (e.g. sbcl-2.5.11) or branch (e.g. master) to
# build. A shallow clone of a tag lets make.sh derive the version via
# `git describe`; for a plain branch (no tags in shallow history) we fall
# back to a synthetic version.lisp-expr so make.sh doesn't abort.
ARG SBCL_VERSION=master
RUN git clone --depth 1 --branch "${SBCL_VERSION}" https://github.com/sbcl/sbcl.git /tmp/sbcl \
    && cd /tmp/sbcl \
    && { git describe --tags >/dev/null 2>&1 || echo '"2.5.11"' > version.lisp-expr; } \
    && sh make.sh --fancy --with-sb-core-compression \
         --xc-host='sbcl --no-userinit --no-sysinit --disable-debugger' \
    && sh install.sh \
    && cd / \
    && rm -rf /tmp/sbcl \
    && apt-get purge -y sbcl \
    && apt-get autoremove -y \
    && hash -r \
    && sbcl --version

# ---- Non-root user --------------------------------------------------------
RUN useradd -m -s /bin/bash coalton
USER coalton
WORKDIR /home/coalton

# ---- Quicklisp ------------------------------------------------------------
# The mine Makefile loads $HOME/quicklisp/setup.lisp directly, so install
# Quicklisp into the default location it expects.
RUN curl -fsSL https://beta.quicklisp.org/quicklisp.lisp -o /tmp/quicklisp.lisp \
    && sbcl --non-interactive \
            --load /tmp/quicklisp.lisp \
            --eval '(quicklisp-quickstart:install)' \
    && rm -f /tmp/quicklisp.lisp

# ---- Source ---------------------------------------------------------------
# Clone the coalton repo (which contains mine/); it builds from source via the
# repo-local source registry (CL_SOURCE_REGISTRY pointing at the repo root, as
# in the Makefile). COALTON_VERSION is the git tag or branch to clone.
ARG COALTON_VERSION=main
RUN git clone --depth 1 --branch "${COALTON_VERSION}" https://github.com/coalton-lang/coalton.git \
        /home/coalton/coalton

WORKDIR /home/coalton/coalton/mine

# ---- Build mine -----------------------------------------------------------
# This mirrors the Makefile's `mine` recipe (load Quicklisp + coalton-config,
# load the system, then dump the executable via mine/app/executable:build),
# with three deliberate changes:
#
#   * ql:quickload instead of asdf:load-system, so the third-party deps
#     (alexandria, eclector, ...) get downloaded — plain asdf:load-system
#     does not fetch them.
#   * MINE_SAVE_CORE is left UNSET, so build produces a normal standalone
#     `mine` executable (toplevel = mine/app/mine:main) rather than the split
#     runtime+core layout the Makefile uses on Linux only to survive AppImage
#     packaging, which we don't do here.
#
# The executable builder loads SBCL contribs (incl. sb-perf on Linux) and
# dumps a zstd-compressed core — both provided by the SBCL we built above.
#
# Everything happens in a single SBCL process: compile once, then dump.
# The retry loop only guards transient network hiccups during dependency
# downloads.
ENV CL_SOURCE_REGISTRY=/home/coalton/coalton//
RUN for i in 1 2 3 4 5; do \
        sbcl --non-interactive \
             --load /home/coalton/quicklisp/setup.lisp \
             --eval '(pushnew :coalton-portable-bigfloat *features*)' \
             --load coalton-config.lisp \
             --eval '(ql:quickload "mine")' \
             --eval '(mine/app/executable:build)' \
        && break; \
        echo "build attempt $i failed (likely transient network); retrying..."; \
        sleep 5; \
    done; \
    test -x ./mine

# ---- Entrypoint -----------------------------------------------------------
# Launch the mine IDE. On first run, use F6:Site > Setup Wizard (or run with
# `--setup`). Quit with Ctrl+q.
ENTRYPOINT ["/home/coalton/coalton/mine/mine"]
