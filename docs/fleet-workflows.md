# Fleet diagnostics

Two `workflow_dispatch` workflows in this repository act on the runner fleet
rather than on this repository's own code. Both run one job per host, selected
by the host label (`primcast`). Every service on a host shares its tool cache,
dependency store, build store and disk, so one job reports the whole host.

The PowerVPS ultra services (`universe-linux-ultra-01` to `-64`) are not
reachable from here: their runner group, `Universe-PowerVPS-Secondary`, admits
only index-zcash-metaprotocols, inscribe, king, mempool and zerdinals-and-zrunes.
A job in this repository that names an ultra runner stays queued until GitHub
expires it. Ultra host diagnostics and certification run from king
(`runner-host-diagnostics.yml`, `runner-certification.yml`).

They live here, in a public repository, on purpose: while the account is
billing-locked, private repositories cannot start a workflow at all, so a fleet
diagnostic kept there is unavailable exactly when it is needed.

## Fleet toolchain audit

`.github/workflows/fleet-toolchain-audit.yml`

Reports, for each host:

- whether the pinned Node.js 24.19.0 is in that runner's Actions tool cache,
  which version it reports, and whether the tool cache entry is marked complete
- which npm that tool cache copy carries
- the size of the shared dependency store and the shared build store
- architecture, core count, memory and free space

Run it after any runner provisioning change. A runner reporting
`NODE_IN_TOOL_CACHE=NO` is the reason jobs on it pay for an
`actions/setup-node` download; `universe-node-env` will repair that one job and
annotate it as a runner image defect, but the fix belongs in the image.

## Fleet disk reclaim

`.github/workflows/fleet-disk-reclaim.yml`

A full runner disk fails jobs in "Set up job", before any step runs, with
"No space left on device". The job looks unrelated to the change under test,
which is what makes this worth a dedicated workflow.

| Input | Default | Meaning |
| --- | --- | --- |
| `runners` | `all` | Comma separated host labels (`primcast`), or `all`. |
| `apply` | `false` | Report only by default. Set `true` to delete. |

**Report first.** With `apply=false` it prints disk usage before, and the
largest consumers by directory. Read that before deleting anything.

With `apply=true` it removes, in this order: job workspace `_temp` directories
older than two hours and `_diag` directories older than a day, runner logs older
than three days, Docker images and build cache older than 48 hours, then verifies
the npm cache. Everything it deletes is recreated by the runner or rebuilt on the
next job.

## Running them

From the Actions tab of this repository, or:

```sh
gh workflow run fleet-toolchain-audit.yml -R bitcoinuniverseio/universe-ci-actions
gh workflow run fleet-disk-reclaim.yml -R bitcoinuniverseio/universe-ci-actions \
  -f runners=all -f apply=false
```

Both use `fail-fast: false`, so one unreachable runner does not hide the report
from the others.
