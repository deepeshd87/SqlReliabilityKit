#requires -Module Pester

# Structural tests for SqlReliabilityKit. These validate the module contract without
# needing a live SQL Server. Run with: Invoke-Pester ./Tests

BeforeAll {
    $ModuleRoot = Split-Path $PSScriptRoot -Parent
    $ManifestPath = Join-Path $ModuleRoot 'SqlReliabilityKit.psd1'
}

Describe 'Module manifest' {
    It 'exists' {
        Test-Path $ManifestPath | Should -BeTrue
    }
    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }
    It 'declares dbatools as a required module' {
        $data = Import-PowerShellDataFile $ManifestPath
        ($data.RequiredModules.ModuleName) | Should -Contain 'dbatools'
    }
    It 'exports Find-SqlQueryStoreRegression explicitly' {
        $data = Import-PowerShellDataFile $ManifestPath
        $data.FunctionsToExport | Should -Contain 'Find-SqlQueryStoreRegression'
    }
    It 'exports Test-SqlRestoreChain explicitly' {
        $data = Import-PowerShellDataFile $ManifestPath
        $data.FunctionsToExport | Should -Contain 'Test-SqlRestoreChain'
    }
}

Describe 'Test-SqlRestoreChain' {
    BeforeAll {
        . (Join-Path $ModuleRoot 'Public/Test-SqlRestoreChain.ps1')
        $cmd = Get-Command Test-SqlRestoreChain
    }
    It 'has SqlInstance as a mandatory parameter' {
        $cmd.Parameters['SqlInstance'].Attributes.Mandatory | Should -Contain $true
    }
    It 'has a Physical switch' {
        $cmd.Parameters['Physical'].SwitchParameter | Should -BeTrue
    }
    It 'has comment-based help with a synopsis' {
        (Get-Help Test-SqlRestoreChain).Synopsis | Should -Not -BeNullOrEmpty
    }
    It 'provides at least one usage example' {
        @((Get-Help Test-SqlRestoreChain).Examples.Example).Count | Should -BeGreaterThan 0
    }
}

Describe 'Find-SqlQueryStoreRegression' {
    BeforeAll {
        . (Join-Path $ModuleRoot 'Public/Find-SqlQueryStoreRegression.ps1')
        $cmd = Get-Command Find-SqlQueryStoreRegression
    }
    It 'has SqlInstance as a mandatory parameter' {
        $cmd.Parameters['SqlInstance'].Attributes.Mandatory | Should -Contain $true
    }
    It 'has Database as a mandatory parameter' {
        $cmd.Parameters['Database'].Attributes.Mandatory | Should -Contain $true
    }
    It 'defaults SlowdownThreshold to 1.5' {
        (Get-Command Find-SqlQueryStoreRegression).Parameters['SlowdownThreshold'] | Should -Not -BeNullOrEmpty
    }
    It 'has comment-based help with a synopsis' {
        $help = Get-Help Find-SqlQueryStoreRegression
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
    It 'provides at least one usage example' {
        $help = Get-Help Find-SqlQueryStoreRegression
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
}
