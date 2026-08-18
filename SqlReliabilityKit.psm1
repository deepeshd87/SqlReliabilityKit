# SqlReliabilityKit root module
# Dot-sources every .ps1 in Public/ and Private/, then exports only the public functions.

$Public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($Public + $Private)) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error "Failed to import function $($file.FullName): $_"
    }
}

# Export only the public function names (matches FunctionsToExport in the manifest).
Export-ModuleMember -Function $Public.BaseName
