# `universe-build-store`

Saves a build output once and restores it everywhere else, keyed by the exact
commit plus the toolchain and machine shape that produced it.

On a persistent runner the store is local disk shared by every runner service on
the host, so nothing is uploaded, downloaded or metered.

## Usage

Save, in the job that builds:

```yaml
- run: npm run build
- uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@8e24bc760556caa5ec8c7c497baaad2e9adcc912 # v1
  with:
    path: dist
    mode: save
```

Restore, in every job that only consumes the build:

```yaml
- id: build
  uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@8e24bc760556caa5ec8c7c497baaad2e9adcc912 # v1
  continue-on-error: true
  with:
    path: dist
    mode: restore
- name: Build if the store had nothing
  if: steps.build.outputs.state != 'hit'
  run: npm run build
```

## Inputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `path` | yes | | Directory to save or restore. |
| `mode` | yes | | `save` or `restore`. |
| `key-suffix` | no | empty | Extra text folded into the key, for a repository that builds more than one output from one commit. |

## Outputs

| Output | Value |
| --- | --- |
| `state` | `hit` or `miss` on restore, `stored` on save, `unavailable` when the store is not writable. |

## The restore step fails on a miss

This is the one behaviour that surprises people, so it is worth stating plainly:

**`mode: restore` exits non-zero when the archive is not there.** It sets
`state=miss` first, so the output is readable, but the step itself fails.

That is deliberate: a restore that silently produced nothing would leave a later
step consuming an empty directory. It does mean a consumer that wants to fall
back to building must set `continue-on-error: true` on the restore step and
branch on `steps.<id>.outputs.state`, as in the example above.

`state=unavailable` behaves the same way: a restore fails, and a save emits a
warning and succeeds without storing anything, because a runner that cannot
share build output should not fail an otherwise good build.

## The key

```
build-v1-<owner>-<repo>-<commit sha>-<16 hex of sha256(path + key-suffix)>-<os>-<arch>-node<version>
```

The commit is what makes a build output correct, together with the toolchain
that produced it and the machine shape it was produced for. A different commit,
a different Node.js version or a different architecture is a different key, so a
restore can never hand a job the wrong bytes.

## Storage and pruning

The store defaults to a `.universe-build-store` directory beside the npm cache
root, which is the shared location every runner service on the host can reach.
Override with `UNIVERSE_BUILD_STORE`.

Archives are `.tar.zst`, written to a private temporary name and moved into
place so a racing job never reads a half-written archive. Pruning is by least
recent use, keeping `UNIVERSE_BUILD_STORE_KEEP` archives (default 40). A restore
touches its archive, so anything a live branch still consumes survives. Stale
`.partial` files older than two hours are removed.

## When to use `actions/upload-artifact` instead

Use it only when the bytes genuinely have to leave the fleet, for example when a
human needs to download them from the run page.

`upload-artifact` is metered against the account's Actions storage quota. That
quota being full is what broke artifact uploads across the organization on
2026-08-31. The build store has no such quota because nothing leaves the host.
