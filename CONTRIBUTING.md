# Contributing

Every action here is consumed by many repositories across the organization, so
treat a change as a change to a public interface.

## Before you change an action

Read [docs/pinning.md](docs/pinning.md). Consumers pin by full commit SHA, so
nothing you push can change an existing pinned workflow. What you can do is make
the next pin harder to adopt. Classify your change first:

| Change | Kind |
| --- | --- |
| New input with a default that preserves current behaviour | additive |
| New output | additive |
| Changed default, renamed input or output | breaking |
| Changed dependency or build key composition | breaking in effect: every consumer takes a one-time cache miss |
| New runner requirement, new required tool, new label | breaking |

Land breaking changes deliberately, then move `v1`, then tell the repositories
that pin it.

## Rules that are not negotiable

- **No GitHub-hosted runner labels.** Not in this repository's own workflows, not
  in an example in the documentation, not in a test fixture. See
  [docs/runners.md](docs/runners.md).
- **Pinned toolchain.** Node.js 24.19.0, npm 11.17.0, Docker Engine 29.7.2. If
  you change a pin here, change it everywhere it appears in this repository in
  the same commit: the action scripts, the fleet workflows, and the
  documentation.
- **No secrets, no account identifiers, no infrastructure addresses.** This
  repository is public. That includes hostnames, IP addresses, licence keys and
  cloud account details, in code, in comments and in examples.
- **Third-party actions are pinned by SHA** with a trailing version comment,
  exactly as `actions/setup-node` and `actions/cache` are pinned today.

## Shell scripts

- `bash` scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Keep logic in a `.sh` next to the `action.yml` rather than inline in YAML.
  Inline shell in a composite action is hard to read, hard to lint and hard to
  test.
- Every input reaching a shell is validated before it is used. Look at how
  `portable-container-build` checks its tag, build arguments, run environment
  and JSON command before it invokes Docker, and match that standard.
- Be loud. A CI helper that silently stops reusing anything is expensive and
  invisible. Print the key, the store and the hit or miss, and append a line to
  `GITHUB_STEP_SUMMARY` where it helps.

## Changing a cache key

The dependency key carries `schema=2` and the build key is prefixed `build-v1-`.
If you change what goes into a key, bump that schema so new archives cannot
collide with old ones, and say in the pull request that consumers will see one
`DEPENDENCY MISS` or `BUILD MISS` after upgrading their pin.

## Testing a change

There is no unit test suite for these actions. Verify a change by running it:

1. Push your branch here.
2. In one consuming repository, point a workflow at your branch's commit SHA
   temporarily and run it.
3. Read the log. `universe-node-env` and `universe-build-store` both print the
   key, the store and the outcome, which is what you are checking.
4. Confirm the result on both runner classes when the change touches runner
   detection: a persistent fleet runner and an ephemeral RunsOn one behave
   differently by design.
5. Revert the temporary pin, merge here, then roll the new SHA out.

`.github/workflows/ci.yml` in this repository checks the Docker pin on a
container-builder runner. Keep it passing.

## Documentation is part of the change

Any change to an input, an output, a default, a key, a runner requirement or a
pinned version updates the matching page under `docs/` in the same pull request.
The README table and the per-action page must not disagree.

Prose style:

- No em dash characters. Use commas, colons, periods or parentheses.
- Plain, direct writing. Short paragraphs. A table beats three paragraphs.
- No untested examples. If you have not run it, do not publish it.

## Branches

`develop` is the working branch. Branch from it and target it. `main` carries
what consumers pin.
