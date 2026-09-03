# Database fixture actions

`portable-mysql-fixture` and `portable-postgres-fixture` start an isolated
database container for the duration of one job, publish its host and port as
outputs, and remove it in a post step.

Both are `node24` JavaScript actions with a `post` step, so cleanup runs even
when the job fails.

## Requirements

- A Linux runner. Both actions fail immediately on any other platform.
- Docker Engine 29.7.2 exactly. Run
  [`universe-docker-env`](container-builds.md#universe-docker-env) first on a
  runner that may not have it.
- The image must be pinned by digest. An `image` input without `@sha256:` is
  refused.

Target `runs-on: [self-hosted, linux-ultra, linux-container-builder]`.

## `portable-mysql-fixture`

```yaml
- uses: bitcoinuniverseio/universe-ci-actions/universe-docker-env@a812b5dfdaf19401b054a8f7d248a3e875cd86f2
- id: mysql
  uses: bitcoinuniverseio/universe-ci-actions/portable-mysql-fixture@be40d57392687ec250a02b1096cb1c4db5782b74
  with:
    image: mysql@sha256:REPLACE_WITH_THE_DIGEST_YOU_PINNED
    database: universe_ci
    user: universe_ci
    password: ${{ secrets.CI_FIXTURE_PASSWORD }}
    root_password: ${{ secrets.CI_FIXTURE_ROOT_PASSWORD }}
- run: npm test
  env:
    DB_HOST: ${{ steps.mysql.outputs.host }}
    DB_PORT: ${{ steps.mysql.outputs.port }}
```

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `image` | yes | | MySQL image pinned by sha256 digest. |
| `database` | yes | | Database created for the job. `[A-Za-z0-9_]{1,64}`. |
| `user` | no | `universe_ci` | Non-root user. `[A-Za-z0-9_]{1,32}`, and it must not be `root`. |
| `password` | yes | | Password for the non-root user. |
| `root_password` | yes | | Root password for the isolated fixture. |
| `connection_host` | no | `auto` | See [reaching the fixture](#reaching-the-fixture). An explicit host is tried alone and fails loudly when it does not answer. |

## `portable-postgres-fixture`

Same shape, without `root_password`.

## `portable-redis-fixture`

```yaml
- id: redis
  uses: bitcoinuniverseio/universe-ci-actions/portable-redis-fixture@REPLACE_WITH_THE_COMMIT_YOU_PINNED
  with:
    image: redis@sha256:REPLACE_WITH_THE_DIGEST_YOU_PINNED
- run: npm run test:redis-integration
  env:
    REDIS_URL: ${{ steps.redis.outputs.url }}
```

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `image` | yes | | Redis image pinned by sha256 digest. |
| `connection_host` | no | `auto` | See [reaching the fixture](#reaching-the-fixture). |

It also publishes `url`, `redis://host:port`, ready to be used as is.

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `image` | yes | | PostgreSQL image pinned by sha256 digest. |
| `database` | yes | | Database created for the job. |
| `user` | no | `universe_ci` | Non-root user, not `root`. |
| `password` | yes | | Password for the user. |

## Outputs

Both actions:

| Output | Value |
| --- | --- |
| `host` | The address that proved reachable from the runner (see [reaching the fixture](#reaching-the-fixture)) |
| `port` | The dynamically allocated host port |
| `container` | The run-scoped container name |

The port is allocated by Docker, not fixed, so two jobs on the same host never
collide. Read the host and the port from the outputs; never hardcode `127.0.0.1`,
`host.docker.internal`, 3306, 5432 or 6379 on the caller's side.

## Reaching the fixture

The container publishes its port on the Docker host's loopback only. Where the
caller is decides how that port is reached:

- a runner running natively on the Docker host reaches it on its own
  `127.0.0.1`;
- a runner that is itself a container reaches the host's published port
  through the Docker bridge gateway, or through `host.docker.internal` on a
  daemon started with `host-gateway`, and never through its own loopback.

A workflow that writes either address into a connection string works on one
kind of host and fails on the other, which is exactly what happened to the
KNOT HEADS backend checks on 3 September 2026. So the fixture proves the route
instead of assuming it. With `connection_host: auto` (the default) it waits
until the service is healthy inside its container, then connects to the
published port from the runner's own process through each candidate in turn,
`127.0.0.1`, the bridge gateway, `host.docker.internal`, and publishes the
first one that answers, as an address: a name that answered is resolved once
and its IPv4 address is published, so no later connection depends on the
engine's embedded DNS. An explicit `connection_host` is tried alone and fails
loudly when it does not answer, so a caller that names the wrong topology finds
out at the fixture rather than in its tests.

## What they actually do

1. Refuse a non-Linux platform and a Docker Engine that is not 29.7.2.
2. Validate the inputs: digest-pinned image, safe database and user names, not
   `root`.
3. `docker run --detach` with a run-scoped container name and a
   `universe.ci.run` label carrying the run id, publishing the database port on
   `127.0.0.1` only.
4. Wait for the database to answer, then wait for the TCP port.
5. Publish `host`, `port` and `container`.
6. In the post step, `docker rm --force` the container.

MySQL is started with `--skip-innodb-use-native-aio`. Test runners share finite
host AIO capacity between isolated jobs, and MySQL's synchronous fallback is
sufficient for a fixture while avoiding a host-wide `io_setup(EAGAIN)` that made
clean-schema checks flaky.

## About the password inputs

These are parameters for a throwaway container that exists for the length of one
job and is published on loopback only. They are not credentials for anything that
outlives the job, and nothing in this repository holds a secret, an account
identifier or an infrastructure address.

Still pass them from repository or organization secrets rather than writing a
literal into a workflow file, so a value is never in the log or the diff.
