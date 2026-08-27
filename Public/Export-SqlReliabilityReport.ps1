function Export-SqlReliabilityReport {
    <#
    .SYNOPSIS
        Renders SqlReliabilityKit results as a self-contained HTML report suitable for
        sharing with auditors, managers, or an on-call rotation.

    .DESCRIPTION
        Takes the objects emitted by Test-SqlRestoreChain (piped in or passed via
        -InputObject) and produces a single, standalone .html file - no external CSS,
        JavaScript, or network dependencies, so it renders identically offline and survives
        being emailed as an attachment.

        The report leads with a summary banner (how many databases are healthy vs at risk),
        then a per-database table colour-coded by health, with the specific issues for each
        unhealthy database spelled out. It is a presentation layer only: it performs no SQL
        connections and changes nothing on any server. Run Test-SqlRestoreChain to gather the
        data, pipe it here to render it.

        HTML-encodes all data values, so database names or issue text containing angle
        brackets or ampersands cannot break the markup.

    .PARAMETER InputObject
        The result objects to render, as produced by Test-SqlRestoreChain. Accepts pipeline
        input. Objects that don't look like restore-chain results are rendered on a
        best-effort basis using whatever properties they carry.

    .PARAMETER Path
        Destination .html file path. The parent directory must exist. An existing file is
        overwritten.

    .PARAMETER Title
        Heading shown at the top of the report. Default: 'SQL Server Recoverability Report'.

    .PARAMETER PassThru
        Also return the generated file as a System.IO.FileInfo object, so the path can flow
        down the pipeline (e.g. to Send-MailMessage or Invoke-Item).

    .EXAMPLE
        PS C:\> Test-SqlRestoreChain -SqlInstance sql01 |
                Export-SqlReliabilityReport -Path C:\reports\sql01-recoverability.html

        Checks every user database on sql01 and writes a recoverability report.

    .EXAMPLE
        PS C:\> Test-SqlRestoreChain -SqlInstance sql01, sql02 -MaxRpoHours 4 |
                Export-SqlReliabilityReport -Path .\dr-audit.html -Title 'Quarterly DR Audit' -PassThru |
                Invoke-Item

        Audits two instances against a 4-hour RPO, titles the report, writes it, and opens it.

    .NOTES
        Author: Deepesh Dhake
        Presentation only - makes no server connections.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Title = 'SQL Server Recoverability Report',

        [switch]$PassThru
    )

    begin {
        # Collect across all pipeline batches; render once in end{}.
        $rows = [System.Collections.Generic.List[object]]::new()

        function ConvertTo-HtmlText {
            param([object]$Value)
            if ($null -eq $Value) { return '' }
            $s = [string]$Value
            # Manual encode - avoids a hard dependency on System.Web being loaded.
            $s = $s.Replace('&', '&amp;').
                    Replace('<', '&lt;').
                    Replace('>', '&gt;').
                    Replace('"', '&quot;').
                    Replace("'", '&#39;')
            return $s
        }
    }

    process {
        foreach ($item in $InputObject) {
            if ($null -ne $item) { $rows.Add($item) }
        }
    }

    end {
        if ($rows.Count -eq 0) {
            Write-Warning 'No input objects were provided; nothing to report.'
            return
        }

        # Resolve $Path to a full path against PowerShell's current location.
        # [System.IO.File]::WriteAllText resolves relative paths against the PROCESS
        # working directory, which is NOT PowerShell's location - so a relative path
        # like .\report.html would silently write to the wrong directory. Anchor it
        # to $PWD explicitly. (GetUnresolvedProviderPathFromPSPath works for a path
        # whose file does not yet exist.)
        $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

        # Verify the destination directory exists before doing work.
        $parent = Split-Path -Path $fullPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            throw "Destination directory does not exist: $parent"
        }

        # Health is driven by ChainHealthy when present; fall back to "unknown" otherwise.
        $healthy   = @($rows | Where-Object { $_.PSObject.Properties['ChainHealthy'] -and $_.ChainHealthy }).Count
        $unhealthy = @($rows | Where-Object { $_.PSObject.Properties['ChainHealthy'] -and -not $_.ChainHealthy }).Count
        $total     = $rows.Count
        $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

        $bannerClass = if ($unhealthy -gt 0) { 'banner-alert' } else { 'banner-ok' }
        $bannerText  = if ($unhealthy -gt 0) {
            "$unhealthy of $total database(s) are NOT recoverable or breach RPO"
        } else {
            "All $total database(s) have a healthy, restorable backup chain"
        }

        # Build the table body.
        $sb = [System.Text.StringBuilder]::new()
        foreach ($r in ($rows | Sort-Object -Property @{ Expression = { [bool]$_.ChainHealthy } }, SqlInstance, Database)) {
            $isHealthy = $r.PSObject.Properties['ChainHealthy'] -and $r.ChainHealthy
            $rowClass  = if ($isHealthy) { 'ok' } else { 'bad' }
            $statusTxt = if ($isHealthy) { 'Healthy' } else { 'At risk' }

            # Issues may be an array; join for display. Empty when healthy.
            $issuesRaw = if ($r.PSObject.Properties['Issues']) { $r.Issues } else { @() }
            $issuesHtml = if ($issuesRaw -and @($issuesRaw).Count -gt 0) {
                ($issuesRaw | ForEach-Object { '<li>' + (ConvertTo-HtmlText $_) + '</li>' }) -join ''
            } else { '<span class="muted">-</span>' }
            if ($issuesHtml -like '<li>*') { $issuesHtml = "<ul>$issuesHtml</ul>" }

            $rpo = if ($r.PSObject.Properties['RpoGapHours'] -and $null -ne $r.RpoGapHours) {
                ConvertTo-HtmlText ("{0} h" -f $r.RpoGapHours)
            } else { '<span class="muted">-</span>' }

            $lastRestorable = if ($r.PSObject.Properties['LastRestorable'] -and $r.LastRestorable) {
                ConvertTo-HtmlText ([datetime]$r.LastRestorable).ToString('yyyy-MM-dd HH:mm')
            } else { '<span class="muted">none</span>' }

            [void]$sb.Append("<tr class='$rowClass'>")
            [void]$sb.Append("<td>" + (ConvertTo-HtmlText $r.SqlInstance)   + "</td>")
            [void]$sb.Append("<td>" + (ConvertTo-HtmlText $r.Database)      + "</td>")
            [void]$sb.Append("<td>" + (ConvertTo-HtmlText $r.RecoveryModel) + "</td>")
            [void]$sb.Append("<td><span class='pill pill-$rowClass'>$statusTxt</span></td>")
            [void]$sb.Append("<td>$lastRestorable</td>")
            [void]$sb.Append("<td class='num'>$rpo</td>")
            [void]$sb.Append("<td>$issuesHtml</td>")
            [void]$sb.Append("</tr>")
        }
        $tableBody = $sb.ToString()

        $titleEnc = ConvertTo-HtmlText $Title

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$titleEnc</title>
<style>
  :root { color-scheme: light; }
  body { font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         margin: 0; padding: 2rem; background: #f5f6f8; color: #1f2430; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  .meta { color: #6b7280; font-size: .85rem; margin-bottom: 1.25rem; }
  .banner { padding: 1rem 1.25rem; border-radius: 8px; font-weight: 600; margin-bottom: 1.5rem; }
  .banner-ok    { background: #e7f6ec; color: #10693a; border: 1px solid #b7e0c5; }
  .banner-alert { background: #fdeaea; color: #a11919; border: 1px solid #f3bcbc; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px;
          overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  th, td { text-align: left; padding: .6rem .75rem; border-bottom: 1px solid #eceef1;
           vertical-align: top; font-size: .9rem; }
  th { background: #2b3242; color: #fff; font-weight: 600; }
  tr.bad td { background: #fff8f8; }
  td.num { text-align: right; white-space: nowrap; }
  ul { margin: 0; padding-left: 1.1rem; }
  .muted { color: #9aa1ac; }
  .pill { display: inline-block; padding: .1rem .5rem; border-radius: 999px;
          font-size: .78rem; font-weight: 600; }
  .pill-ok  { background: #e7f6ec; color: #10693a; }
  .pill-bad { background: #fdeaea; color: #a11919; }
  footer { margin-top: 1.5rem; color: #9aa1ac; font-size: .78rem; }
</style>
</head>
<body>
  <h1>$titleEnc</h1>
  <div class="meta">Generated $generated &middot; $total database(s) &middot; $healthy healthy, $unhealthy at risk</div>
  <div class="banner $bannerClass">$bannerText</div>
  <table>
    <thead>
      <tr>
        <th>Instance</th><th>Database</th><th>Recovery</th><th>Status</th>
        <th>Last restorable</th><th>RPO gap</th><th>Issues</th>
      </tr>
    </thead>
    <tbody>
$tableBody
    </tbody>
  </table>
  <footer>Generated by SqlReliabilityKit &middot; Export-SqlReliabilityReport. This report reflects backup history at generation time only.</footer>
</body>
</html>
"@

        # UTF-8 without BOM, so browsers and mail clients render cleanly.
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($fullPath, $html, $utf8NoBom)
        Write-Verbose "Wrote report to $fullPath"

        if ($PassThru) { Get-Item -LiteralPath $fullPath }
    }
}
