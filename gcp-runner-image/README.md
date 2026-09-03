# GCP runner image

Golden VM image for the Universe ephemeral GitHub Actions runners in GCP
project `universe-507319`, image family `universe-ci-runner`.

Every runner VM boots from this image, exchanges its own GCE identity for a
one-time JIT registration at the Universe control plane, runs exactly one
job, reports back, and is deleted. No CI job spends time on `apt install`,
`install Node`, or downloading a toolchain: everything below is baked in.

## What is in it

Measured from the workflow and action files across the organization, then
pinned to the versions AGENTS.md requires.

| tool | version | why |
|---|---|---|
| Node | 24.19.0 | AGENTS.md pin, used by most workflows |
| npm | 11.17.0 | AGENTS.md pin |
| pnpm, Yarn | via corepack | no job-time download |
| Deno | latest at build | called by setup-deno workflows |
| Rust | 1.89.0 + clippy, rustfmt | workflow pins |
| Python | 3.12 + uv | distro default, exact interpreters via uv |
| Docker | 29.7.2 + buildx, compose | AGENTS.md pin |
| GitHub Actions runner | 2.337.0 | `/opt/actions-runner`, no update download at boot |
| Playwright Chromium | 1.62.1 | `/ms-playwright`, owned by the runner user |
| PowerShell | 7.x | workflows that declare `shell: pwsh` |
| Cloud Ops agent | latest at build | ships runner and bootstrap logs before the VM is deleted |
| Docker Hub mirror | mirror.gcr.io | anonymous Docker Hub limits are per NAT address |
| git, gh, jq, cmake, clang, lld, build-essential, OpenSSL headers | distro | used across the fleet; clang for WASM and native crates |

`runner.sh` adds the `runner` user (passwordless sudo, docker group), the
runner agent, Playwright, the Ops agent, and `universe-runner.service`, whose
`runner-bootstrap.sh` performs the JIT exchange at boot.

## Build

```
node --test verify-source.test.mjs
node verify-source.mjs
packer init .
packer build -var-file=versions.pkrvars.hcl -var git_commit=$(git rev-parse --short HEAD) .
```

Build only from a fresh, clean checkout. Root Git attributes keep every Linux
image input on LF line endings, including on Windows. `verify-source.mjs`
checks the source before Packer starts. `verify.sh` checks the installed boot
script again inside the image and rejects CR bytes or an invalid interpreter.
Together these gates prevent a copied `bash\r` interpreter from reaching a
runner VM.

`verify.sh` also fails the build if any pinned version or runner-host piece
drifts, so a bad image never reaches a runner. The image name hashes every
pinned version and the build commit, so a change produces a new immutable
image rather than mutating one in place. Image labels carry the runner version,
git commit and build date.

The build host is a Spot `c3d-highcpu-8`: an image build is interruptible
work.

## Promote and roll back

The control plane pins the newest READY image in the family when a Cloud Run
revision starts. Promote by rolling a revision (or set `runner_image` in the
Terraform of `bitcoinuniverseio/.github-private` to the new name), dispatch
`gcp-canary.yml`, and keep the previous image in the family for rollback.

Control plane, runner classes and operations live in
`bitcoinuniverseio/.github-private` under `infra/gcp/` and
`docs/gcp-runner-platform.md`.

If new VMs stay in the booting state and their serial console reports a
`bash\r` interpreter, stop the promotion. Create a zero-downtime control-plane
revision that pins the previous READY runner image, wait for 100 percent
traffic on that revision, then prove that a canary job registers and starts.
Keep both images until the source fix is merged and a replacement image passes
the source gate, image verification, and canary.
