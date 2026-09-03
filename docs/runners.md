# Runner selection

## The rule

**GitHub-hosted runner labels are prohibited.** Never write `ubuntu-latest`,
`windows-latest`, `macos-latest`, or any other GitHub-hosted label in a
`runs-on`, in any repository of this organization, public or private. Those
labels route the job to GitHub's own runners and bypass the fleet entirely.

Every job must target either:

- the self-hosted fleet, by label, or
- the RunsOn plus AWS configuration.

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
requests. That is worth reading twice, because it is the source of most bad
routing in this organization: a broad label matches more machines than the
author expected.

Verified against the organization's registered runners on 2026-09-01:

| Label you request | Runners it can match |
| --- | --- |
| `universe-linux-ultra` | 6, the primary ultra pool and nothing else |
| `linux-ultra` | 11, the ultra pool plus five older runners |
| `linux-container-builder` | 7, the ultra pool plus one older runner |
| `docker-29-7-2`, `docker-ci` | 7, the same set as `linux-container-builder` |
| `ultra`, `universe-ci` | 14, every Linux runner in the fleet |

Practical guidance:

- **Default for a source job:** `runs-on: [self-hosted, linux-ultra]`.
- **When the job needs Docker** (a container build, a database fixture):
  `runs-on: [self-hosted, linux-ultra, linux-container-builder]`. The
  `portable-*` fixtures and `portable-container-build` all require Docker 29.7.2
  and refuse anything else.
- **When you want the primary pool and only the primary pool:** request
  `universe-linux-ultra`. This is the narrowest label and it is the only one
  that excludes every older runner.
- **Avoid `ultra` and `universe-ci` as your only qualifier.** They match every
  Linux runner including the ones being drained.

### The `runner-drained` label

Eight runners currently carry a `runner-drained` label. It is a marker for
operators, not a scheduling control: GitHub routes on the labels a job asks for,
so a drained runner still picks up any job whose requested labels it happens to
carry. Five of the eight also carry `linux-ultra`.

If you need to keep work off them, request a label they do not have
(`universe-linux-ultra`), rather than assuming the marker does it for you.

## When the queue is backlogged

This is a real and recurring condition, not a hypothetical. On 2026-09-01,
across several repositories, jobs sat queued for a long stretch while all six
ultra runners were busy and eight further runners were marked drained.

What actually helps, in order:

1. **Ask for the narrowest correct label set, not the broadest.** A job that
   requests `linux-container-builder` when it never touches Docker is competing
   for seven machines instead of eleven.
2. **Do not duplicate work between jobs.** Use
   [`universe-build-store`](../universe-build-store) to build once and restore
   everywhere else, and `universe-node-env` so no job reinstalls an unchanged
   dependency tree. A backlog is made of jobs, and the cheapest job is the one
   that finishes in seconds.
3. **Cancel superseded runs.** Every workflow should set a `concurrency` group
   with `cancel-in-progress: true` on the ref, so a push does not leave its own
   predecessor occupying a runner. Both workflows in this repository do.
4. **Let RunsOn absorb the overflow where the workload suits it.** RunsOn
   instances are ephemeral, so they have no local dependency or build store;
   `universe-node-env` detects that and uses the account's own S3-backed Actions
   cache instead, automatically. The tradeoff is a cold-ish start in exchange for
   not queueing. RunsOn capacity is spot only; there is no on-demand fallback,
   so a job can still queue when spot capacity is short.
5. **Do not block a documentation or configuration merge on a green run you
   cannot get.** Run the repository's own gate locally, say in the pull request
   exactly what you ran and what it reported, and merge on that evidence. Several
   merges on 2026-09-01 were verified this way.

What does not help: adding a GitHub-hosted runner label to get around the
queue. That is prohibited, and it silently produces a job with none of the warm
caches these actions rely on.

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
