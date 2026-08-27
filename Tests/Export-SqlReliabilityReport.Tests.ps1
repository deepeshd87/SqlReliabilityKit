#requires -Module Pester

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:ModuleRoot 'Public/Export-SqlReliabilityReport.ps1')
    $script:Out = Join-Path ([System.IO.Path]::GetTempPath()) ("srk-" + [guid]::NewGuid() + ".html")
}

AfterAll {
    if (Test-Path $script:Out) { Remove-Item $script:Out -Force }
}

Describe 'Export-SqlReliabilityReport' {
    It 'writes a file from piped input' {
        [PSCustomObject]@{ SqlInstance='s'; Database='d'; RecoveryModel='FULL';
            LastRestorable=(Get-Date); RpoGapHours=1.0; ChainHealthy=$true; Issues=@() } |
            Export-SqlReliabilityReport -Path $script:Out
        Test-Path $script:Out | Should -BeTrue
    }

    It 'HTML-encodes values so markup cannot be injected' {
        [PSCustomObject]@{ SqlInstance='s'; Database='A<b>&c'; RecoveryModel='FULL';
            LastRestorable=$null; RpoGapHours=$null; ChainHealthy=$false;
            Issues=@('bad <thing>') } |
            Export-SqlReliabilityReport -Path $script:Out
        $html = Get-Content $script:Out -Raw
        $html | Should -Not -Match 'A<b>&c'
        $html | Should -Match 'A&lt;b&gt;'
    }

    It 'shows an alert banner when any database is unhealthy' {
        [PSCustomObject]@{ SqlInstance='s'; Database='d'; RecoveryModel='FULL';
            ChainHealthy=$false; Issues=@('x') } |
            Export-SqlReliabilityReport -Path $script:Out
        (Get-Content $script:Out -Raw) | Should -Match 'banner-alert'
    }

    It 'returns a FileInfo with -PassThru' {
        $r = [PSCustomObject]@{ SqlInstance='s'; Database='d'; RecoveryModel='FULL';
            ChainHealthy=$true; Issues=@() } |
            Export-SqlReliabilityReport -Path $script:Out -PassThru
        $r | Should -BeOfType [System.IO.FileInfo]
    }

    It 'warns and writes nothing when given no input' {
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("srk-empty-" + [guid]::NewGuid() + ".html")
        @() | Export-SqlReliabilityReport -Path $empty -WarningAction SilentlyContinue
        Test-Path $empty | Should -BeFalse
    }
}
