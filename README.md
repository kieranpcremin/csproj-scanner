# csproj-scanner — Catch the .csproj Gremlins Before They Catch You

A PowerShell utility that scans `.csproj` files for NuGet and MSBuild problems that silently corrupt package restore, cause cryptic build failures, or bloat dependency graphs — the kind of issues that are invisible in Visual Studio but bring CI pipelines to their knees.

---

## Why This Exists

Large .NET solutions accumulate cruft over years of Visual Studio upgrades, NuGet migrations, and copy-paste errors. Duplicate references, stale build targets, and version mismatches hide quietly in project files until the day they cause a mysterious restore crash on a build agent with no useful error message.

This tool finds them in seconds.

---

## What It Detects

### Errors
Issues that directly cause restore or build failures:

| Code | Description |
|---|---|
| `DUPLICATE PackageReference` | Same NuGet package listed more than once — causes version conflicts and double graph processing |
| `DUPLICATE ProjectReference` | Same project-to-project reference listed more than once — doubles the transitive dependency graph |
| `DUPLICATE Import` | Same `<Import>` element repeated — triggers MSB4011 and processes the same targets twice |
| `DUPLICATE Reference` | Same assembly reference listed more than once |
| `ACTIVE EnsureNuGetPackageBuildImports` | Old packages.config-era target that throws a hard build error on any clean agent where `NuGet.targets` does not exist |
| `MIXED RESTORE` | Both `PackageReference` elements and a `packages.config` file exist in the same project |
| Cross-project version conflicts | The same package is referenced at different versions across projects in the solution |

### Warnings
Issues that cause graph bloat or unexpected behaviour:

| Code | Description |
|---|---|
| `LOCALE BLOAT` | Three or more locale satellite packages (e.g. `Humanizer.Core.fr`, `Humanizer.Core.zh-Hans`) — massively inflates the restore graph without benefit unless the app outputs localized text |

---

## Requirements

- PowerShell 5.1 or later (included with Windows 10 and above)
- No external dependencies

---

## Installation

No installation needed. Download `Find-CsprojIssues.ps1` and run it.

If your execution policy blocks unsigned scripts, run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Usage

### Scan a directory (recursive)
```powershell
.\Find-CsprojIssues.ps1
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src\MyApp"
```

### Scan from a solution file
```powershell
.\Find-CsprojIssues.ps1 -Path "C:\Work\MySolution.sln"
```
Only projects referenced in the `.sln` file are scanned.

### Auto-fix safe issues
```powershell
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -Fix
```
Removes duplicate references, duplicate imports, and empties active `EnsureNuGetPackageBuildImports` targets. A `.bak` backup of each modified file is created automatically.

### Export a report
```powershell
# HTML report
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -OutputFile "report.html"

# Plain text report
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -OutputFile "report.txt"
```

### Show clean projects too
```powershell
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -ShowClean
```

### Combine options
```powershell
.\Find-CsprojIssues.ps1 -Path "C:\Work\MySolution.sln" -Fix -OutputFile "report.html" -ShowClean
```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Path` | String | `.` (current directory) | Directory or `.sln` file to scan |
| `-Fix` | Switch | Off | Auto-fix safe issues with .bak backups |
| `-OutputFile` | String | None | Write report to `.txt` or `.html` file |
| `-ShowClean` | Switch | Off | Show projects with no issues in output |

---

## Example Output

```
csproj-scanner  |  NuGet and MSBuild Issue Detector
===================================================

Scanning 12 project(s)...

>>> DPS.Repository.csproj
    [LOCALE BLOAT]  41 locale satellite packs for 'Humanizer.Core' - remove unless non-English output is required

>>> DPS.IOC.Unit.Tests.csproj
    [DUPLICATE ProjectReference]  ..\DPS.IOC\DPS.IOC.csproj

>>> DPS.BL.csproj
    [ACTIVE EnsureNuGetPackageBuildImports]  1 Error element(s) - will fail on clean build agents

>>> Cross-project version conflicts
    newtonsoft.json
      v12.0.3  ->  DPS.BL.csproj, DPS.Model.csproj
      v13.0.1  ->  DPS.Repository.csproj

==============================================================
 Summary
==============================================================

  Project                      Issues  Warnings   Fixed
  -------------------------------------------------------
  DPS.IOC.Unit.Tests.csproj         1         0       0
  DPS.BL.csproj                     1         0       0
  DPS.Repository.csproj             0         1       0
  DPS.Model.csproj                  0         0       0
  ...

  Issues: 3   Warnings: 1   Fixed: 0
```

---

## Fix Mode

Running with `-Fix` is safe. Before modifying any file:
- A `.bak` copy is created next to the original (e.g. `DPS.BL.csproj.bak`)
- Only the following are auto-fixed:
  - Duplicate `PackageReference` elements (second and subsequent occurrences removed)
  - Duplicate `ProjectReference` elements (second and subsequent occurrences removed)
  - Duplicate `Import` elements (second and subsequent occurrences removed)
  - Duplicate assembly `Reference` elements (second and subsequent occurrences removed)
  - `EnsureNuGetPackageBuildImports` target body emptied (the target element is kept, its children removed)

Version conflicts and locale bloat are reported but **not** auto-fixed, as the correct resolution depends on intent.

---

## Background

This tool was written after diagnosing a series of intermittent NuGet restore failures (exit code `null` / StackOverflowException) on an Azure DevOps pipeline running NuGet 5.x and 6.6.x. The root cause was a combination of:

- **A bug in NuGet 5.x through 6.7.x** where the RID compatibility graph walker used deep recursion, causing a stack overflow on large dependency graphs. Fixed in NuGet 6.8+.
- **Duplicate project references** in several unit test projects causing NuGet to process the transitive dependency graph twice per project.
- **41 Humanizer locale satellite packages** in three projects that each P2P-referenced each other, creating a combined graph large enough to reliably overflow the stack.
- **Active `EnsureNuGetPackageBuildImports` targets** that would have failed the build on any agent that did not have legacy NuGet infrastructure.

The immediate fix was upgrading the pipeline to NuGet `6.*`. This tool exists so the underlying project file issues can be found and cleaned up before they cause the next problem.

---

## Compatibility

- Works with both **legacy (.NET Framework)** and **SDK-style** `.csproj` files
- Handles both `Version=""` attribute style and `<Version>` child element style for PackageReferences
- Tested on PowerShell 5.1 (Windows PowerShell) and PowerShell 7+

---

## Contributing

Issues and pull requests are welcome. If you encounter a false positive or a pattern this tool misses, please open an issue with an anonymised sample of the relevant `.csproj` fragment.
