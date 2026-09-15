param(
  [string]$Organization = 'bitcoinuniverseio',
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Get-GhPagedList {
  param([string]$Endpoint, [string]$Property)
  $raw = gh api --paginate --slurp $Endpoint
  if (-not $raw) { return @() }
  $items = [System.Collections.Generic.List[object]]::new()
  foreach ($page in @($raw | ConvertFrom-Json)) {
    $source = if ($Property) { @($page.$Property) } else { @($page) }
    foreach ($item in $source) { $items.Add($item) }
  }
  return @($items)
}

$repos = Get-GhPagedList "orgs/$Organization/repos?per_page=100&type=all" ''
$candidates = [System.Collections.Generic.List[object]]::new()
foreach ($repo in $repos) {
  $base = "repos/$Organization/$($repo.name)"
  foreach ($artifact in Get-GhPagedList "$base/actions/artifacts?per_page=100" 'artifacts') {
    if ($artifact.expired) {
      $candidates.Add([pscustomobject]@{ kind='artifact'; repository=$repo.name; id=$artifact.id; size_in_bytes=$artifact.size_in_bytes; reason='expired' })
    }
  }
  foreach ($cache in Get-GhPagedList "$base/actions/caches?per_page=100" 'actions_caches') {
    if ($cache.ref -match '^refs/pull/(\d+)/merge$') {
      $state = gh api "$base/pulls/$($Matches[1])" --jq '.state' 2>$null
      if ($state -eq 'closed') {
        $candidates.Add([pscustomobject]@{ kind='cache'; repository=$repo.name; id=$cache.id; size_in_bytes=$cache.size_in_bytes; reason="closed-pr-$($Matches[1])" })
      }
    }
  }
}

$results = foreach ($candidate in $candidates) {
  $success = $null
  if ($Apply) {
    $endpoint = if ($candidate.kind -eq 'artifact') { "repos/$Organization/$($candidate.repository)/actions/artifacts/$($candidate.id)" } else { "repos/$Organization/$($candidate.repository)/actions/caches/$($candidate.id)" }
    & gh api --method DELETE $endpoint 2>&1 | Out-Null
    $success = $LASTEXITCODE -eq 0
  }
  [pscustomobject]@{ kind=$candidate.kind; repository=$candidate.repository; id=$candidate.id; size_in_bytes=$candidate.size_in_bytes; reason=$candidate.reason; success=$success }
}

[pscustomobject]@{
  at=(Get-Date).ToUniversalTime().ToString('o'); apply=[bool]$Apply
  artifact_candidates=@($results | Where-Object kind -eq 'artifact').Count
  artifact_bytes=(@($results | Where-Object kind -eq 'artifact') | Measure-Object size_in_bytes -Sum).Sum
  cache_candidates=@($results | Where-Object kind -eq 'cache').Count
  cache_bytes=(@($results | Where-Object kind -eq 'cache') | Measure-Object size_in_bytes -Sum).Sum
  failed=@($results | Where-Object {$_.success -eq $false}).Count
} | ConvertTo-Json -Compress
