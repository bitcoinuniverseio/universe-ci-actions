# Universe CI actions

Shared GitHub Actions for every Universe repository. This repository is public
so that public and private repositories can both consume it; an action stored in
a private repository cannot be resolved from a public one.

Nothing here holds a secret, a credential, an account identifier or any
infrastructure address.

## Two rules every consuming workflow must follow

**1. No GitHub-hosted runners.** Never write `ubuntu-latest`, `windows-latest`,
`macos-latest`, or any other GitHub-hosted label in a `runs-on`, in any
repository of this organization, public or private. Every job targets the
self-hosted fleet by label, or the RunsOn plus AWS configuration. A job on a
GitHub-hosted runner has none of the warm tool cache, the shared dependency
store or the shared build store these actions depend on.

**2. The toolchain is pinned.** Node.js **24.19.0**, npm **11.17.0**, everywhere
they apply: local, servers, CI, containers. Container work additionally pins
Docker Engine **29.7.2**.

Both rules are violated often enough to be worth restating in every review.
[docs/runners.md](docs/runners.md) explains how to choose a label, and what to do
when the queue is backlogged.

## Quick start

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux-ultra]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: bitcoinuniverseio/universe-ci-actions/universe-node-env@8e24bc760556caa5ec8c7c497baaad2e9adcc912 # v1
      - run: npm run lint:check
      - run: npm run build
      - run: npm test
```

Pin by full commit SHA. See [docs/pinning.md](docs/pinning.md).

## The actions

| Action | Does | Reference |
| --- | --- | --- |
| `universe-node-env` | Resolves the pinned Node.js and npm from the runner's tool cache and reuses an exact, content-addressed dependency tree. Nothing is downloaded or installed on a warm runner. | [docs/universe-node-env.md](docs/universe-node-env.md) |
| `universe-build-store` | Saves a build output once and restores it everywhere else, keyed by commit plus toolchain plus machine shape. Nothing is uploaded or metered. | [docs/universe-build-store.md](docs/universe-build-store.md) |
| `universe-docker-env` | Ensures the runner has the pinned Docker Engine 29.7.2. | [docs/container-builds.md](docs/container-builds.md#universe-docker-env) |
| `portable-container-build` | Builds a Linux image and optionally runs a smoke command inside it before cleanup. | [docs/container-builds.md](docs/container-builds.md#portable-container-build) |
| `portable-mysql-fixture` | Starts an isolated MySQL container for one job and removes it afterwards. | [docs/database-fixtures.md](docs/database-fixtures.md) |
| `portable-postgres-fixture` | The same for PostgreSQL. | [docs/database-fixtures.md](docs/database-fixtures.md) |
| `portable-node-ci` | The whole Node build and test contract in one step, under PowerShell. Slower than `universe-node-env`; use that instead on the Linux fleet. | [docs/portable-node-ci.md](docs/portable-node-ci.md) |

Also here: two fleet diagnostic workflows, documented in
[docs/fleet-workflows.md](docs/fleet-workflows.md).

## Why `universe-node-env` exists

It replaces all three of these:

```yaml
- uses: actions/setup-node@...
  with:
    node-version-file: .nvmrc
    cache: npm                       # downloads a large npm store every job
- run: npm install --global npm@X    # reinstalls the version already present
- run: npm ci                        # reinstalls an unchanged dependency tree
```

Measured on `backend-apis` run 33329978544: those three steps cost 282 seconds
per job and changed nothing. Node was already in the runner's tool cache and
resolved in 0.4 seconds.

## Why these actions live here

`portable-container-build`, `portable-node-ci`, `portable-mysql-fixture` and
`portable-postgres-fixture` moved here from a private repository on 2026-08-31.
They were unreachable from public repositories: `index-patina` is public and
referenced them at their old private location, which a public repository cannot
resolve.

This repository is the single home for them. Do not copy them back into a private
repository, or public consumers break again.

The fleet diagnostics are here for a related reason: while the account is
billing-locked, private repositories cannot start a workflow at all, so a fleet
diagnostic kept there is unavailable exactly when it is needed.

## Documentation

| Page | Covers |
| --- | --- |
| [docs/runners.md](docs/runners.md) | Runner selection, what each label actually matches, and what helps when the queue is backlogged |
| [docs/pinning.md](docs/pinning.md) | How to reference these actions, what `v1` means, how to upgrade a pin |
| [docs/universe-node-env.md](docs/universe-node-env.md) | Full contract: inputs, outputs, the dependency key, storage, log lines |
| [docs/universe-build-store.md](docs/universe-build-store.md) | Full contract, including why a restore miss fails the step |
| [docs/container-builds.md](docs/container-builds.md) | `universe-docker-env` and `portable-container-build` |
| [docs/database-fixtures.md](docs/database-fixtures.md) | The MySQL and PostgreSQL fixtures |
| [docs/portable-node-ci.md](docs/portable-node-ci.md) | The one-step PowerShell contract, and when to prefer it |
| [docs/fleet-workflows.md](docs/fleet-workflows.md) | Toolchain audit and disk reclaim |

Also: [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[SUPPORT.md](SUPPORT.md).

## Licence

This repository carries no licence file today. It is published so that
`bitcoinuniverseio` repositories, public and private, can resolve these actions;
it is not offered as a general purpose action library. Adding an explicit licence
is an open item for the repository owners.
