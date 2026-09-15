# Actions storage maintenance

`scripts/maintain-actions-storage.ps1` uses the authenticated GitHub CLI to
remove only two categories of reconstructable Actions storage:

- artifacts already marked expired by GitHub
- caches belonging to pull requests that are currently closed

It never deletes workflow runs, non-expired artifacts, default-branch caches,
open-pull-request caches, releases, or packages. Package deletion needs a
separate deployment-reference audit because an image digest can be live even
when it is not tagged.

Run a report-only pass:

```powershell
pwsh -File scripts/maintain-actions-storage.ps1
```

Apply the safe cleanup:

```powershell
pwsh -File scripts/maintain-actions-storage.ps1 -Apply
```

The organization-level artifact and log retention setting is three days. This
script is the daily safety net for objects awaiting GitHub's asynchronous
expiration and for caches from closed pull requests.
