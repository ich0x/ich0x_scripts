$ErrorActionPreference = 'Stop'

# Find ytdlp-interface.exe from PATH and common install locations.
$roots = @(
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    $env:LOCALAPPDATA
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

$ytdlpCandidates = @(
    Get-Command ytdlp-interface.exe -All -CommandType Application -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Source }

    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Filter ytdlp-interface.exe -File -Recurse `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Sort-Object -Unique

$y = $ytdlpCandidates | ForEach-Object {
    $f = Get-Item -LiteralPath $_
    $raw = $f.VersionInfo.FileVersion
    if (-not $raw) { $raw = $f.VersionInfo.ProductVersion }
    $v = [version]'0.0'
    if ($raw -match '\d+(?:\.\d+){1,3}') {
        try { $v = [version]$Matches[0] } catch {}
    }
    [pscustomobject]@{ Path=$f.FullName; Version=$v; Created=$f.CreationTime }
} | Sort-Object @{Expression='Version';Descending=$true},
                @{Expression='Created';Descending=$true} |
    Select-Object -First 1 -ExpandProperty Path

if (-not $y) {
    throw 'Could not find ytdlp-interface.exe under Program Files, Program Files (x86), LocalAppData, or PATH.'
}
$appDir = Split-Path -LiteralPath $y
$shim = Join-Path $appDir 'aria2c.exe'

Write-Host "Selected ytdlp-interface: $y"

# Find aria2-next (manual install, PATH, or WinGet package location).
$ariaRoots = @(
    $appDir
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    $env:LOCALAPPDATA
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

function Find-Aria2Next {
    $found = @(
        Get-Command aria2-next.exe -All -CommandType Application -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Source }

        foreach ($root in $ariaRoots) {
            Get-ChildItem -LiteralPath $root -Filter 'aria2-next*.exe' -File -Recurse `
                -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        }
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Sort-Object -Unique

    # Prefer the app folder, then the newest file if multiple installations exist.
    $found | ForEach-Object {
        $f = Get-Item -LiteralPath $_
        [pscustomobject]@{ Path=$f.FullName; InApp=($f.DirectoryName -eq $appDir); Created=$f.LastWriteTime }
    } | Sort-Object @{Expression='InApp';Descending=$true},
                    @{Expression='Created';Descending=$true} |
        Select-Object -First 1 -ExpandProperty Path
}

