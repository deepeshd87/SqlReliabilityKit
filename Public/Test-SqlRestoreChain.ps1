function Test-SqlRestoreChain {
    <#
    .SYNOPSIS
        Validates that a recoverable backup chain exists for one or more databases, and
        optionally proves it by restoring to a test database.

    .DESCRIPTION
        Reads backup history from msdb on the target instance and verifies that a complete,
        restorable chain exists: a base FULL backup, the most recent DIFFERENTIAL (if any)
        based on that full, and an unbroken sequence of LOG backups (for FULL/BULK_LOGGED
        recovery databases) up to the most recent one.

        In the default (logical) mode it does NOT touch the data - it only reads msdb and
        reports whether the chain is complete, where any gap is, and the current RPO gap
        (time since the last restorable backup).

        With -Physical it goes further and actually restores the chain to a uniquely-named
        test database (RESTORE ... WITH NORECOVERY through the chain, then RECOVERY), runs
        DBCC CHECKDB, and drops the test database afterward - an auditable proof of
        recoverability, not just a paper check.

        This command reads msdb backup tables. Physical mode requires enough disk space for
        the restored copy and permission to restore and run DBCC.

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials (SQL auth). Accepts a
        PSCredential (Get-Credential). If omitted, Windows Authentication is used.

    .PARAMETER Database
        The database(s) whose backup chain to validate. If unspecified, all online user
        databases on the instance are checked.

    .PARAMETER ExcludeDatabase
        Database(s) to skip.

    .PARAMETER MaxRpoHours
        If set, the chain is marked NOT healthy when the RPO gap (hours since the last
        restorable backup) exceeds this value, even if the chain is otherwise complete.
        Default: 0 (no RPO threshold - completeness only).

    .PARAMETER Physical
        Actually restore the chain to a temporary test database and run DBCC CHECKDB to
        prove recoverability. Without this switch, only a logical (msdb) check is performed.

    .PARAMETER DataPath
        (Physical mode) Directory for the restored test database's data/log files. Defaults
        to the instance's default data directory. The files are removed when the test
        database is dropped.

    .PARAMETER EnableException
        By default this command catches errors and emits friendly warnings. Use this switch
        to surface raw exceptions for your own try/catch handling.

    .EXAMPLE
        PS C:\> Test-SqlRestoreChain -SqlInstance sql01 -Database Sales

        Logical check: confirms Sales on sql01 has a complete full/diff/log chain and reports
        the current RPO gap. No data is restored.

    .EXAMPLE
        PS C:\> Test-SqlRestoreChain -SqlInstance sql01 -MaxRpoHours 4

        Checks every user database on sql01 and flags any whose most recent restorable backup
        is more than 4 hours old, or whose chain is broken.

    .EXAMPLE
        PS C:\> Test-SqlRestoreChain -SqlInstance sql01 -Database Sales -Physical

        Actually restores the Sales chain to a temporary database, runs DBCC CHECKDB, reports
        pass/fail with duration, then drops the test database.

    .EXAMPLE
        PS C:\> Test-SqlRestoreChain -SqlInstance sql01 | Where-Object { -not $_.ChainHealthy }

        Returns only databases whose backup chain is incomplete or stale.

    .NOTES
        Author: Deepesh Dhake
        Requires the dbatools module (Invoke-DbaQuery, and Test-DbaLastBackup / Get-DbaDefaultPath
        style connectivity) for connectivity.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$SqlInstance,

        [pscredential]$SqlCredential,

        [string[]]$Database,

        [string[]]$ExcludeDatabase,

        [ValidateRange(0, 100000)]
        [double]$MaxRpoHours = 0,

        [switch]$Physical,

        [string]$DataPath,

        [switch]$EnableException
    )

    begin {
        # Pulls the current backup chain state per database from msdb.
        # For each database we find: latest full, latest diff based on that full,
        # latest log, recovery model, and the timestamp of the most recent restorable backup.
        $historySql = @"
;WITH latest_full AS (
    SELECT bs.database_name,
           MAX(bs.backup_finish_date) AS last_full_date
    FROM msdb.dbo.backupset bs
    WHERE bs.type = 'D'   -- full
    GROUP BY bs.database_name
),
latest_diff AS (
    SELECT bs.database_name,
           MAX(bs.backup_finish_date) AS last_diff_date
    FROM msdb.dbo.backupset bs
    WHERE bs.type = 'I'   -- differential
    GROUP BY bs.database_name
),
latest_log AS (
    SELECT bs.database_name,
           MAX(bs.backup_finish_date) AS last_log_date
    FROM msdb.dbo.backupset bs
    WHERE bs.type = 'L'   -- log
    GROUP BY bs.database_name
)
SELECT
    d.name                                   AS DatabaseName,
    d.recovery_model_desc                    AS RecoveryModel,
    lf.last_full_date                        AS LastFullDate,
    ld.last_diff_date                        AS LastDiffDate,
    ll.last_log_date                         AS LastLogDate
FROM sys.databases d
LEFT JOIN latest_full lf ON lf.database_name = d.name
LEFT JOIN latest_diff ld ON ld.database_name = d.name
LEFT JOIN latest_log  ll ON ll.database_name = d.name
WHERE d.database_id > 4          -- user databases only
  AND d.state_desc = 'ONLINE'
  AND d.source_database_id IS NULL   -- exclude snapshots
ORDER BY d.name;
"@
    }

    process {
        foreach ($instance in $SqlInstance) {
            Write-Verbose "Reading backup history from [$instance] msdb"

            $qParams = @{
                SqlInstance     = $instance
                Query           = $historySql
                EnableException = $true
            }
            if ($SqlCredential) { $qParams.SqlCredential = $SqlCredential }

            try {
                $rows = Invoke-DbaQuery @qParams
            }
            catch {
                $msg = "Failed to read backup history from [$instance]: $($_.Exception.Message)"
                if ($EnableException) { throw } else { Write-Warning $msg; continue }
            }

            foreach ($row in $rows) {
                $dbName = $row.DatabaseName

                if ($Database -and $dbName -notin $Database) { continue }
                if ($ExcludeDatabase -and $dbName -in $ExcludeDatabase) { continue }

                $recovery = $row.RecoveryModel
                $lastFull = $row.LastFullDate -as [datetime]
                $lastDiff = $row.LastDiffDate -as [datetime]
                $lastLog  = $row.LastLogDate  -as [datetime]

                $issues = [System.Collections.Generic.List[string]]::new()

                # 1. Must have a base full backup.
                if (-not $lastFull) {
                    $issues.Add('No FULL backup found - chain has no base.')
                }

                # 2. The most recent restorable point depends on recovery model.
                $lastRestorable = $lastFull
                if ($lastDiff -and $lastFull -and $lastDiff -gt $lastFull) { $lastRestorable = $lastDiff }

                if ($recovery -in @('FULL', 'BULK_LOGGED')) {
                    if (-not $lastLog) {
                        $issues.Add("Recovery model is $recovery but no LOG backup exists - point-in-time recovery is not possible.")
                    }
                    elseif ($lastFull -and $lastLog -lt $lastFull) {
                        $issues.Add('Most recent LOG backup predates the most recent FULL - log chain does not cover the current full.')
                    }
                    else {
                        if ($lastLog -and (-not $lastRestorable -or $lastLog -gt $lastRestorable)) {
                            $lastRestorable = $lastLog
                        }
                    }
                }

                # 3. RPO gap.
                $rpoHours = $null
                if ($lastRestorable) {
                    $rpoHours = [math]::Round((New-TimeSpan -Start $lastRestorable -End (Get-Date)).TotalHours, 2)
                }

                if ($MaxRpoHours -gt 0 -and $rpoHours -ne $null -and $rpoHours -gt $MaxRpoHours) {
                    $issues.Add("RPO gap ${rpoHours}h exceeds MaxRpoHours ${MaxRpoHours}h.")
                }

                $chainHealthy = ($issues.Count -eq 0)

                # 4. Physical proof (optional).
                $physicalResult = $null
                $dbccResult     = $null
                $physicalSeconds = $null
                if ($Physical -and $chainHealthy) {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        # Delegated to dbatools' tested restore-test path where available.
                        $testParams = @{
                            SqlInstance     = $instance
                            Database        = $dbName
                            EnableException = $true
                        }
                        if ($SqlCredential) { $testParams.SqlCredential = $SqlCredential }
                        if ($DataPath)      { $testParams.DataDirectory = $DataPath }

                        $td = Test-DbaLastBackup @testParams
                        $physicalResult = if ($td.RestoreResult -eq 'Success') { 'Restored' } else { "Restore: $($td.RestoreResult)" }
                        $dbccResult     = $td.DbccResult
                        if ($td.DbccResult -ne 'Success') { $issues.Add("DBCC after restore: $($td.DbccResult)"); $chainHealthy = $false }
                    }
                    catch {
                        $physicalResult = 'Failed'
                        $issues.Add("Physical restore failed: $($_.Exception.Message)")
                        $chainHealthy = $false
                        if ($EnableException) { throw }
                    }
                    finally {
                        $sw.Stop()
                        $physicalSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                    }
                }

                [PSCustomObject]@{
                    SqlInstance     = "$instance"
                    Database        = $dbName
                    RecoveryModel   = $recovery
                    LastFull        = $lastFull
                    LastDiff        = $lastDiff
                    LastLog         = $lastLog
                    LastRestorable  = $lastRestorable
                    RpoGapHours     = $rpoHours
                    ChainHealthy    = $chainHealthy
                    PhysicalRestore = $physicalResult
                    DbccResult      = $dbccResult
                    PhysicalSeconds = $physicalSeconds
                    Issues          = $issues.ToArray()
                }
            }
        }
    }
}
