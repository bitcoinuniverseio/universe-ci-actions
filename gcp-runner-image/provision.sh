#!/usr/bin/env bash
# Bakes every toolchain CI uses. Nothing here may run at job time.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg git jq unzip zip xz-utils \
  build-essential cmake pkg-config libssl-dev

# GitHub CLI. Used by the router and by release workflows.
mkdir -p /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

# Docker Engine, pinned. The docker runner class is local-only today precisely
# because the cloud image shipped a different engine and failed the version
# gate before building anything. Baking the pinned engine is what lets that
# class take Spot overflow.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y --no-install-recommends gh
DOCKER_APT="5:${DOCKER_VERSION}-1~ubuntu.24.04~noble"
apt-get install -y --no-install-recommends \
  "docker-ce=${DOCKER_APT}" "docker-ce-cli=${DOCKER_APT}" \
  containerd.io docker-buildx-plugin docker-compose-plugin
apt-mark hold docker-ce docker-ce-cli

# Node, pinned, plus corepack for pnpm and yarn without a job-time download.
NODE_TGZ="node-v${NODE_VERSION}-linux-x64.tar.xz"
curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TGZ}"
tar -xJf "${NODE_TGZ}" -C /usr/local --strip-components=1
rm -f "${NODE_TGZ}"
npm install -g "npm@${NPM_VERSION}"
corepack enable
corepack prepare pnpm@latest --activate
corepack prepare yarn@stable --activate

# Deno. Sixteen workflows call setup-deno, so it belongs in the image.
curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s -- --yes

# Python and uv.
apt-get install -y --no-install-recommends \
  "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" python3-pip
curl -fsSL https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

# Rust, pinned, system wide so every user sees the same toolchain.
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
curl -fsSL https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --default-toolchain "${RUST_VERSION}" \
      --component clippy rustfmt --profile minimal
chmod -R a+rx /usr/local/cargo/bin
printf 'export RUSTUP_HOME=/usr/local/rustup\nexport CARGO_HOME=/usr/local/cargo\nexport PATH=$PATH:/usr/local/cargo/bin\n' \
  > /etc/profile.d/rust.sh

# Keep boot minimal. Nothing below earns its start-up cost on an ephemeral
# runner that lives for the length of one job.
systemctl disable --now snapd.service snapd.socket apt-daily.timer \
  apt-daily-upgrade.timer unattended-upgrades.service man-db.timer 2>/dev/null || true
systemctl enable docker

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
