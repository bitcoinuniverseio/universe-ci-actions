# `universe-build-store`

Saves a build output once and restores it everywhere else, keyed by every input
that can change its bytes: the commit (or, with `inputs`, the content of the
files that matter), the build command, output-affecting environment, toolchain
and machine shape.

On a persistent runner the store is local disk shared by every runner service on
the host, so nothing is uploaded, downloaded or metered.

## Usage

Save, in the job that builds:

```yaml
- run: npm run build
- uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@<sha> # v2
  with:
    path: dist
    mode: save
```

Restore, in every job that only consumes the build:

```yaml
- id: build
  uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@<sha> # v2
  continue-on-error: true
  with:
    path: dist
    mode: restore
- name: Build if the store had nothing
  if: steps.build.outputs.state != 'hit'
  run: npm run build
```

Content mode, so a commit that changes only docs or tests reuses the output.
List every file the build reads; save and restore must pass the same values:

```yaml
- uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@<sha>
  with:
    path: frontend/dist
    mode: save
    command: npm run build
    inputs: |
      frontend/src
      frontend/public
      frontend/index.html
      frontend/package-lock.json
      frontend/vite.config.js
    env-keys: VITE_API_ORIGIN VITE_NETWORK
```

A cached build is evidence that these bytes came from these inputs. It is not
evidence that production is ready: deployment verification still runs live.

## Inputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `path` | yes | | Directory to save or restore, relative to the workspace. Absolute and `..` paths are rejected. |
| `mode` | yes | | `save` or `restore`. |
| `key-suffix` | no | empty | Extra text folded into the key, for a repository that builds more than one output from one commit. |
| `inputs` | no | empty | Newline-separated git pathspecs whose working-tree file contents determine the output. Switches the key from the commit to those contents. A pathspec list that matches no file is an error. |
| `command` | no | empty | The build command, folded into the key. |
| `env-keys` | no | empty | Names of environment variables whose values change the output. Values enter the key only as one opaque digest and are never logged. |
| `embeds-commit` | no | `false` | With `inputs`: set `true` when the build writes the commit id into its output, so the commit stays in the key. |

## Outputs

| Output | Value |
| --- | --- |
| `state` | Restore: `hit`, `miss`, `unavailable`. Save: `stored` (also when an identical entry already existed), `skipped` (free-space floor or write failure; the job still passes), `unavailable`. |
| `key` | The key this job saved or looked up. |
| `source` | On a hit, the key actually restored (a pull request may restore a trusted entry). |

## The restore step fails on a miss

**`mode: restore` exits non-zero when there is nothing usable to restore.** It
sets `state=miss` first, so the output is readable, but the step itself fails.

That is deliberate: a restore that silently produced nothing would leave a later
step consuming an empty directory. A consumer that wants to fall back to
building sets `continue-on-error: true` on the restore step and branches on
`steps.<id>.outputs.state`, as in the example above.

A corrupt or truncated entry is a miss too: the archive is extracted into a
scratch directory first, the existing directory is only replaced after a clean
extraction, and the bad entry is removed so the next save repairs it.

`state=unavailable` behaves the same way: a restore fails, and a save emits a
warning and succeeds without storing anything, because a runner that cannot
share build output should not fail an otherwise good build.

## The key

```
build-v2-<tier>-<owner>-<repo>-<32 hex of sha256(identity)>
```

The identity, printed in the log on every run (without environment values), is:

| Part | Commit mode (default) | Content mode (`inputs` set) |
| --- | --- | --- |
| Source | `GITHUB_SHA` | git blob ids of every tracked and untracked, non-ignored file the pathspecs match, as they are in the working tree, plus the commit when `embeds-commit` is true |
| Always | path, key suffix, `command`, names and digest of `env-keys`, OS, arch, `/etc/os-release` ID and version, libc version, Node.js and npm versions | same |

Content mode is what lets an unrelated commit reuse an output. It is only
correct when `inputs` lists every file the build reads. Generated files that are
git-ignored are not seen, so generate them inside the build or list their
sources. If the output embeds the commit id, set `embeds-commit: true`.

`v1` keys (`build-v1-…`) are never read by this version; they age out through
normal pruning. The first run after upgrading is one cold build per output.

### Trust tiers

