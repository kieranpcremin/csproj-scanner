#Requires -Version 5.1
# Author: Kieran Cremin
<#
.SYNOPSIS
    Scans .csproj files for NuGet and MSBuild issues that cause restore or build failures.

.DESCRIPTION
    Detects the following issues across all .csproj files in a directory or solution:

    Errors (cause restore or build failures):
      - Duplicate PackageReferences
      - Duplicate ProjectReferences
      - Duplicate Import elements  (causes MSB4011 and double-processing)
      - Duplicate assembly References
      - Active EnsureNuGetPackageBuildImports targets  (fails on clean build agents)
      - Mixed packages.config and PackageReference usage
      - Package version conflicts across projects

    Warnings (cause graph bloat or unexpected behaviour):
      - Locale satellite packages  (e.g. Humanizer.Core.fr, Humanizer.Core.zh-Hans)

.PARAMETER Path
    Path to a directory or .sln file to scan. Defaults to the current directory.

.PARAMETER Fix
    Automatically fix safe issues: duplicates and active EnsureNuGetPackageBuildImports.
    A .bak backup of each modified file is created before any changes are written unless -NoBackup is specified.

.PARAMETER NoBackup
    Skip creating .bak backup files when running with -Fix.
    Use with caution — changes cannot be undone automatically.

.PARAMETER OutputFile
    Write the full report to a file. Supports .txt and .html extensions.

.PARAMETER ShowClean
    Include projects with no issues in the console output.

.EXAMPLE
    .\Find-CsprojIssues.ps1
    .\Find-CsprojIssues.ps1 -Path "C:\Work\MySolution.sln"
    .\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -Fix
    .\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -Fix -NoBackup
    .\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -OutputFile "report.html"
    .\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -Fix -OutputFile "report.txt" -ShowClean
