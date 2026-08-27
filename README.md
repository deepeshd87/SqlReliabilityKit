# SqlReliabilityKit

A free, open-source (MIT) PowerShell module for SQL Server **reliability engineering** — backup recoverability, restore-chain validation, and Query Store regression analysis, with disaster-recovery drift detection and backup anomaly detection planned. Built on top of [dbatools](https://dbatools.io).

> Status: early / active development (v0.6.0). Feedback and issues welcome.

## Why this module

dbatools is superb for general SQL Server administration. SqlReliabilityKit focuses on a narrower theme — **is this estate actually recoverable, and is its performance drifting?** — packaging techniques that DBAs otherwise script by hand around backup, restore, DR, and Query Store.

## Requirements

- PowerShell 5.1+ (Windows) or PowerShell 7+
- [dbatools](https://dbatools.io) 2.0.0+ (`Install-Module dbatools`)
- SQL Server 2016+ for Query Store features

## Install

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/SqlReliabilityKit):

```powershell
Install-Module SqlReliabilityKit -Scope CurrentUser
```

To update to the latest version:

```powershell
Update-Module SqlReliabilityKit
```

Or install from source:

```powershell
git clone https://github.com/deepeshd87/SqlReliabilityKit.git
Import-Module ./SqlReliabilityKit/SqlReliabilityKit.psd1
```

## Commands

### `Find-SqlQueryStoreRegression`

Detects query performance regressions from Query Store runtime statistics using an
**execution-weighted baseline**. Instead of a naive "yesterday vs today average" — which
hides spikes and over-weights rarely-run queries — it weights each plan's historical
duration by execution count and filters out low-frequency, low-impact noise, so genuine
regressions surface.

Read-only: it reads Query Store DMVs and returns objects. It does not force plans or change
configuration.

```powershell
# Queries in AdventureWorks that ran 50%+ slower in the last day vs the prior 7-to-1-day baseline
Find-SqlQueryStoreRegression -SqlInstance sql01 -Database AdventureWorks

# Only regressions that at least doubled, on queries run 50+ times
Find-SqlQueryStoreRegression -SqlInstance sql01 -Database Sales -SlowdownThreshold 2.0 -MinExecutionCount 50

# Ten worst regressions by factor
Find-SqlQueryStoreRegression -SqlInstance sql01 -Database Sales |
    Sort-Object SlowdownFactor -Descending | Select-Object -First 10
```

The underlying technique is described here:
<https://dzone.com/articles/sql-server-query-store-regression>

### `Test-SqlRestoreChain`

Checks the **backup chain** for one or more databases. By default (logical mode) it reads
backup history from msdb, confirms that the expected backups are present and current for the
database's recovery model, and reports the current **RPO gap** (time since the last
restorable backup), flagging databases whose most recent backup is stale — without touching
the data. Logical mode is a presence-and-currency check against backup history; it does not
by itself guarantee that every log interval will restore.

With `-Physical`, it proves recoverability directly: it restores the chain to a temporary
test database, runs `DBCC CHECKDB`, reports pass/fail with duration, and drops the test copy.
This is the mode to use when you need auditable proof that a database actually restores,
rather than a check that the backups exist.

```powershell
# Logical check: are the Sales backups present and current, and how old is the last restorable point?
Test-SqlRestoreChain -SqlInstance sql01 -Database Sales

# Flag any user database whose last restorable backup is more than 4 hours old
Test-SqlRestoreChain -SqlInstance sql01 -MaxRpoHours 4

# Prove it: actually restore Sales to a test DB and run DBCC CHECKDB
Test-SqlRestoreChain -SqlInstance sql01 -Database Sales -Physical

# Only databases with a broken or stale chain
Test-SqlRestoreChain -SqlInstance sql01 | Where-Object { -not $_.ChainHealthy }
```

### `Export-SqlReliabilityReport`

Renders the results of `Test-SqlRestoreChain` as a self-contained HTML recoverability
report — a single file with no external CSS, JavaScript, or network dependencies, so it
renders identically offline and survives being emailed as an attachment. Useful for handing
recoverability status to auditors or management. Presentation only: it makes no server
connections and changes nothing.

```powershell
# Check every database and write a report
Test-SqlRestoreChain -SqlInstance sql01 |
    Export-SqlReliabilityReport -Path .\recoverability.html

# Title it, audit against a 4-hour RPO, and open it
Test-SqlRestoreChain -SqlInstance sql01 -MaxRpoHours 4 |
    Export-SqlReliabilityReport -Path .\dr-audit.html -Title 'Quarterly DR Audit' -PassThru |
    Invoke-Item
```

## Roadmap

Planned commands, drawn from production reliability tooling:

- `Find-SqlBackupAnomaly` — flag unusual backup behavior (size, timing, frequency deviations)

## License

MIT — see [LICENSE](LICENSE).
