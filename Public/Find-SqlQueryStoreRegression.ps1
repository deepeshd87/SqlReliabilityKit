function Find-SqlQueryStoreRegression {
    <#
    .SYNOPSIS
        Detects query performance regressions in SQL Server using Query Store runtime statistics.

    .DESCRIPTION
        Reads sys.query_store_runtime_stats and identifies queries whose recent performance
        has regressed against a historical baseline.

        Rather than a naive "yesterday vs today average" comparison, this command uses an
        execution-weighted baseline: each plan's historical duration is weighted by execution
        count, and low-frequency / low-total-impact queries are filtered out so that genuine
        regressions surface instead of noise from a handful of slow one-off executions.

        The command is read-only. It queries Query Store DMVs and returns objects; it does not
        force plans, change configuration, or modify any data.

        Requires Query Store to be enabled on the target database(s) (SQL Server 2016+).

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials (SQL auth). Accepts a
        PSCredential object (Get-Credential). If omitted, Windows Authentication is used.

    .PARAMETER Database
        The database(s) to analyze. If unspecified, an error is thrown - Query Store is a
        per-database feature, so a database must be named.

    .PARAMETER BaselineStart
        Start of the historical baseline window, expressed as a number of WindowUnit (days or
        hours) before now. Default: 7.

    .PARAMETER BaselineEnd
        End of the historical baseline window, in WindowUnit before now. Default: 1. The
        baseline window is BaselineStart..BaselineEnd, and the current window is BaselineEnd..now.
        (Default: baseline = 7 days ago through 1 day ago; current = the last 1 day.)

    .PARAMETER WindowUnit
        The unit for BaselineStart and BaselineEnd: 'Day' (default), 'Hour', or 'Minute'. Use
        'Hour' or 'Minute' for short-window analysis - catching a regression that started earlier
        today, or validating against freshly generated Query Store data.

    .PARAMETER SlowdownThreshold
        Minimum ratio of current duration to baseline duration for a query to be flagged.
        Default: 1.5 (50% slower). A value of 2.0 flags only queries that doubled.

    .PARAMETER MinExecutionCount
        Minimum number of executions in the current window for a query to be considered.
        Filters out infrequently-run queries. Default: 20.

    .PARAMETER MinTotalDurationMs
        Minimum total current duration (milliseconds, summed across executions) for a query
        to be considered. Filters out queries that are individually slow but negligible to the
        overall workload. Default: 100 (i.e. 100 ms = 100000 microseconds).

    .PARAMETER TrustServerCertificate
        Bypasses the certificate chain validation when connecting. Use this when the target
        instance presents a self-signed certificate (a common cause of "the certificate chain
        was issued by an authority that is not trusted" errors). Passed through to dbatools.

    .PARAMETER EnableException
        By default this command catches and translates errors into friendly warnings. Use this
        switch to turn that off and surface raw exceptions for your own try/catch handling.

    .EXAMPLE
        PS C:\> Find-SqlQueryStoreRegression -SqlInstance sql01 -Database AdventureWorks

        Finds queries in AdventureWorks on sql01 that ran at least 50% slower in the last day
        versus the prior 7-to-1-day baseline, considering only queries run 20+ times.

    .EXAMPLE
        PS C:\> Find-SqlQueryStoreRegression -SqlInstance sql01 -Database Sales -SlowdownThreshold 2.0 -MinExecutionCount 50

        Only flags queries in Sales that at least doubled in duration and ran 50+ times.

    .EXAMPLE
        PS C:\> Find-SqlQueryStoreRegression -SqlInstance sql01 -Database Sales |
                Sort-Object SlowdownFactor -Descending | Select-Object -First 10

        Returns the ten worst regressions by slowdown factor.

    .NOTES
        Author: Deepesh Dhake
        Underlying technique described at:
        https://dzone.com/articles/sql-server-query-store-regression

        Requires the dbatools module (Invoke-DbaQuery) for connectivity.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$SqlInstance,

        [pscredential]$SqlCredential,

        [Parameter(Mandatory)]
        [string[]]$Database,

        [ValidateRange(1, 3650)]
        [int]$BaselineStart = 7,

        [ValidateRange(0, 3649)]
        [int]$BaselineEnd = 1,

        [ValidateSet('Day', 'Hour', 'Minute')]
        [string]$WindowUnit = 'Day',

        [ValidateRange(1.0, 1000.0)]
        [double]$SlowdownThreshold = 1.5,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinExecutionCount = 20,

        [ValidateRange(0, [long]::MaxValue)]
        [long]$MinTotalDurationMs = 100,

        [switch]$TrustServerCertificate,

        [switch]$EnableException
    )

    begin {
        if ($BaselineEnd -ge $BaselineStart) {
            $msg = "BaselineEnd ($BaselineEnd) must be smaller than BaselineStart ($BaselineStart). The baseline is the OLDER window."
            if ($EnableException) { throw $msg } else { Write-Warning $msg; return }
        }

        # Query Store stores durations in microseconds. Convert the ms floor to us.
        $minTotalDurationUs = $MinTotalDurationMs * 1000

        # DATEADD unit: 'day', 'hour', or 'minute' depending on WindowUnit.
        $dateUnit = switch ($WindowUnit) {
            'Hour'   { 'hour' }
            'Minute' { 'minute' }
            default  { 'day' }
        }

        # Parameterized T-SQL. Windows are computed server-side from the offsets.
        # Regression is measured at the QUERY level: each query's executions are aggregated
        # across ALL its plans within a window (weighted by execution count). This catches
        # plan-flip regressions - the common case where a query's performance degrades because
        # the optimizer switched to a worse plan - which a plan-level comparison would miss.
        $sql = @"
DECLARE @BaselineStart datetimeoffset = DATEADD($dateUnit, -@BaselineStartOffset, SYSDATETIMEOFFSET());
DECLARE @BaselineEnd   datetimeoffset = DATEADD($dateUnit, -@BaselineEndOffset,   SYSDATETIMEOFFSET());
DECLARE @CurrentStart  datetimeoffset = @BaselineEnd;

WITH baseline AS (
    SELECT
        q.query_id,
        SUM(rs.avg_duration * rs.count_executions) * 1.0
            / NULLIF(SUM(rs.count_executions), 0) AS baseline_duration,
        SUM(rs.count_executions)                  AS baseline_exec_count,
        COUNT(DISTINCT p.plan_id)                 AS baseline_plan_count
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_plan  p ON rs.plan_id  = p.plan_id
    JOIN sys.query_store_query q ON p.query_id  = q.query_id
    WHERE rs.last_execution_time >= @BaselineStart
      AND rs.last_execution_time <  @BaselineEnd
    GROUP BY q.query_id
),
current_perf AS (
    SELECT
        q.query_id,
        SUM(rs.avg_duration * rs.count_executions) * 1.0
            / NULLIF(SUM(rs.count_executions), 0) AS current_duration,
        SUM(rs.count_executions)                  AS current_exec_count,
        SUM(rs.avg_duration * rs.count_executions) AS current_total_duration,
        COUNT(DISTINCT p.plan_id)                 AS current_plan_count
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_plan  p ON rs.plan_id  = p.plan_id
    JOIN sys.query_store_query q ON p.query_id  = q.query_id
    WHERE rs.last_execution_time >= @CurrentStart
    GROUP BY q.query_id
)
SELECT
    c.query_id                                                    AS QueryId,
    CAST(b.baseline_duration / 1000.0 AS DECIMAL(18,2))           AS BaselineDurationMs,
    CAST(c.current_duration  / 1000.0 AS DECIMAL(18,2))           AS CurrentDurationMs,
    CAST(c.current_duration * 1.0
        / NULLIF(b.baseline_duration, 0) AS DECIMAL(10,2))        AS SlowdownFactor,
    b.baseline_exec_count                                         AS BaselineExecCount,
    c.current_exec_count                                          AS CurrentExecCount,
    CASE WHEN c.current_plan_count > b.baseline_plan_count OR c.current_plan_count > 1
         THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END              AS PlanChanged
FROM current_perf c
JOIN baseline b
    ON c.query_id = b.query_id
WHERE c.current_duration     > b.baseline_duration * @SlowdownThreshold
  AND c.current_exec_count   > @MinExecutionCount
  AND c.current_total_duration > @minTotalDurationUs
ORDER BY SlowdownFactor DESC;
"@
    }

    process {
        foreach ($instance in $SqlInstance) {
            # Establish the connection once per instance. Trust settings (for self-signed
            # certificates) are applied here, at connection time, then the connection is
            # reused for each database query.
            $connectParams = @{ SqlInstance = $instance }
            if ($SqlCredential) { $connectParams.SqlCredential = $SqlCredential }
            if ($TrustServerCertificate) { $connectParams.TrustServerCertificate = $true }

            try {
                $server = Connect-DbaInstance @connectParams -ErrorAction Stop
            }
            catch {
                $msg = "Failed to connect to [$instance]: $($_.Exception.Message)"
                if ($EnableException) { throw } else { Write-Warning $msg; continue }
            }

            foreach ($db in $Database) {
                Write-Verbose "Analyzing Query Store on [$instance].[$db]"

                $params = @{
                    SqlInstance = $server
                    Database    = $db
                    Query       = $sql
                    SqlParameter = @{
                        BaselineStartOffset = $BaselineStart
                        BaselineEndOffset   = $BaselineEnd
                        SlowdownThreshold    = $SlowdownThreshold
                        MinExecutionCount    = $MinExecutionCount
                        minTotalDurationUs   = $minTotalDurationUs
                    }
                    EnableException = $true
                }

                try {
                    $rows = Invoke-DbaQuery @params
                }
                catch {
                    $msg = "Failed to analyze Query Store on [$instance].[$db]: $($_.Exception.Message)"
                    if ($EnableException) { throw } else { Write-Warning $msg; continue }
                }

                foreach ($row in $rows) {
                    [PSCustomObject]@{
                        SqlInstance       = "$instance"
                        Database          = $db
                        QueryId           = $row.QueryId
                        BaselineDurationMs = $row.BaselineDurationMs
                        CurrentDurationMs  = $row.CurrentDurationMs
                        SlowdownFactor     = $row.SlowdownFactor
                        PlanChanged        = [bool]$row.PlanChanged
                        BaselineExecCount  = $row.BaselineExecCount
                        CurrentExecCount   = $row.CurrentExecCount
                    }
                }
            }
        }
    }
}
