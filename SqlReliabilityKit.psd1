@{
    RootModule        = 'SqlReliabilityKit.psm1'
    ModuleVersion     = '0.6.0'
    GUID              = '0f3c9a2e-8b1d-4c7a-9e2f-1a6b5d4c3e2f'
    Author            = 'Deepesh Dhake'
    CompanyName       = 'Deepesh Dhake'
    Copyright         = '(c) 2026 Deepesh Dhake. MIT License.'
    Description       = 'A SQL Server reliability toolkit: backup recoverability, restore-chain validation, disaster-recovery drift detection, backup anomaly detection, and Query Store regression analysis. Built on dbatools.'
    PowerShellVersion = '5.1'

    # Compatible editions - Desktop (Windows PowerShell 5.1) and Core (PowerShell 7+).
    CompatiblePSEditions = @('Desktop', 'Core')

    # dbatools provides connectivity (Invoke-DbaQuery) used by the commands.
    RequiredModules   = @(
        @{ ModuleName = 'dbatools'; ModuleVersion = '2.0.0' }
    )

    # Explicit export list - keep in sync with Public/*.ps1
    FunctionsToExport = @(
        'Find-SqlQueryStoreRegression',
        'Test-SqlRestoreChain',
        'Export-SqlReliabilityReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('SQLServer', 'dbatools', 'DBA', 'QueryStore', 'Backup', 'DisasterRecovery', 'Reliability', 'Windows', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/deepeshd87/SqlReliabilityKit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/deepeshd87/SqlReliabilityKit'
            ReleaseNotes = 'https://github.com/deepeshd87/SqlReliabilityKit/blob/main/CHANGELOG.md'
        }
    }
}