#>
param(
    [string]$Path       = ".",
    [switch]$Fix,
    [switch]$NoBackup,
    [string]$OutputFile = "",
    [switch]$ShowClean
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Helpers
# =============================================================================

function Get-CsprojFiles ([string]$InputPath) {
    if ($InputPath -match '\.sln$') {
        if (-not (Test-Path $InputPath)) { throw "Solution file not found: $InputPath" }
        $slnDir = Split-Path (Resolve-Path $InputPath).Path -Parent
        $files  = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($line in (Get-Content $InputPath)) {
            if ($line -match '"([^"]+\.csproj)"') {
                $rel = $Matches[1] -replace '\\', [IO.Path]::DirectorySeparatorChar
                $abs = Join-Path $slnDir $rel
                if (Test-Path $abs) { $files.Add((Get-Item $abs)) }
            }
        }
        return $files.ToArray()
    }
    return @(Get-ChildItem -Path (Resolve-Path $InputPath).Path -Filter "*.csproj" -Recurse)
}

function Get-PackageRefVersion ([System.Xml.XmlNode]$Node) {
    $v = $Node.GetAttribute("Version")
    if (-not $v) {
        foreach ($child in $Node.ChildNodes) {
            if ($child.LocalName -eq "Version") { $v = $child.InnerText; break }
        }
    }
    return $v
}

function Save-FixedXml ([string]$FilePath, [System.Xml.XmlDocument]$Xml, [bool]$Backup) {
    if ($Backup) { Copy-Item $FilePath "$FilePath.bak" -Force }
    $settings             = New-Object System.Xml.XmlWriterSettings
    $settings.Indent      = $true
    $settings.IndentChars = "  "
    $settings.Encoding    = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($FilePath, $settings)
    try     { $Xml.Save($writer) }
    finally { $writer.Dispose() }
}

function ConvertTo-HtmlSafe ([string]$Text) {
    $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;'
}

# =============================================================================
# Per-project scan
# =============================================================================

function Invoke-ScanProject ([System.IO.FileInfo]$File, [bool]$ApplyFix, [bool]$Backup) {

    $result = [PSCustomObject]@{
        FileName = $File.Name
        FullPath = $File.FullName
        Issues   = [System.Collections.Generic.List[string]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
        Fixed    = [System.Collections.Generic.List[string]]::new()
        Packages = @{}   # lowerName -> version  (used for cross-project conflict check)
        WasFixed = $false
    }

    [xml]$xml = $null
    try   { [xml]$xml = Get-Content $File.FullName -Raw -Encoding UTF8 }
    catch { $result.Issues.Add("Cannot parse XML: $_"); return $result }

    $allNodes = @($xml.SelectNodes("//*"))
    $modified = $false

    # Returns nodes that appear more than once by a given key selector
    function Get-DuplicateNodes ([System.Xml.XmlNode[]]$Nodes, [scriptblock]$KeyFn) {
        $seen  = @{}
        $dupes = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
        foreach ($n in $Nodes) {
            $key = (& $KeyFn $n).ToLower()
            if ($key -eq "") { continue }
            if ($seen.ContainsKey($key)) { $dupes.Add($n) } else { $seen[$key] = $true }
        }
        return $dupes
    }

    # ── Duplicate PackageReferences ──────────────────────────────────────────
    $pkgNodes = @($allNodes | Where-Object { $_.LocalName -eq "PackageReference" })

    foreach ($node in (Get-DuplicateNodes $pkgNodes { param($n) $n.GetAttribute("Include") })) {
        $name = $node.GetAttribute("Include")
        $result.Issues.Add("[DUPLICATE PackageReference]  $name")
        if ($ApplyFix) {
            $node.ParentNode.RemoveChild($node) | Out-Null
            $result.Fixed.Add("Removed duplicate PackageReference: $name")
            $modified = $true
        }
    }

    # Collect versions for cross-project analysis
    foreach ($node in $pkgNodes) {
        $name = $node.GetAttribute("Include").ToLower()
        if ($name -and -not $result.Packages.ContainsKey($name)) {
            $ver = Get-PackageRefVersion $node
            if ($ver) { $result.Packages[$name] = $ver }
        }
    }

    # ── Duplicate ProjectReferences ──────────────────────────────────────────
    $projNodes = @($allNodes | Where-Object { $_.LocalName -eq "ProjectReference" })

    foreach ($node in (Get-DuplicateNodes $projNodes { param($n) $n.GetAttribute("Include") -replace '\\', '/' })) {
        $name = $node.GetAttribute("Include")
        $result.Issues.Add("[DUPLICATE ProjectReference]  $name")
        if ($ApplyFix) {
            $node.ParentNode.RemoveChild($node) | Out-Null
            $result.Fixed.Add("Removed duplicate ProjectReference: $name")
            $modified = $true
        }
    }

    # ── Duplicate Import elements ─────────────────────────────────────────────
    $importNodes = @($allNodes | Where-Object { $_.LocalName -eq "Import" })

    foreach ($node in (Get-DuplicateNodes $importNodes { param($n) $n.GetAttribute("Project") })) {
        $name = $node.GetAttribute("Project")
        $result.Issues.Add("[DUPLICATE Import]  $name")
        if ($ApplyFix) {
            $node.ParentNode.RemoveChild($node) | Out-Null
            $result.Fixed.Add("Removed duplicate Import: $name")
            $modified = $true
        }
    }

    # ── Duplicate assembly References ─────────────────────────────────────────
    $refNodes = @($allNodes | Where-Object { $_.LocalName -eq "Reference" })

    foreach ($node in (Get-DuplicateNodes $refNodes { param($n) ($n.GetAttribute("Include") -split ',')[0].Trim() })) {
        $name = ($node.GetAttribute("Include") -split ',')[0].Trim()
        $result.Issues.Add("[DUPLICATE Reference]  $name")
        if ($ApplyFix) {
            $node.ParentNode.RemoveChild($node) | Out-Null
            $result.Fixed.Add("Removed duplicate Reference: $name")
            $modified = $true
        }
    }

    # ── Active EnsureNuGetPackageBuildImports ─────────────────────────────────
    $ensureTargets = @($allNodes | Where-Object {
        $_.LocalName -eq "Target" -and $_.GetAttribute("Name") -eq "EnsureNuGetPackageBuildImports"
    })
    foreach ($target in $ensureTargets) {
        $errorNodes = @($target.SelectNodes(".//*") | Where-Object { $_.LocalName -eq "Error" })
        if ($errorNodes.Count -gt 0) {
            $result.Issues.Add("[ACTIVE EnsureNuGetPackageBuildImports]  $($errorNodes.Count) Error element(s) - will fail on clean build agents")
            if ($ApplyFix) {
                while ($target.HasChildNodes) { $target.RemoveChild($target.FirstChild) | Out-Null }
                $result.Fixed.Add("Emptied EnsureNuGetPackageBuildImports target")
                $modified = $true
            }
        }
    }

    # ── Locale satellite packages ─────────────────────────────────────────────
    # Flags groups of 3+ packages sharing the same base name with locale-code suffixes.
    # e.g. Humanizer.Core.fr, Humanizer.Core.de, Humanizer.Core.zh-Hans are all flagged together.
    $allPkgNames = @($pkgNodes | ForEach-Object { $_.GetAttribute("Include") } | Where-Object { $_ })
    $localeRegex = '^(.+)\.[a-z]{2}(-[A-Za-z]{2,4})?$'

    $localeSatellites = foreach ($pkg in $allPkgNames) {
        if ($pkg -match $localeRegex) {
            [PSCustomObject]@{ Package = $pkg; Base = $Matches[1] }
        }
    }
    if ($localeSatellites) {
        foreach ($group in ($localeSatellites | Group-Object Base | Where-Object { $_.Count -ge 3 })) {
            $result.Warnings.Add("[LOCALE BLOAT]  $($group.Count) locale satellite packs for '$($group.Name)' - remove unless non-English output is required")
            if ($ApplyFix) {
                $packagesToRemove = $group.Group.Package
                foreach ($node in $pkgNodes) {
                    if ($packagesToRemove -contains $node.GetAttribute("Include")) {
                        $node.ParentNode.RemoveChild($node) | Out-Null
                        $modified = $true
                    }
                }
                $result.Fixed.Add("Removed $($group.Count) locale satellite packs for '$($group.Name)'")
            }
        }
    }

    # ── Mixed packages.config + PackageReference ──────────────────────────────
    $pkgConfigPath = Join-Path $File.DirectoryName "packages.config"
    if ($pkgNodes.Count -gt 0 -and (Test-Path $pkgConfigPath)) {
        $result.Issues.Add("[MIXED RESTORE]  Both PackageReference and packages.config exist - use one restore method only")
    }

    # ── Save if fixes were applied ────────────────────────────────────────────
    if ($ApplyFix -and $modified) {
        Save-FixedXml -FilePath $File.FullName -Xml $xml -Backup $Backup
        $result.WasFixed = $true
    }

    return $result
}

# =============================================================================
# Main
# =============================================================================

$banner = "csproj-scanner  |  NuGet and MSBuild Issue Detector"
Write-Host ""
Write-Host $banner -ForegroundColor Cyan
Write-Host ("=" * $banner.Length) -ForegroundColor Cyan
Write-Host ""

$resolvedPath = Resolve-Path $Path -ErrorAction SilentlyContinue
if (-not $resolvedPath) { Write-Error "Path not found: $Path"; exit 1 }

if ($Fix) {
    if ($NoBackup) {
        Write-Host "[FIX MODE]  Safe issues will be fixed automatically. Backups are DISABLED (-NoBackup)." -ForegroundColor Yellow
    } else {
        Write-Host "[FIX MODE]  Safe issues will be fixed automatically. .bak backups will be created." -ForegroundColor Yellow
    }
    Write-Host ""
}

$csprojFiles = Get-CsprojFiles $resolvedPath.Path
if ($csprojFiles.Count -eq 0) {
    Write-Host "No .csproj files found at: $resolvedPath" -ForegroundColor Yellow
    exit 0
}
Write-Host "Scanning $($csprojFiles.Count) project(s)..." -ForegroundColor Gray
Write-Host ""

# ── Scan each project ─────────────────────────────────────────────────────────
$allResults  = [System.Collections.Generic.List[object]]::new()
$allVersions = @{}   # lowerPackageName -> { versionString -> [fileNames] }

foreach ($file in $csprojFiles) {
    $result = Invoke-ScanProject -File $file -ApplyFix $Fix.IsPresent -Backup (-not $NoBackup.IsPresent)
    $allResults.Add($result)

    foreach ($kvp in $result.Packages.GetEnumerator()) {
        if (-not $allVersions.ContainsKey($kvp.Key)) { $allVersions[$kvp.Key] = @{} }
        $ver = $kvp.Value
        if (-not $allVersions[$kvp.Key].ContainsKey($ver)) { $allVersions[$kvp.Key][$ver] = @() }
        $allVersions[$kvp.Key][$ver] += $result.FileName
    }
}

# ── Cross-project version conflicts ──────────────────────────────────────────
$versionConflicts = @(
    $allVersions.GetEnumerator() |
    Where-Object { $_.Value.Keys.Count -gt 1 } |
    Sort-Object   Key |
    ForEach-Object { [PSCustomObject]@{ Package = $_.Key; Versions = $_.Value } }
)

# ── Console output ────────────────────────────────────────────────────────────
$totalIssues   = 0
$totalWarnings = 0
$totalFixed    = 0

foreach ($r in $allResults) {
    $hasContent = $r.Issues.Count -gt 0 -or $r.Warnings.Count -gt 0 -or $r.Fixed.Count -gt 0

    if ($hasContent -or $ShowClean) {
        Write-Host ">>> $($r.FileName)" -ForegroundColor Yellow
        if (-not $hasContent)       { Write-Host "    Clean" -ForegroundColor Green }
        foreach ($i in $r.Issues)   { Write-Host "    $i"   -ForegroundColor Red }
        foreach ($w in $r.Warnings) { Write-Host "    $w"   -ForegroundColor DarkYellow }
        foreach ($f in $r.Fixed)    { Write-Host "    [FIXED] $f" -ForegroundColor Green }
        Write-Host ""
    }

    $totalIssues   += $r.Issues.Count
    $totalWarnings += $r.Warnings.Count
    $totalFixed    += $r.Fixed.Count
}

if ($versionConflicts.Count -gt 0) {
    Write-Host ">>> Cross-project package version conflicts" -ForegroundColor Yellow
    foreach ($c in $versionConflicts) {
        Write-Host "    $($c.Package)" -ForegroundColor Red
        foreach ($ver in ($c.Versions.GetEnumerator() | Sort-Object Key)) {
            Write-Host "      v$($ver.Key)  ->  $($ver.Value -join ', ')" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "  NOTE: Version conflicts are not auto-fixed by -Fix." -ForegroundColor DarkYellow
    Write-Host "  Reason: the correct version to standardise on depends on intent - one project" -ForegroundColor DarkYellow
    Write-Host "  may need a newer version for a specific feature, another may be pinned to avoid" -ForegroundColor DarkYellow
    Write-Host "  a breaking change. Getting this wrong can cause subtle runtime bugs. Review each" -ForegroundColor DarkYellow
    Write-Host "  conflict above and update the versions manually once you know which to keep." -ForegroundColor DarkYellow
    Write-Host ""
}

# ── Summary table ─────────────────────────────────────────────────────────────
Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan
Write-Host ""

$maxLen = ($allResults | ForEach-Object { $_.FileName.Length } | Measure-Object -Maximum).Maximum
$fmt    = "  {0,-$maxLen}  {1,6}  {2,8}  {3,6}"

Write-Host ($fmt -f "Project", "Issues", "Warnings", "Fixed") -ForegroundColor Gray
Write-Host ("  " + ("-" * ($maxLen + 26))) -ForegroundColor Gray

foreach ($r in ($allResults | Sort-Object { $_.Issues.Count * 100 + $_.Warnings.Count } -Descending)) {
    $color = if ($r.Issues.Count -gt 0) { "Red" } elseif ($r.Warnings.Count -gt 0) { "DarkYellow" } else { "Green" }
    Write-Host ($fmt -f $r.FileName, $r.Issues.Count, $r.Warnings.Count, $r.Fixed.Count) -ForegroundColor $color
}

Write-Host ""
$totColor = if ($totalIssues -gt 0 -or $versionConflicts.Count -gt 0) { "Red" } else { "Green" }
Write-Host "  Project issues: $totalIssues   Version conflicts: $($versionConflicts.Count)   Warnings: $totalWarnings   Fixed: $totalFixed" -ForegroundColor $totColor
Write-Host ""

# ── File output ───────────────────────────────────────────────────────────────
if ($OutputFile -ne "") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ext       = [IO.Path]::GetExtension($OutputFile).ToLower()

    if ($ext -eq ".html") {

        $projectRows = foreach ($r in $allResults) {
            $entries = [System.Collections.Generic.List[string]]::new()
            foreach ($i in $r.Issues)   { $entries.Add("<div class='issue'>"   + (ConvertTo-HtmlSafe $i) + "</div>") }
            foreach ($w in $r.Warnings) { $entries.Add("<div class='warning'>" + (ConvertTo-HtmlSafe $w) + "</div>") }
            foreach ($f in $r.Fixed)    { $entries.Add("<div class='fixed'>[FIXED] " + (ConvertTo-HtmlSafe $f) + "</div>") }

            $statusClass = if ($r.Issues.Count -gt 0) { "status-error" } elseif ($r.Warnings.Count -gt 0) { "status-warn" } else { "status-ok" }
            $statusText  = if ($r.Issues.Count -gt 0) { "$($r.Issues.Count) issue(s)" } elseif ($r.Warnings.Count -gt 0) { "$($r.Warnings.Count) warning(s)" } else { "Clean" }
            $detailHtml  = if ($entries.Count -gt 0) { $entries -join "" } else { "<div class='clean'>No issues found</div>" }

            "<tr><td><code>" + (ConvertTo-HtmlSafe $r.FileName) + "</code></td><td><span class='$statusClass'>$statusText</span></td><td>$detailHtml</td></tr>"
        }

        $conflictsHtml = ""
        if ($versionConflicts.Count -gt 0) {
            $items = foreach ($c in $versionConflicts) {
                $verLines = ($c.Versions.GetEnumerator() | Sort-Object Key | ForEach-Object {
                    "<li>v$($_.Key) &rarr; $(ConvertTo-HtmlSafe ($_.Value -join ', '))</li>"
                }) -join ""
                "<li><strong>$(ConvertTo-HtmlSafe $c.Package)</strong><ul>$verLines</ul></li>"
            }
            $conflictsHtml = "<h2>Cross-Project Version Conflicts</h2><ul class='conflicts'>$($items -join '')</ul>"
        }

        $issueNumColor = if ($totalIssues   -gt 0) { "#c0392b" } else { "#27ae60" }
        $warnNumColor  = if ($totalWarnings -gt 0) { "#d68910" } else { "#27ae60" }

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>csproj-scanner Report</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body      { font-family: Segoe UI, Arial, sans-serif; margin: 0; padding: 40px; background: #f0f2f5; color: #333; }
    h1        { color: #1a1a2e; margin: 0 0 4px; font-size: 1.6em; }
    h2        { color: #444; margin: 32px 0 12px; font-size: 1.1em; text-transform: uppercase; letter-spacing: 0.05em; }
    .meta     { color: #888; font-size: 0.85em; margin: 0 0 32px; }
    .card     { background: white; border-radius: 8px; padding: 24px; margin-bottom: 24px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
    .stats    { display: flex; gap: 32px; flex-wrap: wrap; }
    .stat     { text-align: center; min-width: 80px; }
    .stat-num { font-size: 2.2em; font-weight: 700; line-height: 1; }
    .stat-lbl { font-size: 0.8em; color: #888; margin-top: 4px; text-transform: uppercase; letter-spacing: 0.05em; }
    table     { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
    th        { background: #1a1a2e; color: #fff; padding: 12px 16px; text-align: left; font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.05em; }
    td        { padding: 12px 16px; border-bottom: 1px solid #eef0f3; vertical-align: top; }
    tr:last-child td { border-bottom: none; }
    tr:hover  td     { background: #f7f9ff; }
    code      { background: #eef0f3; padding: 2px 6px; border-radius: 4px; font-size: 0.85em; }
    .issue    { color: #c0392b; font-size: 0.88em; padding: 1px 0; }
    .warning  { color: #d68910; font-size: 0.88em; padding: 1px 0; }
    .fixed    { color: #27ae60; font-size: 0.88em; padding: 1px 0; }
    .clean    { color: #27ae60; font-size: 0.88em; }
    .status-error { background: #fdecea; color: #c0392b; padding: 3px 10px; border-radius: 12px; font-size: 0.8em; font-weight: 600; white-space: nowrap; }
    .status-warn  { background: #fef9e7; color: #d68910; padding: 3px 10px; border-radius: 12px; font-size: 0.8em; font-weight: 600; white-space: nowrap; }
    .status-ok    { background: #eafaf1; color: #27ae60; padding: 3px 10px; border-radius: 12px; font-size: 0.8em; font-weight: 600; white-space: nowrap; }
    .conflicts li { margin-bottom: 6px; }
    .conflicts ul { margin: 4px 0; color: #666; font-size: 0.9em; }
  </style>
</head>
<body>
  <h1>csproj-scanner Report</h1>
  <p class="meta">Generated: $timestamp &nbsp;&bull;&nbsp; Projects scanned: $($allResults.Count)</p>

  <div class="card">
    <div class="stats">
      <div class="stat"><div class="stat-num" style="color:$issueNumColor">$totalIssues</div><div class="stat-lbl">Issues</div></div>
      <div class="stat"><div class="stat-num" style="color:$warnNumColor">$totalWarnings</div><div class="stat-lbl">Warnings</div></div>
      <div class="stat"><div class="stat-num" style="color:#27ae60">$totalFixed</div><div class="stat-lbl">Fixed</div></div>
      <div class="stat"><div class="stat-num">$($versionConflicts.Count)</div><div class="stat-lbl">Version Conflicts</div></div>
    </div>
  </div>

  $conflictsHtml

  <h2>Project Details</h2>
  <table>
    <thead><tr><th>Project</th><th>Status</th><th>Details</th></tr></thead>
    <tbody>$($projectRows -join '')</tbody>
  </table>
</body>
</html>
"@
        $html | Set-Content $OutputFile -Encoding UTF8
        Write-Host "HTML report written to: $(Resolve-Path $OutputFile)" -ForegroundColor Cyan

    } else {

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("csproj-scanner Report")
        $lines.Add("Generated : $timestamp")
        $lines.Add("Projects  : $($allResults.Count)")
        $lines.Add("")

        foreach ($r in $allResults) {
            $lines.Add(">>> $($r.FileName)")
            if ($r.Issues.Count -eq 0 -and $r.Warnings.Count -eq 0) { $lines.Add("    Clean") }
            foreach ($i in $r.Issues)   { $lines.Add("    $i") }
            foreach ($w in $r.Warnings) { $lines.Add("    $w") }
            foreach ($f in $r.Fixed)    { $lines.Add("    [FIXED] $f") }
            $lines.Add("")
        }

        if ($versionConflicts.Count -gt 0) {
            $lines.Add(">>> Cross-project version conflicts")
            foreach ($c in $versionConflicts) {
                $lines.Add("    $($c.Package)")
                foreach ($ver in ($c.Versions.GetEnumerator() | Sort-Object Key)) {
                    $lines.Add("      v$($ver.Key) -> $($ver.Value -join ', ')")
                }
            }
            $lines.Add("")
        }

        $lines.Add("Summary:  Issues=$totalIssues   Warnings=$totalWarnings   Fixed=$totalFixed")
        $lines | Set-Content $OutputFile -Encoding UTF8
        Write-Host "Text report written to: $(Resolve-Path $OutputFile)" -ForegroundColor Cyan
    }

    Write-Host ""
}

# ── Exit code ─────────────────────────────────────────────────────────────────
if ($totalIssues -gt 0) { exit 1 }
