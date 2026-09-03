# `universe-node-env`

Verifies the pinned Node.js and npm that the runner host already carries, then
activates an exact, pre-warmed dependency tree from the host's shared store.
On a warm runner nothing is downloaded and nothing is installed. A runner that
is missing its toolchain fails with a provisioning error instead of repairing
itself inside the job.

This is the action most repositories in the organization depend on. Its
contract is below in full.

## Usage

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: bitcoinuniverseio/universe-ci-actions/universe-node-env@<pin> # v2
- run: npm run lint:check
```

It replaces all three of these:

```yaml
- uses: actions/setup-node@...
  with:
    node-version-file: .nvmrc
    cache: npm                       # downloads a large npm store every job
- run: npm install --global npm@X    # reinstalls the version already present
- run: npm ci                        # relinks an unchanged dependency tree
```

## The steady state

```
CHECKOUT -> Verify pre-warmed runtime (milliseconds)
         -> Verify dependency fingerprint (a hash over the inputs)
         -> Activate pre-warmed dependencies (hard links, seconds)
         -> test / lint / build
```

Measured on 2026-09-03 with `forked-felines` (16,373 files in the tree):

| host | `npm ci` in a job before | activation now |
| --- | --- | --- |
| Primcast (`universe-super`) | 56 s cold on a fresh host | 2 s |
| PowerVPS guest at load 206 (`universe-ultra`) | 456 to 524 s | 8 to 12 s |

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `working-directory` | `.` | Directory holding `package.json` and `package-lock.json`. |
| `node-version-file` | `.nvmrc` | File holding the pinned Node.js version. |
| `install` | `true` | Set to `false` to verify the toolchain and touch no dependencies. |
| `npm-install-args` | empty | Extra flags for the one cold `npm ci` that builds a new fingerprint. They are part of the fingerprint. |
| `store-root` | empty | Dependency store root on a persistent runner. Defaults to the host's `UNIVERSE_DEP_STORE`. Ignored on ephemeral runners, which use `actions/cache`. |

## Outputs

| Output | Meaning |
| --- | --- |
| `node-version` | Node.js version now on `PATH`. |
| `npm-version` | npm version now on `PATH`. |
| `dependency-key` | The dependency fingerprint. |
| `dependency-state` | `hit`, `miss`, or `empty` when the lockfile installs nothing. |
| `persistent-runner` | `true` when the runner keeps its disk between jobs. |

## How the toolchain is verified

1. **Find the pin.** `.nvmrc` (or `node-version-file`) if present; otherwise an
   exact three-part `engines.node` from `package.json`; otherwise the
   organization pin, 24.19.0.
2. **Select it from the tool cache.** `$RUNNER_TOOL_CACHE/node/<version>/<arch>/bin`
   is prepended to `PATH`. That is the whole cost.
3. **Check npm.** npm is provisioned inside the same Node copy at the pinned
   version. A mismatch with `engines.npm` is a provisioning defect.

Any miss fails the job immediately:

```
RUNNER PROVISIONING ERROR: Node.js 24.19.0 is not in the tool cache ... on universe-linux-super-07
Required Node.js/npm toolchain is not preinstalled on universe-linux-super-07.
Repair the host with provision-toolchain.sh before it accepts CI jobs.
```

Nothing is downloaded and nothing is installed by a job. Infrastructure drift
is exposed, never hidden behind a slow self-repair.

## The dependency fingerprint

`universe-deps key` hashes everything that can make a restored tree wrong:

```
schema, os, arch, libc, node version, node ABI, npm version, install flags,
sha256(package.json), sha256(.npmrc), sha256(every lockfile),
sha256(every workspace package.json named by the lockfile)
```

Producing:

```
universe-deps-v3-<os>-<arch>-<libc>-node<version>-abi<n>-npm<version>-<digest>
```

- **`libc` and the Node ABI are part of the key**, because prebuilt native
  addons are compiled against exactly those.
- **Workspace manifests are hashed**, because npm validates every one of them
  against the lockfile and a nested `node_modules` under a workspace changes
  with them.
- **The key is not tied to a repository or path.** Two checkouts with
  identical inputs share one snapshot.

## Where the tree lives, and how a job gets it

On a persistent runner the host keeps one immutable snapshot per fingerprint
in `UNIVERSE_DEP_STORE/trees/<key>/`. It holds every `node_modules` directory
the install produced (the root and any nested workspace trees), every file
read-only, plus a metadata manifest.

A job's activation:

1. Takes a shared lock on the fingerprint and verifies the snapshot's
   manifest (mode, size, mtime of every file). A snapshot that drifted is
   quarantined and rebuilt, never reused.
2. Removes any `node_modules` in the workspace and creates a **private
   hard-link farm** of the snapshot there. Thousands of files link in well
   under a second on an idle host. The workspace gets its own directories, so
   tools may create new files; the shared inodes are read-only, so no job can
   edit what the next job receives. Nothing is shared writable between
   runners.

A fingerprint with no snapshot is built **exactly once per host**: the first
job takes an exclusive lock, runs `npm ci --prefer-offline` from the host's
npm content cache, moves the resulting trees into the store, marks them
read-only, writes the manifest and publishes the snapshot atomically. Every
job that arrives meanwhile waits on the lock and then links the same tree. The
log states how many packages the cold build fetched from the network.

The same script, `universe-deps`, is installed on every host by
`provision-toolchain.sh` and used by the fleet warmer, so a snapshot warmed at
provisioning time is the one a job links. The action uses the host's copy and
falls back to its bundled copy on a host that predates it.

Retention is least recently used: `UNIVERSE_DEP_STORE_KEEP` trees (default
600) survive, a tree used in the last hour or being linked right now is never
removed, and a pruned tree leaves every job's existing links intact.

Ephemeral runners (none in the fleet today) use `actions/cache` with the same
key.

## Repositories with no dependencies

A repository can legitimately have nothing to install: a documentation site
that runs plain Node scripts may have no `package.json` or no lockfile. The
action says `NO DEPENDENCIES`, sets `no-dependencies=true`, and lets the
toolchain stand on its own. A lockfile that resolves to nothing reports
`dependency-state: empty`.

## Environment variables it honours

| Variable | Effect |
| --- | --- |
| `UNIVERSE_NODE_VERSION` | Organization Node.js pin used when a repository declares none. Defaults to 24.19.0. |
| `UNIVERSE_DEP_STORE` | Dependency store root on a persistent runner. |
| `UNIVERSE_DEP_STORE_KEEP` | Trees kept before least-recently-used pruning. Default 600. |
| `UNIVERSE_DEPS_BIN` | Path of the host's `universe-deps`; defaults to `bin/universe-deps` beside the store. |
| `UNIVERSE_DEPS_VERIFY` | `full` (default) verifies the manifest on every activation; `none` skips it. |

## Reading the log

```
NODE: preinstalled 24.19.0 (/opt/actions-runner/.toolcache/node/24.19.0/x64/bin/node)
NPM: preinstalled 11.17.0 (/opt/actions-runner/.toolcache/node/24.19.0/x64/bin/npm)
DEPENDENCY FINGERPRINT: universe-deps-v3-linux-x64-glibc-node24.19.0-abi137-npm11.17.0-<digest>
DEPENDENCY CACHE: warm
DEPENDENCY SOURCE: local warm state
DEPENDENCY ACTIVATED: 16373 files linked in 2s
```

A cold fingerprint reads `DEPENDENCY CACHE: cold`, `DEPENDENCY SOURCE: refresh
required`, then `DEPENDENCY BUILT: <files> in <s>, network package downloads:
<n>`. A cold line on a job whose dependencies did not change means the key
moved: compare the two keys, the field that differs names the cause.

Each run appends the same one-line summary to the job step summary.

## Platform support

Every step runs `shell: bash` on the fleet's Linux runners. The store relies
on hard links and `flock`. For a job that has to run under PowerShell on
another platform, see [portable-node-ci.md](portable-node-ci.md).

## Testing

`node --test universe-node-env/universe-deps.test.mjs` on a Linux host with
node and npm on `PATH` builds a tiny workspace cold, activates it warm, proves
the hard links and write protection, moves the fingerprint, tampers with a
snapshot and watches it get rebuilt.
