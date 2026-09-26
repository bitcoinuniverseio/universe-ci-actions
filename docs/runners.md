# Runner selection

## The rule

**GitHub-hosted runner labels are prohibited.** Never write `ubuntu-latest`,
`windows-latest`, `macos-latest`, or any other GitHub-hosted label in a
`runs-on`, in any repository of this organization, public or private. Those
labels route the job to GitHub's own runners and bypass the fleet entirely.

Every job targets the self-hosted fleet by label. The GCP (`gcp`,
`universe-gcp-*`), WarpBuild and RunsOn platforms are decommissioned; king's
selector lint rejects them, and a job that requests them queues until GitHub
expires it.

This applies to public repositories too. It is not a cost preference; it is how
the organization's CI is built, and a job on a GitHub-hosted runner has none of
the warm tool cache, the shared dependency store or the shared build store the
actions in this repository depend on.

## Pinned toolchain

Every workflow and every runner image uses the same pinned toolchain:

| Tool | Version |
| --- | --- |
| Node.js | 24.19.0 |
| npm | 11.17.0 |

`universe-node-env` reads the pin from your repository (`.nvmrc`, then
`engines.node` in `package.json`, then the organization default 24.19.0) and
resolves it from the runner's Actions tool cache without downloading anything.
It also checks npm against `engines.npm` and repairs a mismatched tool cache
copy once, with a warning annotation, rather than letting every job pay for it.

Pin these versions everywhere they apply: local development, servers, CI,
containers.

## Choosing a label

A job is scheduled onto any runner that carries **all** the labels the job
requests, and only if the runner's group admits the job's repository.

Live fleet, verified 2026-09-26 (online services):

| Pool | Services | Runner group | Repositories admitted |
| --- | --- | --- | --- |
| PrimCast super, primary | 48 enabled of `universe-linux-super-01` to `-192` | `Universe-Primcast-Primary` | all |
| PowerVPS ultra, secondary | `universe-linux-ultra-01` to `-64` | `Universe-PowerVPS-Secondary` | index-zcash-metaprotocols, inscribe, king, mempool, zerdinals-and-zrunes |

| Label you request | Services it matches |
| --- | --- |
| `universe-super`, `primcast` | 48, PrimCast only |
| `universe-linux-ultra`, `linux-ultra`, `ultra` | 64, ultra only (admitted repositories only) |
| `universe-ci`, `universe-linux`, `docker-ci`, `docker-29-7-2`, `linux-container-builder`, `playwright-chromium`, `browser-heavy` | 112, both pools |

Practical guidance:

- **Default for any job:** `runs-on: [self-hosted, linux, x64, universe-super]`.
  PrimCast is the primary fleet; use it first.
- **When the job needs Docker or Playwright:** the same selector works; every
  PrimCast service carries Docker 29.7.2 and Playwright Chromium. The
  `portable-*` fixtures and `portable-container-build` refuse any other Docker
  version.
- **Service containers must publish ephemeral host ports.** Every PrimCast
  service shares one Docker daemon, so a fixed mapping such as `3306:3306`
  fails the second concurrent job with "port is already allocated". Publish only
  the container port (`- 3306`) and read the host port from
  `job.services.<name>.ports['3306']` in a step.
- **Ultra only from an admitted repository.** Requesting an ultra label from any
  other repository never schedules.
- **Avoid `universe-ci` as your only qualifier** unless the job genuinely runs
  on either pool.

## When the queue is backlogged

This is a real and recurring condition, not a hypothetical. PrimCast runs 48
services; with all 192 enabled the host logged OOM kills, and at 48 its disk is
already the bottleneck, so the cap is deliberate.

What actually helps, in order:

1. **Ask for the narrowest correct label set.** A job that requests a label only
   one pool carries competes for fewer machines than it could.
2. **Do not duplicate work between jobs.** Use
   [`universe-build-store`](../universe-build-store) to build once and restore
   everywhere else, and `universe-node-env` so no job reinstalls an unchanged
   dependency tree. A backlog is made of jobs, and the cheapest job is the one
   that finishes in seconds.
3. **Cancel superseded runs.** Every workflow should set a `concurrency` group
   with `cancel-in-progress: true` on the ref, so a push does not leave its own
   predecessor occupying a runner. Both workflows in this repository do.
4. **Do not block a documentation or configuration merge on a green run you
   cannot get.** Run the repository's own gate locally, say in the pull request
   exactly what you ran and what it reported, and merge on that evidence.

What does not help: adding a GitHub-hosted or decommissioned runner label to get
around the queue. Both are prohibited, and the decommissioned ones never run.

## How the actions detect the runner class

`universe-node-env` decides where an exact dependency tree should live by
detecting whether the runner keeps its filesystem between jobs:

| Signal | Meaning |
| --- | --- |
| `RUNNER_NAME` starts with `runs-on` | ephemeral |
| `RUNNER_ENVIRONMENT` is `github-hosted` | ephemeral |
| `RUNS_ON_RUNNER_NAME` or `RUNS_ON_S3_BUCKET_CACHE` is set | ephemeral |
| none of the above | persistent |

On a persistent runner it writes and reads a content-addressed archive under a
store on local disk, shared by every runner service on that host, so nothing is
uploaded, downloaded or metered. On an ephemeral runner it falls back to
`actions/cache`. If the store directory is not writable it emits a warning and
falls back to the remote cache rather than failing the job.

The same detection is why you do not need to configure anything per runner
class: write one workflow, and it does the right thing on both.
