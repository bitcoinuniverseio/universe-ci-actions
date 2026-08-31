# Universe CI actions

Shared GitHub Actions for every Universe repository. This repository is public
so that public and private repositories can both consume it; an action stored
in a private repository cannot be resolved from a public one.

Nothing here holds a secret, a credential, an account identifier or any
infrastructure address.

## universe-node-env

Resolves the pinned Node.js and npm from the runner image and reuses an exact,
content-addressed dependency tree. Nothing is downloaded or installed on a warm
runner.

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: bitcoinuniverseio/universe-ci-actions/universe-node-env@main
- run: npm run lint:check
```

It replaces all three of these:

```yaml
- uses: actions/setup-node@...
  with:
    node-version-file: .nvmrc
    cache: npm                       # downloads a ~1 GB npm store every job
- run: npm install --global npm@X    # reinstalls the version already present
- run: npm ci                        # reinstalls an unchanged dependency tree
```

Measured on `backend-apis` run 33329978544: those three steps cost 282 seconds
per job and changed nothing. Node was already in the runner's tool cache and
resolved in 0.4 seconds.

Full rationale and the dependency key definition:
`.github-private/docs/node-ci-environment.md`.

## universe-build-store

Saves a build output once and restores it everywhere else, keyed by the exact
commit plus the toolchain and machine shape that produced it.

```yaml
- run: npm run build
- uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@main
  with: {path: dist, mode: save}
```

```yaml
- uses: bitcoinuniverseio/universe-ci-actions/universe-build-store@main
  with: {path: dist, mode: restore}
```

On a persistent runner the store is local NVMe shared by every runner service
on the host, so nothing is uploaded, downloaded or metered. Use
`actions/upload-artifact` only when the bytes genuinely have to leave the
fleet; it is metered against the account's Actions storage, and that quota
being full is what broke artifact uploads organization-wide on 2026-08-31.
