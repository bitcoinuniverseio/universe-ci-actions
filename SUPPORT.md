# Support

Issues are disabled on this repository. Raise a problem as a pull request here
with the fix, or in the repository whose workflow is failing, quoting the run URL
and the relevant log lines.

Before you do, check the symptom below. Most reports are one of these.

## Troubleshooting by symptom

### The job never starts, it just sits queued

The runner queue is backlogged, or your `runs-on` labels match no runner that is
free. [docs/runners.md](docs/runners.md) lists what each label actually matches
and what helps. The short version: request the narrowest correct label set, make
sure `concurrency` cancels superseded runs, and do not add a GitHub-hosted label
to escape the queue.

### "No space left on device" in "Set up job"

A full runner disk, before any step of yours ran. Run the fleet disk reclaim
workflow, report first, then apply. See
[docs/fleet-workflows.md](docs/fleet-workflows.md).

### `TOOLCHAIN MISS` in the log

The pinned Node.js is not in that runner's tool cache. `universe-node-env`
repairs the one job so your branch is still validated, and annotates it as a
runner image defect. Run the fleet toolchain audit to see which runners are
affected, and fix the image so no other job pays the cost.

### `NPM MISS` in the log

The tool cache carries a different npm than your `engines.npm`. Repaired once,
with a warning. Same fix: repair the runner image.

### `DEPENDENCY MISS` on every run, even when nothing changed

The dependency key is moving. Compare the printed key between two runs; the field
that differs names the cause. Common ones: a `package.json` that a generator
rewrites on every run, `npm-install-args` set from an expression that varies, or
jobs running on runners with different architectures or libc.

The key composition is documented in
[docs/universe-node-env.md](docs/universe-node-env.md#how-the-dependency-key-is-built).

### `Dependency store ... is not writable`

A warning, not a failure. The action falls back to `actions/cache`. It means that
runner's shared store directory has the wrong ownership or permissions.

### A `universe-build-store` restore step fails the job

Expected on a miss. `mode: restore` exits non-zero when the archive is not there,
so a later step cannot silently consume an empty directory. Set
`continue-on-error: true` on the restore step and branch on
`steps.<id>.outputs.state`. Example in
[docs/universe-build-store.md](docs/universe-build-store.md#the-restore-step-fails-on-a-miss).

### "Expected Docker 29.7.2, received ..."

The runner has a different Docker Engine. Add `universe-docker-env` before the
container step, and target a runner carrying `linux-container-builder`.

### "Unsupported runner platform" from a database fixture

Both fixtures are Linux only. So is `portable-container-build`.

### "MySQL image must be pinned by sha256 digest"

The `image` input needs an `@sha256:` digest, not a tag.

### An artifact upload fails

`actions/upload-artifact` is metered against the account's Actions storage quota,
and that quota being full broke uploads across the organization on 2026-08-31.
Use [`universe-build-store`](docs/universe-build-store.md) instead unless the
bytes genuinely have to leave the fleet.

## Security reports

Do not open a pull request describing a vulnerability. Follow
[SECURITY.md](SECURITY.md).
