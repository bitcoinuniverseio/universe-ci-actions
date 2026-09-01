# Security

## Reporting

Send reports to security@bitcoinuniverse.org. Include the action, the commit SHA
you are describing, and the smallest reproduction you have. Do not open a public
issue.

We acknowledge reports within three working days.

## What this repository contains

Composite and JavaScript GitHub Actions, and two `workflow_dispatch` diagnostic
workflows. There is no service, no network endpoint and no data store.

**Nothing here holds a secret, a credential, an account identifier or an
infrastructure address.** That is a property to preserve on every change, not a
one-time claim. The repository is public precisely so that public repositories
can resolve these actions.

The `password` and `root_password` inputs on the database fixture actions are
parameters for a throwaway container that lives for the length of one job and is
published on loopback only. They are not credentials for anything that outlives
the job. Pass them from repository or organization secrets so a value never
appears in a log or a diff.

## Trust model

These actions run inside your job, with your job's token and your job's
filesystem. A change here is a change to code that executes in every consuming
repository, which is why:

- Consumers pin by full 40-character commit SHA, so a push to this repository
  cannot change an existing workflow. See [docs/pinning.md](docs/pinning.md).
- Third-party actions used inside these actions are themselves pinned by SHA.
- Every input that reaches a shell is validated before use. Image tags, build
  arguments, run environment lines and JSON commands are all pattern-checked in
  `portable-container-build`; database and user names are pattern-checked in the
  fixtures, and the fixture user may not be `root`.
- Container images for the database fixtures must be pinned by `@sha256:`
  digest. A tag-only image is refused.

## Guidance for consuming workflows

- `actions/checkout` with `persist-credentials: false` unless the job genuinely
  needs to push. Every example in this repository does this.
- Declare least-privilege `permissions:` at workflow level. `contents: read` is
  enough for a build and test job.
- Guard jobs that run on shared self-hosted runners against pull requests from
  forks. The pattern used in the organization is
  `github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository`.
  A shared runner must never execute untrusted code.
- Never echo a secret. Pass it through `env:` and let the action read it.

## Shared runner considerations

The dependency store and the build store are shared by every runner service on a
host, and are content-addressed by a key that includes the repository. A key
collision across repositories is not possible for that reason. Anyone with the
ability to run a job on a fleet runner can read those stores, which is the normal
trust boundary for a shared self-hosted fleet: treat the fleet as one trust
domain and keep untrusted code off it.

## Out of scope

- Vulnerabilities in Node.js, npm, Docker or GitHub Actions themselves. Report
  those upstream; tell us if a pinned version here needs moving.
- Runner provisioning and fleet infrastructure. That is not in this repository.
