# `universe-node-env`

Resolves the pinned Node.js and npm from the runner image, then reuses an exact,
content-addressed dependency tree. On a warm runner nothing is downloaded and
nothing is installed.

This is the action most repositories in the organization depend on, including
the documentation platform. Its contract is below in full.

## Usage

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: bitcoinuniverseio/universe-ci-actions/universe-node-env@8e24bc760556caa5ec8c7c497baaad2e9adcc912 # v1
- run: npm run lint:check
```

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

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding `package.json` and `package-lock.json`. |
| `node-version-file` | `.nvmrc` | File holding the pinned Node.js version. |
| `install` | `true` | Set to `false` to resolve the toolchain and touch no dependencies. |
| `npm-install-args` | empty | Extra flags appended to the fallback `npm ci`. They are part of the dependency key, so changing them changes the identity of the tree. |
| `store-root` | empty | Directory holding the content-addressed dependency store on a persistent runner. Ignored on ephemeral runners, which use `actions/cache`. |

## Outputs

| Output | Meaning |
| --- | --- |
| `node-version` | Node.js version now on `PATH`. |
| `npm-version` | npm version now on `PATH`. |
| `dependency-key` | The content-addressed dependency key. |
| `dependency-state` | `hit`, `miss`, or `empty` when the lockfile installs nothing. |
| `persistent-runner` | `true` when the runner keeps its disk between jobs. |

```yaml
- id: env
  uses: bitcoinuniverseio/universe-ci-actions/universe-node-env@8e24bc760556caa5ec8c7c497baaad2e9adcc912 # v1
- run: echo "node ${{ steps.env.outputs.node-version }} deps ${{ steps.env.outputs.dependency-state }}"
```

## How the toolchain is resolved

1. **Find the pin.** `.nvmrc` (or `node-version-file`) if present; otherwise an
   exact three-part `engines.node` from `package.json`; otherwise the
   organization pin, 24.19.0. Each fallback is announced in the log.
2. **Select it from the tool cache.** The action prepends
   `$RUNNER_TOOL_CACHE/node/<version>/<arch>/bin` to `PATH`. This is a `PATH`
   change, not a download, which is why a warm job spends milliseconds here.
3. **Check npm.** npm ships inside the Node tarball. When `engines.npm` is set
   and the resolved npm differs, the action repairs the tool cache copy once and
   fails the job if the repair did not take.

Two failure modes are treated as runner image defects rather than job problems,
and both are annotated so they can be fixed at the image instead of repeatedly:

- **`TOOLCHAIN MISS`**: the pinned Node.js is not in the tool cache. The action
  emits a warning, falls back to `actions/setup-node` for this one job so the
  branch is still validated, brings npm to the pin, and leaves a loud marker in
  the log.
- **`NPM MISS`**: the tool cache has a different npm than the repository pins.
  Repaired once, with a warning.

If the tool cache holds a different Node.js version than the directory name
claims, the action fails with an error. That is a corrupt image, not something
to work around.

## How the dependency key is built

The key is a SHA-256 over everything that can make a restored tree wrong:

```
schema, os, arch, libc, node version, node ABI, npm version,
npm-install-args, repository, working directory,
sha256(package.json), sha256(every lockfile)
```

Producing:

```
universe-deps-v2-<os>-<arch>-<libc>-node<version>-npm<version>-<digest>
```

Three details worth knowing:

- **`libc` is part of the key.** glibc and musl produce incompatible native
  addons for the same Node ABI.
- **The Node ABI is part of the key**, because that is what every prebuilt
  native addon is compiled against.
- **`package.json` is hashed separately from the lockfile**, because it carries
  overrides, workspaces, engines and install scripts that do not appear in the
  lockfile hash alone.

Lockfiles are discovered with `git ls-files`, so a workspace repository with
several `package-lock.json` files folds all of them into one key.

## Where the tree is stored

| Runner class | Storage | Transfer |
| --- | --- | --- |
| Persistent (self-hosted fleet) | A content-addressed `.tar.zst` archive on local disk, in a store shared by every runner service on that host | none |
| Ephemeral (RunsOn) | `actions/cache`, served from the account's own S3 bucket | inside the VPC |

Resolution order on a persistent runner:

1. The exact archive already exists on this runner's disk. Extract it. `hit`.
2. `actions/cache` already restored the exact tree for this key. `hit`.
3. Otherwise `npm ci` runs. This is the only place a dependency download
   happens, and it happens once per dependency identity rather than once per job.
   The resulting tree is archived to a private temporary name and moved into
   place, so a second job racing on the same key never reads a half-written
   archive.

The store is pruned by least recent use, keeping `UNIVERSE_DEP_STORE_KEEP`
archives (default 24). Every hit touches its archive, so an active dependency
identity survives. Stale `.partial` files older than two hours are removed.

## Repositories with no dependencies

A repository can legitimately have nothing to install: a documentation site that
runs plain Node scripts may have no `package.json` or no lockfile. The action
says `NO DEPENDENCIES`, sets `no-dependencies=true`, and lets the toolchain stand
on its own rather than failing the job. A lockfile that resolves to nothing
reports `dependency-state: empty`.

## Environment variables it honours

| Variable | Effect |
| --- | --- |
| `UNIVERSE_NODE_VERSION` | Organization Node.js pin used when a repository declares none. Defaults to 24.19.0. |
| `UNIVERSE_DEP_STORE` | Dependency store root on a persistent runner. |
| `UNIVERSE_DEP_STORE_KEEP` | Number of archives kept before least-recently-used pruning. Default 24. |

## Platform support

Every step runs `shell: bash`, and the tool cache path handling assumes the
Linux layout used by the fleet's Linux runners. Use it there. For a job that has
to run under PowerShell on another platform, see
[portable-node-ci.md](portable-node-ci.md), which is the older and slower
contract but is not Linux specific.

## Reading the log

The action is deliberately loud about what it did, because a CI change that
silently stops reusing anything is expensive and invisible:

```
TOOLCHAIN HIT: node 24.19.0 npm 11.17.0 from /opt/hostedtoolcache/node/24.19.0/x64
DEPENDENCY KEY: universe-deps-v2-linux-x64-glibc-node24.19.0-npm11.17.0-<digest>
DEPENDENCY STORE: /.../.universe-dep-store (persistent=true)
DEPENDENCY HIT: universe-deps-v2-... in 3s
```

A line saying `DEPENDENCY MISS` on a job whose dependencies did not change means
the key moved. Compare the key between the two runs: the field that differs
names the cause.

Each run also appends a one-line dependency summary to the job step summary.
