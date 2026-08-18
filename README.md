# SqlReliabilityKit

A free, open-source (MIT) PowerShell module for SQL Server **reliability engineering** — backup recoverability, restore-chain validation, disaster-recovery drift detection, backup anomaly detection, and Query Store regression analysis. Built on top of [dbatools](https://dbatools.io).

> Status: early / active development (v0.1.0). Feedback and issues welcome.

## Why this module

dbatools is superb for general SQL Server administration. SqlReliabilityKit focuses on a narrower theme — **is this estate actually recoverable, and is its performance drifting?** — packaging techniques that DBAs otherwise script by hand around backup, restore, DR, and Query Store.

## Requirements

- PowerShell 5.1+ (Windows) or PowerShell 7+
- [dbatools](https://dbatools.io) 2.0.0+ (`Install-Module dbatools`)
- SQL Server 2016+ for Query Store features

## Install

```powershell
# From source (until published to the PowerShell Gallery)
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

Validates that a **recoverable backup chain** exists for one or more databases. By default it
reads backup history from msdb and confirms a complete full → differential → log chain,
reports the current **RPO gap** (time since the last restorable backup), and flags any break
or staleness — without touching the data.

With `-Physical`, it goes further: it restores the chain to a temporary test database, runs
`DBCC CHECKDB`, reports pass/fail with duration, and drops the test copy — an auditable proof
of recoverability rather than a paper check.

```powershell
# Logical check: is the Sales chain complete, and how old is the last restorable point?
Test-SqlRestoreChain -SqlInstance sql01 -Database Sales

# Flag any user database whose last restorable backup is more than 4 hours old
Test-SqlRestoreChain -SqlInstance sql01 -MaxRpoHours 4

# Prove it: actually restore Sales to a test DB and run DBCC CHECKDB
Test-SqlRestoreChain -SqlInstance sql01 -Database Sales -Physical

# Only databases with a broken or stale chain
Test-SqlRestoreChain -SqlInstance sql01 | Where-Object { -not $_.ChainHealthy }
```

## Roadmap

Planned commands, drawn from production reliability tooling:

- `Test-SqlBackupRecoverability` — automated backup recoverability testing across a fleet
- `Get-SqlDrDrift` — detect configuration drift between primary and DR replicas
- `Find-SqlBackupAnomaly` — flag unusual backup behavior (size, timing, frequency deviations)

## License

MIT — see [LICENSE](LICENSE).
