# SqlReliabilityKit — testing & deploy notes

## Before you publish, run locally
```powershell
Install-Module dbatools -MinimumVersion 2.0.0 -Scope CurrentUser
Install-Module Pester   -MinimumVersion 5.0.0 -Scope CurrentUser -SkipPublisherCheck
Test-ModuleManifest .\SqlReliabilityKit.psd1
Invoke-Pester .\Tests
Import-Module .\SqlReliabilityKit.psd1 -Force
```

## Publish to PowerShell Gallery
1. Get an API key: powershellgallery.com -> account -> API Keys
2. Repo -> Settings -> Secrets and variables -> Actions -> add secret PSGALLERY_API_KEY
3. Bump ModuleVersion in the manifest, commit, then:
   git tag v0.6.0 && git push --tags
   (the workflow guard fails if the tag != manifest version)

## Report usage
Test-SqlRestoreChain -SqlInstance sql01 -MaxRpoHours 4 |
    Export-SqlReliabilityReport -Path .\dr-audit.html -Title 'Quarterly DR Audit' -PassThru | Invoke-Item

## KNOWN — not yet fixed (do these before a real release)
- Test-SqlRestoreChain logical mode still uses date comparison, not LSN continuity;
  it can report a broken log chain as healthy. Fix before publishing.
- Find-SqlQueryStoreRegression PlanChanged flag and baseline execution floor still pending.
- Reconcile README version (says v0.1.0) with manifest (0.6.0).
- The HTML report reflects whatever Test-SqlRestoreChain concludes; if you rename its
  output properties during the LSN fix, update Export-SqlReliabilityReport to match.
