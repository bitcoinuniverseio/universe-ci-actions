# Container actions

Two actions cover container work: one makes sure the runner has the pinned
Docker Engine, the other builds and smoke-tests a Linux image.

Both require **Docker Engine 29.7.2** and refuse to proceed on anything else.
Target a runner that carries `linux-container-builder`.

## `universe-docker-env`

Checks the Docker Engine version and installs the pinned 29.7.2 when the runner
image has a different release. Use it before a container fixture on a fresh
RunsOn machine. On the permanent fleet it is a no-op.

```yaml
- uses: bitcoinuniverseio/universe-ci-actions/universe-docker-env@a812b5dfdaf19401b054a8f7d248a3e875cd86f2
- uses: bitcoinuniverseio/universe-ci-actions/portable-mysql-fixture@be40d57392687ec250a02b1096cb1c4db5782b74
  with:
    image: mysql@sha256:REPLACE_WITH_THE_DIGEST_YOU_PINNED
    database: universe_ci
    password: ${{ secrets.CI_FIXTURE_PASSWORD }}
    root_password: ${{ secrets.CI_FIXTURE_ROOT_PASSWORD }}
```

No inputs.

| Output | Meaning |
| --- | --- |
| `docker-version` | Docker Engine version available to later steps. |

It installs from the Docker apt repository on Ubuntu, needs `sudo`, and fails
with a clear message when 29.7.2 is not offered for that runner image.

## `portable-container-build`

Builds a Linux image with `docker buildx build --load`, optionally runs a
command inside the built image, and cleans up.

```yaml
- uses: bitcoinuniverseio/universe-ci-actions/portable-container-build@be40d57392687ec250a02b1096cb1c4db5782b74
  with:
    tag: index-patina:${{ github.sha }}
    run-environment: |
      PATINA_NETWORK=regtest
      PATINA_RPC_OFFLINE=true
    run-command-json: '["status","--json"]'
```

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `context` | `.` | Build context, repository-relative or absolute. Must exist. |
| `dockerfile` | empty | Dockerfile path. Defaults to the one in the context. |
| `tag` | empty | Image tag. A run-scoped tag is generated when omitted. |
| `target` | empty | Dockerfile target stage. |
| `build-args` | empty | Newline-separated `KEY=VALUE` build arguments. |
| `pull` | `false` | Pull referenced base images before building. |
| `cleanup` | `true` | Remove the image after the build, successful or not. |
| `run-environment` | empty | Newline-separated `KEY=VALUE` environment for a post-build container command. |
| `run-command-json` | `[]` | JSON array command executed in the built image before cleanup. |

| Output | Meaning |
| --- | --- |
| `tag` | The image tag that was built. |

### What it validates before it builds

Every input that reaches a shell is checked first, and a malformed one fails the
step rather than being passed through:

- `tag` must be an explicit `name:tag`, matching
  `^[a-zA-Z0-9][a-zA-Z0-9._/-]*:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$`. A bare image
  name with no tag is refused.
- Each `build-args` and `run-environment` line must look like
  `NAME=value` with a valid shell identifier on the left.
- `run-command-json` must parse as a JSON array of non-empty strings.
- `context` and `dockerfile` must resolve to real paths.
- The runner must be Linux. `RUNNER_OS` anything else fails the step outright.

### The smoke test pattern

The `run-environment` and `run-command-json` inputs exist so a build can prove
the image actually starts before it is thrown away. `index-patina` uses exactly
that: it builds the image, then runs the indexer's own `status --json` inside it
with an offline configuration, so a broken image fails the pull request rather
than a deployment.

A command runs when either input is non-empty. With both empty, the action
builds and stops.

### Cleanup

With `cleanup: true` (the default) the image is removed in a `finally` block, so
a failed build does not leave an image behind on a persistent runner. Disk on
the fleet is a shared resource; leave the default alone unless a later job in the
same run needs the image.
