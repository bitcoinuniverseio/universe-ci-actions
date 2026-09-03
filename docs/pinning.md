# Versioning and pinning

## How to reference these actions

**Pin by full 40-character commit SHA.** That is what every consumer in the
organization does today, and it is what the organization does for third-party
actions such as `actions/checkout` too.

```yaml
- uses: bitcoinuniverseio/universe-ci-actions/universe-node-env@8e24bc760556caa5ec8c7c497baaad2e9adcc912 # v1
```

The trailing comment is not decoration. A bare SHA tells a reader nothing about
how old the pin is, so name the tag or the date it corresponds to.

Why a SHA and not a branch:

- A branch reference means the next push to this repository changes the
  behaviour of every workflow in the organization at once, with no review in the
  consuming repository and no way to bisect a CI regression to a change.
- A SHA is the only reference GitHub cannot move.

## The `v1` tag

`v1` points at commit `8e24bc760556caa5ec8c7c497baaad2e9adcc912`, which is the
pin most consuming repositories already use. It is a release marker, not a
floating alias: it is not moved on every push to `main`, so a workflow pinned to
`v1` today does not silently change tomorrow.

If you prefer readability over immutability, `@v1` is acceptable **for the
actions that existed when it was tagged**. `@main` is not, for the reason above,
even though older examples used it.

## Verified pins

Each of these was checked on 2026-09-01 by confirming the action's `action.yml`
exists in this repository at that commit.

| Action | Pin | Note |
| --- | --- | --- |
| `universe-node-env` | `8e24bc760556caa5ec8c7c497baaad2e9adcc912` | the `v1` commit, and what most consumers already pin |
| `universe-build-store` | `8e24bc760556caa5ec8c7c497baaad2e9adcc912` | the `v1` commit |
| `universe-docker-env` | `a812b5dfdaf19401b054a8f7d248a3e875cd86f2` | **added after `v1` was tagged, so `@v1` does not resolve it** |
| `portable-container-build` | `be40d57392687ec250a02b1096cb1c4db5782b74` | |
| `portable-mysql-fixture` | `be40d57392687ec250a02b1096cb1c4db5782b74` | |
| `portable-postgres-fixture` | `be40d57392687ec250a02b1096cb1c4db5782b74` | |
| `portable-node-ci` | `be40d57392687ec250a02b1096cb1c4db5782b74` | |

The `universe-docker-env` row is the reason to check rather than assume: a
reference to `universe-docker-env@v1` fails to resolve, because the action did
not exist at that commit. Verify a pin before you copy it:

```sh
gh api "repos/bitcoinuniverseio/universe-ci-actions/contents/<action>/action.yml?ref=<sha>" -q .name
```

## Version identity of the actions themselves

| Component | Version identity |
| --- | --- |
| The action library | Git commit, with `v1` as the current release marker |
| Node.js and npm | 24.19.0 and 11.17.0, pinned by every action |
| Docker Engine | 29.7.2 exactly, checked by `universe-docker-env`, `portable-container-build` and both database fixtures |
| Database fixture images | Supplied by the caller, and required to be pinned by `@sha256:` digest |
| Third-party actions used inside these actions | Pinned by SHA: `actions/setup-node` v7.0.0, `actions/cache` v4.3.0 |

Two caches carry their own schema version inside the key, so a change in how a
key is computed cannot collide with archives written by an older version:
`universe-deps-v2-...` for dependencies and `build-v1-...` for build outputs.

## Upgrading a pin

1. Read what changed between your pinned SHA and the new one.
2. Update the SHA and the trailing comment in one commit, in one repository
   first.
3. Watch that repository's next run. `universe-node-env` prints the resolved
   toolchain, the dependency key and whether it hit, so a regression is visible
   in the log without instrumentation.
4. Roll the same pin out to other repositories.

A change to how a dependency or build key is computed shows up as a one-time
`DEPENDENCY MISS` or `BUILD MISS` on the first run after the upgrade. That is
expected. A miss on every run afterwards is not: compare the printed keys
between two runs and the differing field names the cause.

## Changing an action in this repository

An action here is consumed by many repositories, so treat every change as a
public API change:

- Additive input with a default: safe.
- Changed default, changed output name, changed key composition, changed runner
  requirement: breaking. Land it, then move `v1` deliberately, and tell the
  repositories that pin it.
- Never change behaviour under an existing pinned SHA. That is impossible by
  construction, which is exactly why SHA pinning is the rule.

See [CONTRIBUTING.md](../CONTRIBUTING.md).
