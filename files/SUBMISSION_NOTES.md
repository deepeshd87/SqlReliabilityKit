# Submitting Find-DbaDbQueryStoreRegression to dbatools

This is the **dbatools contribution** — a single command intended to live *inside* the
`dataplat/dbatools` repository. It is separate from your own SqlReliabilityKit module.
(niphlod, a core maintainer, approved the concept and the `Find-` verb in Slack.)

## Files

- `functions/Find-DbaDbQueryStoreRegression.ps1` — the command, written to dbatools conventions
  (Connect-DbaInstance, Get-DbaDatabase, Write-Message, Stop-Function, Select-DefaultView,
  standard ComputerName/InstanceName/SqlInstance output properties).
- `tests/Find-DbaDbQueryStoreRegression.Tests.ps1` — Pester v5 test matching their current
  template (parameter-validation unit test + a skipped integration test stub).

## Steps

1. **Fork and clone** `dataplat/dbatools`. Check out the **`development`** branch (PRs target
   development, not master).
   ```
   git checkout development
   git checkout -b find-dbadbquerystoreregression
   ```

2. **Copy the two files** into the matching folders in your clone:
   - `functions/Find-DbaDbQueryStoreRegression.ps1`
   - `tests/Find-DbaDbQueryStoreRegression.Tests.ps1`

3. **Import the module locally and smoke-test** against a real SQL 2016+ instance with Query
   Store enabled:
   ```
   Import-Module ./dbatools.psd1 -Force
   Find-DbaDbQueryStoreRegression -SqlInstance yourtestinstance -Database YourDb -Verbose
   ```
   Confirm the output properties populate and the default view shows the columns you expect.

4. **Run PSScriptAnalyzer** with their settings (CI will reject on violations):
   ```
   Invoke-ScriptAnalyzer -Path ./functions/Find-DbaDbQueryStoreRegression.ps1
   ```

5. **Run the unit test:**
   ```
   Invoke-Pester ./tests/Find-DbaDbQueryStoreRegression.Tests.ps1 -Tag UnitTests
   ```
   The parameter-count test enforces that the declared parameters exactly match the test list —
   if you add/remove a parameter, update both.

6. **Verify against a current dbatools function** before submitting. The framework helpers
   (Select-DefaultView usage, the exact Connect-DbaInstance signature, the test config object)
   occasionally change. Open a recent Query Store command in the repo
   (e.g. `Get-DbaDbQueryStoreOption.ps1`) and confirm your patterns still match.

7. **Commit, push, open the PR** against `development`. In the PR description, reference the
   Slack conversation where niphlod approved the concept and the `Find-` verb.

8. **Respond to review.** Expect small requested changes — that's normal. Maintainers may tweak
   output properties, help wording, or test structure.

## Likely review points to pre-empt

- **`MinimumVersion 13`** on Connect-DbaInstance restricts to SQL 2016+ (Query Store's floor).
  Confirm that's how they gate version-specific features elsewhere.
- **Reading `$db.QueryStoreOptions.ActualState`** to skip Query Store-disabled DBs — verify the
  SMO property path against their existing Query Store commands.
- **Inlined parameters in the T-SQL** (via string expansion) rather than SqlParameter objects.
  The values are all numeric and range-bounded, so injection isn't a risk, but a maintainer may
  prefer parameterized queries — be ready to switch to `$db.Query($sql, $params)` if asked.
