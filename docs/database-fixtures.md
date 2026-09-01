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

## `portable-postgres-fixture`

Same shape, without `root_password`.

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
| `host` | `127.0.0.1` |
| `port` | The dynamically allocated host port |
| `container` | The run-scoped container name |

The port is allocated by Docker, not fixed, so two jobs on the same host never
collide. Read it from the output; never hardcode 3306 or 5432 on the host side.

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
