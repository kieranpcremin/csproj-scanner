# csproj-scanner — Catch the .csproj Gremlins Before They Catch You

**A PowerShell utility that scans `.csproj` files for NuGet and MSBuild problems that silently corrupt package restore, cause cryptic build failures, or bloat dependency graphs.**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue)](https://learn.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)](https://github.com/kieranpcremin/csproj-scanner)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

<img width="1860" height="218" alt="image" src="https://github.com/user-attachments/assets/97668cb8-ece7-4a4c-a04e-000b6206d32e" />

---

## 🎯 Why This Exists

Large .NET solutions accumulate cruft over years of Visual Studio upgrades, NuGet migrations, and copy-paste errors. Duplicate references, stale build targets, and version mismatches hide quietly in project files until the day they cause a mysterious restore crash on a build agent with no useful error message.

This tool finds them in seconds.

> **Real-world origin:** This tool was built after diagnosing a series of intermittent NuGet restore failures (exit code `null` / StackOverflowException) on an Azure DevOps pipeline. The culprits were duplicate project references, 41 locale satellite packages across chained projects, and stale `EnsureNuGetPackageBuildImports` targets — none of which were visible in Visual Studio.

---

## 🔍 What It Detects

### Errors — cause restore or build failures

| Code | Description |
|---|---|
| `DUPLICATE PackageReference` | Same NuGet package listed more than once — causes version conflicts and double graph processing |
| `DUPLICATE ProjectReference` | Same project-to-project reference listed more than once — doubles the transitive dependency graph |
| `DUPLICATE Import` | Same `<Import>` element repeated — triggers MSB4011 and processes targets twice |
| `DUPLICATE Reference` | Same legacy assembly reference listed more than once |
| `ACTIVE EnsureNuGetPackageBuildImports` | Old packages.config-era target that throws a hard build error on any clean agent |
| `MIXED RESTORE` | Both `PackageReference` elements and a `packages.config` file exist in the same project |
| Version conflicts | The same package referenced at different versions across projects in the solution |

### Warnings — cause graph bloat or unexpected behaviour

| Code | Description |
|---|---|
| `LOCALE BLOAT` | Three or more locale satellite packages (e.g. `Humanizer.Core.fr`, `Humanizer.Core.zh-Hans`) — massively inflates the restore graph |

---

## 🚀 Quick Start

```powershell
# Scan current directory
.\Find-CsprojIssues.ps1

# Scan a specific folder
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src\MyApp"

# Scan from a solution file
.\Find-CsprojIssues.ps1 -Path "C:\Work\MySolution.sln"
```

If PowerShell blocks unsigned scripts, run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## 🖥️ Example Output

```
csproj-scanner  |  NuGet and MSBuild Issue Detector
===================================================

Scanning 12 project(s)...

>>> DPS.Repository.csproj
    [LOCALE BLOAT]  41 locale satellite packs for 'Humanizer.Core'

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

  Project issues: 3   Version conflicts: 1   Warnings: 1   Fixed: 0
```

---

## ⚙️ All Options

```powershell
.\Find-CsprojIssues.ps1 [-Path <string>] [-Fix] [-OutputFile <string>] [-ShowClean]
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Path` | String | `.` (current directory) | Directory or `.sln` file to scan |
| `-Fix` | Switch | Off | Auto-fix safe issues with automatic `.bak` backups |
| `-NoBackup` | Switch | Off | Skip `.bak` backup creation when running with `-Fix` |
| `-OutputFile` | String | None | Write report to a `.txt` or `.html` file |
| `-ShowClean` | Switch | Off | Include projects with no issues in the output |

### Examples

```powershell
# Auto-fix all safe issues (creates .bak backups before modifying)
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -Fix

# Auto-fix without creating .bak backups
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -Fix -NoBackup

# Export a styled HTML report
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -OutputFile "report.html"

# Export a plain text report
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -OutputFile "report.txt"

# Show every project including clean ones
.\Find-CsprojIssues.ps1 -Path "C:\Work\Src" -ShowClean

# Full run — fix, report, show all
.\Find-CsprojIssues.ps1 -Path "C:\Work\MySolution.sln" -Fix -OutputFile "report.html" -ShowClean
```

---

## 🔧 Fix Mode

Running with `-Fix` is safe. Before modifying any file:
- ✅ A `.bak` copy is created next to the original (e.g. `DPS.BL.csproj.bak`)
- ✅ Only clearly safe issues are auto-fixed

Add `-NoBackup` to skip backup creation if you are confident in the changes or working in a version-controlled directory where files can be reverted via git.

**What gets fixed automatically:**
- Duplicate `PackageReference` elements → second and subsequent occurrences removed
- Duplicate `ProjectReference` elements → second and subsequent occurrences removed
- Duplicate `Import` elements → second and subsequent occurrences removed
- Duplicate assembly `Reference` elements → second and subsequent occurrences removed
- `EnsureNuGetPackageBuildImports` → target body emptied, element kept
- Locale satellite packages → all locale variants removed, base package preserved (e.g. `Humanizer.Core.fr` removed, `Humanizer.Core` kept)

**What is reported but NOT auto-fixed:**

- **Version conflicts** → requires a manual decision. The correct version to standardise on depends on intent — one project may need a newer version for a specific feature, another may be deliberately pinned to avoid a breaking change. Blindly picking a version could introduce subtle runtime bugs or regressions. Review each conflict in the output and update versions manually once you know which to keep.

---

## 📋 Requirements

- **PowerShell 5.1+** (included with Windows 10 and above)
- **No external dependencies** — uses only built-in .NET XML APIs

Works with both **legacy (.NET Framework)** and **SDK-style** `.csproj` files.

---

## 🧠 Background

This tool was written after diagnosing a series of intermittent NuGet restore crashes (`exit code null` / StackOverflowException) on an Azure DevOps pipeline. The investigation found a combination of causes:

1. **A bug in NuGet 5.x through 6.7.x** — the RID compatibility graph walker used deep recursion, overflowing the thread stack on large dependency graphs. Fixed in NuGet 6.8+.
2. **Duplicate project references** in unit test `.csproj` files — causing NuGet to walk the transitive graph twice per project, doubling memory and recursion depth.
3. **41 Humanizer locale satellite packages** across three projects that P2P-referenced each other — creating a combined graph large enough to reliably crash the restore.
4. **Active `EnsureNuGetPackageBuildImports` targets** — legacy checks looking for `NuGet.targets` that does not exist on any modern build agent.

The immediate fix was upgrading the pipeline to NuGet `6.*`. This tool exists so the underlying project file issues can be found and cleaned up before they cause the next problem.

---

## 🛠️ Tech Stack

- **PowerShell 5.1+** — core runtime
- **.NET `System.Xml.XmlDocument`** — project file parsing (namespace-agnostic via `LocalName`)
- **.NET `System.Xml.XmlWriter`** — formatted XML output in fix mode
- **No third-party dependencies**

---

## 👨‍💻 Author

**Kieran Cremin**
Built with assistance from Claude (Anthropic)

---

## 📄 License

MIT License — free to use, modify, and distribute.

---

## 🤝 Contributing

Issues and pull requests are welcome. If you encounter a false positive or a pattern this tool misses, please open an issue with an anonymised sample of the relevant `.csproj` fragment.