$aria = Find-Aria2Next
if (-not $aria) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'aria2-next was not found and winget.exe is unavailable. Install aria2-next, then rerun this script.'
    }

    $answer = Read-Host 'aria2-next was not found. Install it with WinGet now? [Y/N]'
    if ($answer -notmatch '^(Y|YES)$') {
        throw 'Install aria2-next, then rerun this script.'
    }

    & $winget.Source install --exact --id AnInsomniacy.Aria2Next `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "WinGet install failed (exit code $LASTEXITCODE)." }

    # WinGet may need a moment to finish exposing the installed files.
    Start-Sleep -Seconds 2
    $aria = Find-Aria2Next
    if (-not $aria) {
        throw 'Install completed, but aria2-next*.exe was not found in the searched folders. Rerun after locating the installed executable.'
    }
}
Write-Host "Selected aria2-next: $aria"

# Locate the built-in .NET Framework C# compiler.
$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ }

if (-not $cscCandidates) {
    throw 'Could not find the .NET Framework C# compiler (csc.exe). No existing shim was changed.'
}
$csc = $cscCandidates[0]

# Build in TEMP first. Do not remove/replace an existing shim unless compilation succeeds.
$work = Join-Path $env:TEMP ('aria2-shim-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$cs = Join-Path $work 'Shim.cs'
$tmpExe = Join-Path $work 'aria2c.exe'

$source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;

class Shim {
    [DllImport("kernel32.dll")] static extern bool AllocConsole();

    static string Quote(string s) {
        if (s.Length > 0 && s.IndexOfAny(new char[] {' ', '\t', '\n', '\v', '"'}) < 0) return s;
        var r = new System.Text.StringBuilder("\"");
        int slashes = 0;
        foreach (char c in s) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { r.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
            r.Append('\\', slashes).Append(c); slashes = 0;
        }
        r.Append('\\', slashes * 2).Append('"');
        return r.ToString();
    }

    static string Sanitize(string p) {
        try {
            string dir = Path.GetDirectoryName(p);
            string name = Path.GetFileName(p);
            if (String.IsNullOrEmpty(name)) name = p;
            name = Regex.Replace(name, "[^\\p{L}\\p{N}\\s\\-\\.\\(\\)\\[\\]_]","");
            name = Regex.Replace(name, "\\s+", " ").Trim().TrimStart('.');
            name = name.TrimEnd(' ', '.');
            if (name.Length > 150) name = name.Substring(0,150).TrimEnd(' ', '.');
            if (String.IsNullOrWhiteSpace(name)) name = "video";
            if (Regex.IsMatch(name, "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\\.|$)", RegexOptions.IgnoreCase))
                name = "_" + name;
            return String.IsNullOrEmpty(dir) ? name : Path.Combine(dir,name);
        } catch { return "video.mp4.part"; }
    }

    static string FindEngine() {
        string dir = Path.GetDirectoryName(typeof(Shim).Assembly.Location);
        var paths = new List<string>();
        paths.Add(Path.Combine(dir, "aria2-next.exe"));
        string path = Environment.GetEnvironmentVariable("PATH");
        if (path != null) foreach (string d in path.Split(Path.PathSeparator))
            if (!String.IsNullOrWhiteSpace(d)) paths.Add(Path.Combine(d.Trim('"'), "aria2-next.exe"));

        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string la = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        paths.Add(Path.Combine(pf, "aria2-next", "aria2-next.exe"));
        paths.Add(Path.Combine(pf86, "aria2-next", "aria2-next.exe"));
        paths.Add(Path.Combine(la, "aria2-next", "aria2-next.exe"));
        paths.Add(Path.Combine(la, "Microsoft", "WinGet", "Links", "aria2-next.exe"));

        foreach (string p in paths) if (File.Exists(p)) return p;

        // WinGet and manual releases may retain a versioned executable name.
        string[] roots = { dir, pf, pf86, la };
        foreach (string root in roots) {
            if (String.IsNullOrEmpty(root) || !Directory.Exists(root)) continue;
            try {
                foreach (string p in Directory.GetFiles(root, "aria2-next*.exe", SearchOption.AllDirectories))
                    return p;
            } catch {}
        }
        return "aria2-next.exe";
    }

    static int Main(string[] args) {
        try { AllocConsole(); } catch {}
        var bad = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "--always-resume", "--auto-file-renaming", "--force-save", "--remove-control-file"
        };
        var keep = new List<string>();

        for (int i=0; i<args.Length; i++) {
            string a = args[i];
            bool drop = false;
            foreach (string b in bad)
                if (a == b || a.StartsWith(b + "=")) { drop = true; break; }
            if (drop) continue;

            if (a == "--file-allocation" || a.StartsWith("--file-allocation=")) {
                if (a == "--file-allocation" && i+1 < args.Length) i++;
                continue;
            }

            if (a == "--out" || a == "-o") {
                keep.Add(a);
                if (i+1 < args.Length) keep.Add(Sanitize(args[++i]));
                continue;
            }
            if (a.StartsWith("--out=")) {
                keep.Add("--out=" + Sanitize(a.Substring(6)));
                continue;
            }
            keep.Add(a);
        }

        string defaults = "--continue=true --check-integrity=true --log=- --file-allocation=falloc";
        string bin = FindEngine();
        string all = defaults;
        foreach (string a in keep) all += " " + Quote(a);

        Console.WriteLine("[aria2 shim] " + bin);
        var psi = new ProcessStartInfo(bin, all);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = false;
        var proc = Process.Start(psi);
        if (proc == null) return 1;
        proc.WaitForExit();
        return proc.ExitCode;
    }
}
'@

Set-Content -LiteralPath $cs -Value $source -Encoding UTF8
& $csc /nologo /target:exe "/out:$tmpExe" $cs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpExe)) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    throw 'Shim compilation failed; any existing aria2c.exe was left untouched.'
}

# Replace atomically as far as possible; preserve prior shim until new build is ready.
$backup = $null
try {
    if (Test-Path -LiteralPath $shim) {
        $backup = Join-Path $appDir ('aria2c.exe.backup-' + (Get-Date -Format 'yyyyMMddHHmmss'))
        Move-Item -LiteralPath $shim -Destination $backup
    }
    Move-Item -LiteralPath $tmpExe -Destination $shim
} catch {
    if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $shim)) {
        Move-Item -LiteralPath $backup -Destination $shim
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    throw
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "SUCCESS: shim created at $shim"
if ($backup) { Write-Host "Previous shim backup: $backup" }
