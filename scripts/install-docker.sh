#!/usr/bin/env bash
#
# Installs Docker if it is not already here, then makes sure it is usable.
#
# Referenced by `make docker`, and safe to run on its own. Idempotent: on a
# machine that already has a working Docker it checks a few things, says so, and
# exits without touching anything.
#
# **This script asks for sudo, and it should.** Installing a system daemon is
# not something to do silently from a helper script. What it will not do is
# install anything *else*, or change a setting beyond the two it names below.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
say()  { printf '%b\n' "${GREEN}==>${RESET} $*"; }
warn() { printf '%b\n' "${YELLOW}warning:${RESET} $*" >&2; }
die()  { printf '%b\n' "${RED}error:${RESET} $*" >&2; exit 1; }

# --- what kind of machine is this? ----------------------------------------- #

uname_s="$(uname -s)"
case "$uname_s" in
  Linux) ;;
  Darwin)
    # Docker Desktop is the supported path on macOS and cannot be installed by
    # a script; it needs a licence click and a privileged helper.
    if command -v docker >/dev/null 2>&1; then
      say "Docker is already installed on macOS. Nothing to do."
      exit 0
    fi
    die "On macOS, install Docker Desktop from https://docker.com/products/docker-desktop and run this again."
    ;;
  *)
    die "Unsupported platform '$uname_s'. Install Docker manually, then run 'make up'."
    ;;
esac

# --- is docker already usable? --------------------------------------------- #

# `docker info` rather than `docker --version`: the CLI being on PATH says
# nothing about whether the daemon is running or whether this user may talk to
# it, and those are the two things that actually break `make up`.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  say "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') is installed and the daemon is reachable."

  if ! docker compose version >/dev/null 2>&1; then
    warn "The Docker Compose plugin is missing. On Debian/Ubuntu: sudo apt install docker-compose-plugin"
    exit 1
  fi

  say "Compose $(docker compose version --short) is available. Nothing to install."
  exit 0
fi

# --- not usable. install, or explain why it is not. ------------------------ #

if command -v docker >/dev/null 2>&1; then
  # Installed but not reachable — by far the most common state, and almost
  # always a permissions problem rather than a broken install. Installing again
  # would not help, so say what the actual fix is.
  warn "Docker is installed but this user cannot reach the daemon."
  warn "That is usually the docker group, which needs a fresh login to take effect:"
  warn "    sudo usermod -aG docker $USER   # then log out and back in"
  warn "Or run everything through sudo:   sudo make up"
  exit 1
fi

say "Docker is not installed. Installing it now."
say "This uses Docker's official convenience script from https://get.docker.com."
printf '%b' "${YELLOW}Continue? [y/N] ${RESET}"
read -r reply
case "$reply" in
  [yY]|[yY][eE][sS]) ;;
  *) die "Cancelled. Install Docker yourself, then run 'make up'." ;;
esac

# Downloaded to a file rather than piped straight into a shell. `curl | sh` runs
# whatever the network returns before anyone has seen it; this at least leaves
# the script on disk to be read first, and the checksum is GitHub's problem
# rather than ours either way — the point is that it is inspectable.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL https://get.docker.com -o "$tmp/get-docker.sh" \
  || die "Could not download the installer. Check your network."
say "Downloaded to $tmp/get-docker.sh — read it if you like; it is about to run."

sudo sh "$tmp/get-docker.sh"

# The daemon, not just the client.
sudo systemctl enable --now docker 2>/dev/null || true

# So the next login can run docker without sudo. The current shell cannot — a
# group change only applies to new sessions — which is why the message below
# says to re-run rather than claiming success.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  say "Adding $USER to the docker group."
  sudo usermod -aG docker "$USER"
fi

say "Docker installed."
warn "The docker group applies to new sessions only, so this shell still cannot use it."
warn "Either log out and back in, or run 'newgrp docker' in this terminal."
say  "Then run: make up"
