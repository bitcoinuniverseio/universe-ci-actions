#!/usr/bin/env bash
# Turns the toolchain image into an ephemeral GitHub Actions runner host.
#
# The VM boots, obtains a one-time JIT configuration from the Universe control
# plane using its own GCE identity, runs exactly one job, reports back, and
# powers off. Nothing here is a credential: the JIT configuration is fetched
# at boot and never written to persistent disk.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${RUNNER_VERSION:?RUNNER_VERSION is required}"
: "${PLAYWRIGHT_VERSION:?PLAYWRIGHT_VERSION is required}"

# Runner user. Passwordless sudo is deliberate: the VM is single tenant and
# lives for one job, so there is no second workload to protect from it.
if ! id runner >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups docker,sudo runner
fi
echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-runner
chmod 0440 /etc/sudoers.d/90-runner

# GitHub Actions runner, pinned. Baked so no VM spends its first minute
# downloading it.
install -d -o runner -g runner /opt/actions-runner
RUNNER_TGZ="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
curl -fsSL -o "/tmp/${RUNNER_TGZ}" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TGZ}"
tar -xzf "/tmp/${RUNNER_TGZ}" -C /opt/actions-runner
rm -f "/tmp/${RUNNER_TGZ}"
/opt/actions-runner/bin/installdependencies.sh
chown -R runner:runner /opt/actions-runner
# The runner prepends this file to every job PATH, the way GitHub-hosted
# images expose ~/.local/bin (pip --user, poetry) and the shared cargo bin.
echo "/home/runner/.local/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > /opt/actions-runner/.path
chown runner:runner /opt/actions-runner/.path
# The runner reads this into every job environment.
echo "${RUNNER_VERSION}" > /opt/actions-runner/.universe-runner-version

# Playwright browsers, pinned to the version the organization's packages
# declare. --with-deps installs every required Linux library while the image
# is built. PLAYWRIGHT_BROWSERS_PATH is set system wide so jobs using this
# version find Chromium, Firefox, and WebKit without downloading anything.
install -d -m 0755 /ms-playwright
export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium firefox webkit
# The runner user owns the browser tree: Playwright takes a directory lock
# under it even when the browser is already present, and a read-only tree
# makes that lock wait for minutes and then fail.
chown -R runner:runner /ms-playwright
chmod -R a+rX /ms-playwright
sed -i -E '/^PLAYWRIGHT_BROWSERS_PATH=/d' /etc/environment
echo 'PLAYWRIGHT_BROWSERS_PATH=/ms-playwright' >> /etc/environment
echo "${PLAYWRIGHT_VERSION}" > /ms-playwright/.universe-playwright-version
rm -rf /root/.npm /root/.cache

# PowerShell 7: many organization workflows declare shell: pwsh.
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
apt-get update
apt-get install -y --no-install-recommends powershell
apt-get clean
rm -rf /var/lib/apt/lists/*

# The runner user owns the shared Rust toolchain: workflows run rustup and
# cargo as that user, and a root-owned RUSTUP_HOME refuses to install a
# target or a component.
chown -R runner:runner /usr/local/rustup /usr/local/cargo

# Cloud Logging and Monitoring agent. Runner diagnostics, the bootstrap log
# and the journal survive the VM, which is deleted the moment the job ends.
curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
  | bash -s -- --also-install
install -m 0644 /tmp/ops-agent.yaml /etc/google-cloud-ops-agent/config.yaml

# Boot service and bootstrap script.
install -d -m 0755 /opt/universe-runner
install -m 0755 /tmp/runner-bootstrap.sh /opt/universe-runner/bootstrap.sh
install -m 0644 /tmp/universe-runner.service /etc/systemd/system/universe-runner.service
systemctl enable universe-runner.service
systemctl enable google-cloud-ops-agent

# Docker: the daemon starts at boot; BuildKit is the default builder. Docker
# Hub pulls go through Google's public mirror, because every runner leaves
# through a handful of Cloud NAT addresses and anonymous Docker Hub limits are
# counted per address.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "features": { "buildkit": true },
  "registry-mirrors": ["https://mirror.gcr.io"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "2" }
}
EOF

# Kernel and filesystem settings that CI workloads hit: inotify watchers for
# bundlers and test watchers, more open files for parallel test runners.
cat > /etc/sysctl.d/90-universe-ci.conf <<'EOF'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
vm.swappiness = 10
EOF
cat > /etc/security/limits.d/90-universe-ci.conf <<'EOF'
runner soft nofile 1048576
runner hard nofile 1048576
runner soft nproc 65536
runner hard nproc 65536
EOF

# Leave no SSH host keys or machine id behind: each boot generates fresh ones.
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