`pull_request` and `pull_request_target` jobs write to the `pr` tier and can
restore from `pr` or `trusted`. Every other event writes to and reads from
`trusted` only, so a pull request job using this action can never hand a
release build its bytes.

This protects against mistakes, not against hostile code: the store is a
directory every job on the host can write, so code that runs in a job can still
write into it directly. Untrusted fork code must not run on these runners at all
(the CI workflows already gate forks off persistent runners).

## Storage, concurrency and pruning

The store defaults to a `.universe-build-store` directory beside the npm cache
root, which is the shared location every runner service on the host can reach.
Override with `UNIVERSE_BUILD_STORE`.

- **Writes** go to a private `mktemp` name and are renamed into place, so a
  racing job never reads a half-written archive. Concurrent producers of one key
  are safe (identical bytes by contract; the last rename wins). A save whose key
  already exists skips compression entirely.
- **Restores take a lease**: a hard link to the archive for the duration of the
  extraction. Pruning never removes an archive with more than one link, and the
  bytes stay readable if the entry is replaced mid-restore. A restore touches its
  archive first, which is also its least-recently-used signal.
- **Pruning** runs after each save, least recently used first, until all of these
  hold: at most `UNIVERSE_BUILD_STORE_KEEP` archives (default 40), at most
  `UNIVERSE_BUILD_STORE_MAX_BYTES` (default 20 GiB), and at least
  `UNIVERSE_BUILD_STORE_MIN_FREE_PCT` free on the filesystem (default 10%). The
  archive just written and leased archives are spared. If the floor still can't
  be met, the save is skipped with a warning rather than filling the disk.
  Partial files and leases older than two hours are removed.

## Compression

Archives are `.tar.zst` at level `UNIVERSE_BUILD_STORE_LEVEL` (default 3) with
`UNIVERSE_BUILD_STORE_THREADS` threads. The default thread count is this job's
share of the host: `nproc`, capped by a cgroup v2 `cpu.max` quota, divided by
the number of running `Runner.Worker` processes, clamped to 1..4. It is never
`-T0`: one PrimCast host runs 48 runner services, and `-T0` in every job asks
for every core at once.

Measured 2026-11-15 with `BENCH_STREAM=1 python3 scripts/bench-store-compression.py`
(zstd 1.5.7, 5 samples, median; Apple M5 Pro, 18 cores; not a fleet host):

| Payload | zstd | save CPU | save wall | restore wall | ratio |
| --- | --- | --- | --- | --- | --- |
| StampDEX frontend `node_modules`, 212 MB tar | `-6 -T0` (v1) | 1.49 s | 176 ms | 117 ms | 5.58 |
| | `-6 -T1` | 1.02 s | 989 ms | 114 ms | 5.58 |
| | `-3 -T1` | 0.36 s | 324 ms | 123 ms | 5.06 |
| | `-3 -T4` | 0.40 s | 105 ms | 119 ms | 5.06 |
| StampDEX frontend `dist`, 4.2 MB | `-6 -T0` (v1) | 0.03 s | 29 ms | 7 ms | 3.51 |
| | `-3 -T1` | 0.01 s | 16 ms | 7 ms | 3.27 |

Level 3 costs about a quarter of the compressor CPU of v1's `-6 -T0` for an
archive about 10% larger, and restore time does not change. On a single job the
wall-time difference is small, because walking the files in `tar` dominates
(about 3 s for that `node_modules` on macOS). The gain is host CPU under
concurrent saves. Re-run the benchmark on a fleet host before changing the
default.

`universe-node-env`'s dependency store uses the same level and thread rule
(`UNIVERSE_STORE_LEVEL`, `UNIVERSE_STORE_THREADS`).

## Tests

`bash universe-build-store/test.sh` runs the behaviour suite (CI job
`store-behaviour`): commit and content keys, irrelevant versus relevant changes,
environment and command identity, trust tiers, truncated and garbage entries,
in-flight partials, concurrent producers, leases under pruning, count, byte and
free-space budgets, thread bounds and path validation. It runs on Linux and
macOS.

## When to use `actions/upload-artifact` instead

Use it only when the bytes genuinely have to leave the fleet, for example when a
human needs to download them from the run page.

`upload-artifact` is metered against the account's Actions storage quota. That
quota being full is what broke artifact uploads across the organization on
2026-08-31. The build store has no such quota because nothing leaves the host.
