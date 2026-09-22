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

        [ValidateSet('Duration', 'CpuTime', 'LogicalReads')]
        [string]$Metric = 'Duration',

        [ValidateRange(1.0, 1000.0)]
        [double]$SlowdownThreshold = 1.5,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinExecutionCount = 20,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinBaselineExecutionCount = 20,

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

        # Map the chosen metric to its Query Store column, its unit, the divisor that turns
        # the raw stored value into the reported unit, and the output-column suffix. Duration
        # and CPU are stored in microseconds (report as ms, divide by 1000); logical reads is
        # a page COUNT (no unit conversion - divide by 1). Getting this right matters: dividing
        # a read count by 1000 would silently report nonsense.
        $metricMap = @{
            'Duration'     = @{ Column = 'avg_duration';         Divisor = 1000.0; Suffix = 'Ms';    TotalFloorColumn = $true }
            'CpuTime'      = @{ Column = 'avg_cpu_time';         Divisor = 1000.0; Suffix = 'Ms';    TotalFloorColumn = $false }
            'LogicalReads' = @{ Column = 'avg_logical_io_reads'; Divisor = 1.0;    Suffix = 'Reads'; TotalFloorColumn = $false }
        }
        $m           = $metricMap[$Metric]
        $metricCol   = $m.Column
        $metricDiv   = $m.Divisor
        $metricSuffix = $m.Suffix

        # The MinTotalDurationMs floor is a duration concept (total microseconds of runtime).
        # It only makes sense when the metric IS Duration; for CPU or reads, a microsecond floor
        # against a different unit would be nonsense, so we omit the clause entirely for those.
        # This keeps v1 unambiguous - the total-impact filter applies to Duration only.
        if ($m.TotalFloorColumn) {
            $totalFloorClause = '  AND c.current_total_metric > @minTotalDurationUs'
        } else {
            $totalFloorClause = ''
        }

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
        SUM(rs.$metricCol * rs.count_executions) * 1.0
            / NULLIF(SUM(rs.count_executions), 0) AS baseline_metric,
        SUM(rs.count_executions)                  AS baseline_exec_count
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
        SUM(rs.$metricCol * rs.count_executions) * 1.0
            / NULLIF(SUM(rs.count_executions), 0) AS current_metric,
        SUM(rs.count_executions)                  AS current_exec_count,
        SUM(rs.$metricCol * rs.count_executions)  AS current_total_metric
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_plan  p ON rs.plan_id  = p.plan_id
    JOIN sys.query_store_query q ON p.query_id  = q.query_id
    WHERE rs.last_execution_time >= @CurrentStart
    GROUP BY q.query_id
),
-- Distinct plan_ids actually executed in each window.
baseline_plans AS (
    SELECT DISTINCT q.query_id, rs.plan_id
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_plan  p ON rs.plan_id  = p.plan_id
    JOIN sys.query_store_query q ON p.query_id  = q.query_id
    WHERE rs.last_execution_time >= @BaselineStart
      AND rs.last_execution_time <  @BaselineEnd
),
current_plans AS (
    SELECT DISTINCT q.query_id, rs.plan_id
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_plan  p ON rs.plan_id  = p.plan_id
    JOIN sys.query_store_query q ON p.query_id  = q.query_id
    WHERE rs.last_execution_time >= @CurrentStart
),
-- A real plan change: a plan_id running NOW that was NOT running in the baseline.
-- Count-of-plans is not enough (a query may always run under several stable plans);
-- what signals a change is a genuinely new plan appearing in the current window.
new_plans AS (
    SELECT cp.query_id, COUNT(*) AS new_plan_count
    FROM current_plans cp
    WHERE NOT EXISTS (
        SELECT 1 FROM baseline_plans bp
        WHERE bp.query_id = cp.query_id
          AND bp.plan_id  = cp.plan_id
    )
    GROUP BY cp.query_id
)
SELECT
    c.query_id                                                    AS QueryId,
    CAST(b.baseline_metric / $metricDiv AS DECIMAL(18,2))         AS Baseline$metricSuffix,
    CAST(c.current_metric  / $metricDiv AS DECIMAL(18,2))         AS Current$metricSuffix,
    CAST(c.current_metric * 1.0
        / NULLIF(b.baseline_metric, 0) AS DECIMAL(10,2))          AS SlowdownFactor,
    b.baseline_exec_count                                         AS BaselineExecCount,
    c.current_exec_count                                          AS CurrentExecCount,
    CASE WHEN np.new_plan_count > 0
         THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END              AS PlanChanged
FROM current_perf c
JOIN baseline b
    ON c.query_id = b.query_id
LEFT JOIN new_plans np
    ON np.query_id = c.query_id
WHERE c.current_metric        > b.baseline_metric * @SlowdownThreshold
  AND c.current_exec_count    > @MinExecutionCount
  AND b.baseline_exec_count   > @MinBaselineExecutionCount
$totalFloorClause
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
                        SlowdownThreshold        = $SlowdownThreshold
                        MinExecutionCount        = $MinExecutionCount
                        MinBaselineExecutionCount = $MinBaselineExecutionCount
                        minTotalDurationUs       = $minTotalDurationUs
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

                # Output columns carry a metric-specific suffix in SQL (Baseline$metricSuffix),
                # but we surface STABLE property names so a pipeline consuming this doesn't break
                # when -Metric changes. The Metric and Unit columns say which metric these numbers
                # describe. 'Ms' -> milliseconds; 'Reads' -> logical page reads.
                $baselineProp = "Baseline$metricSuffix"
                $currentProp  = "Current$metricSuffix"
                $unit = if ($metricSuffix -eq 'Ms') { 'ms' } else { 'reads' }

                foreach ($row in $rows) {
                    $out = [ordered]@{
                        SqlInstance       = "$instance"
                        Database          = $db
                        QueryId           = $row.QueryId
                        Metric            = $Metric
                        Unit              = $unit
                        BaselineValue     = $row.$baselineProp
                        CurrentValue      = $row.$currentProp
                        SlowdownFactor    = $row.SlowdownFactor
                        PlanChanged       = [bool]$row.PlanChanged
                        BaselineExecCount = $row.BaselineExecCount
                        CurrentExecCount  = $row.CurrentExecCount
                    }

                    # Backward compatibility: prior versions exposed BaselineDurationMs /
                    # CurrentDurationMs. Those names were duration-specific, so we keep emitting
                    # them ONLY for -Metric Duration, alongside the new metric-agnostic columns.
                    # Scripts and docs written against the old names keep working; CpuTime and
                    # LogicalReads runs don't carry them (they never applied to those metrics).
                    if ($Metric -eq 'Duration') {
                        $out.BaselineDurationMs = $row.$baselineProp
                        $out.CurrentDurationMs  = $row.$currentProp
                    }

                    [PSCustomObject]$out
                }
            }
        }
    }
}
