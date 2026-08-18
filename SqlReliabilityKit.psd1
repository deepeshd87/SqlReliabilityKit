@{
    RootModule        = 'SqlReliabilityKit.psm1'
    ModuleVersion     = '0.5.2'
    GUID              = '0f3c9a2e-8b1d-4c7a-9e2f-1a6b5d4c3e2f'
    Author            = 'Deepesh Dhake'
    CompanyName       = 'Deepesh Dhake'
    Copyright         = '(c) 2026 Deepesh Dhake. MIT License.'
    Description       = 'A SQL Server reliability toolkit: backup recoverability, restore-chain validation, disaster-recovery drift detection, backup anomaly detection, and Query Store regression analysis. Built on dbatools.'
    PowerShellVersion = '5.1'

    # dbatools provides connectivity (Invoke-DbaQuery) used by the commands.
    RequiredModules   = @(
        @{ ModuleName = 'dbatools'; ModuleVersion = '2.0.0' }
    )

    # Explicit export list - keep in sync with Public/*.ps1
    FunctionsToExport = @(
        'Find-SqlQueryStoreRegression',
        'Test-SqlRestoreChain'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SQLServer', 'dbatools', 'DBA', 'QueryStore', 'Backup', 'DisasterRecovery', 'Reliability', 'Windows')
            LicenseUri = 'https://github.com/deepeshd87/SqlReliabilityKit/blob/main/LICENSE'
            ProjectUri = 'https://github.com/deepeshd87/SqlReliabilityKit'
            ReleaseNotes = '0.5.2 - Physical mode now sets dbatools session trust config automatically when -TrustServerCertificate is used, covering the internal restore-target connection, and restores the prior value afterward. 0.5.1 - Fix: physical mode passes the connected server object to Test-DbaLastBackup (it does not accept TrustServerCertificate directly). 0.5.0 - Detect regressions at the QUERY level (aggregate across plans), catching plan-flip regressions that plan-level comparison missed. Adds PlanChanged output, removes PlanId. 0.4.1 - Add Minute to WindowUnit for very-short-window analysis. 0.4.0 - Add -WindowUnit (Day/Hour) for short-window regression analysis; rename BaselineStartDaysAgo/BaselineEndDaysAgo to BaselineStart/BaselineEnd. 0.3.2 - Fix: remove EnableException from Connect-DbaInstance call, use ErrorAction Stop for reliable error handling across dbatools versions. 0.3.1 - Fix: apply TrustServerCertificate at connection time via Connect-DbaInstance (Invoke-DbaQuery does not accept it directly). 0.3.0 - Adds -TrustServerCertificate to both commands for self-signed cert connections. 0.2.0 - Adds Test-SqlRestoreChain (backup chain validation with logical and physical/DBCC modes). 0.1.0 - Find-SqlQueryStoreRegression (execution-weighted Query Store regression detection).'
        }
    }
}
