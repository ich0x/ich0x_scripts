<#
.SYNOPSIS
 EXIF batch‑fixer – copies EXIF data from original JPEGs (or side‑car XMPs) to
 converted JPEGs that have the “.jpegli.di079_.jpeg.jpg” suffix.

.DESCRIPTION
 1️⃣ Index originals and XMP side‑cars.  
 2️⃣ Test copying EXIF (dry‑run optional).  
 3️⃣ Optionally run the “smart repair” that tries to reconstruct a missing
    DateTimeOriginal from filename, XMP, folder name, file‑creation time, or
    the converted file itself.  

All operations are parallelised (threads = CPU count by default) and
progress is shown for each step.  Errors and statistics are written to
log files under the root folder.

.NOTES
 Tested on PowerShell 7+.  Requires **exiftool** to be available in PATH.
#>

param(
    [switch]$DryRun      = $false,
    [int]    $Threads    = 0,
    [int]    $BatchSize  = 75,
    [switch]$Verbose    = $true,
    [int]    $LastResortDays = 7
)

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
$Root          = "D:\migration\robocopy"
$LogFail       = "$Root\exif_failed.log"
$LogDone       = "$Root\exif_done.log"
$LogMissing    = "$Root\exif_missing_originals.log"
$LogSmartSkip  = "$Root\exif_smart_skip.log"

$env:EXIFTOOL_CHARSET = "UTF8"
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }

# -----------------------------------------------------------------
# Statistics & thread‑safe collections
# -----------------------------------------------------------------
$Stats = [hashtable]::Synchronized(@{
    IndexedOriginals   = 0; FoundConverted   = 0; SkippedResume = 0
    Processed          = 0; TestOK           = 0; TestFAIL     = 0
    TestMISS           = 0; FuzzyFound       = 0; SmartRepaired = 0
    SmartSkipped       = 0; LastResortRepaired = 0
})

$DoneQueue         = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$FailList          = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$MissingQueue      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$SmartSkipQueue    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$OperationFailQueue= [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# -----------------------------------------------------------------
# Load previously processed files (resume support)
# -----------------------------------------------------------------
$DoneSet = New-Object System.Collections.Hashtable([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $LogDone) {
    Get-Content -LiteralPath $LogDone -ErrorAction SilentlyContinue |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { $DoneSet[$_] = $true }
}
$Stats.SkippedResume = $DoneSet.Count

# -----------------------------------------------------------------
# Verbose header
# -----------------------------------------------------------------
if ($Verbose) {
    [pscustomobject]@{
        Root           = $Root
        Threads        = $Threads
        BatchSize      = $BatchSize
        DryRun         = $DryRun
        LastResortDays = $LastResortDays
        PowerShell     = $PSVersionTable.PSVersion
    } | Format-Table -AutoSize | Out-Host
}

Write-Host "=== EXIF BATCH FIXER v12.4 ===" -ForegroundColor Cyan
Write-Host "`nStep 1 of 5: Indexing…" -ForegroundColor Cyan

# -----------------------------------------------------------------
# 1️⃣ Index originals & XMP side‑cars
# -----------------------------------------------------------------
$Originals = [hashtable]::Synchronized(@{})
$XMPs      = [hashtable]::Synchronized(@{})
$AllFiles  = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue

foreach ($Item in $AllFiles) {
    # Normalise the base name (remove suffixes, copy flags, etc.)
    $Key = [System.IO.Path]::GetFileNameWithoutExtension($Item.Name) `
        -replace '(?i)\.jpegli\.di079_\.jpeg$','' `
        -replace '(?i)\s+-copy$','' `
        -replace '\(\d+\)$','' `
        -replace '-\d+$',''                # <-- fixed syntax
    $Key = $Key.ToLowerInvariant() -replace '[^\p{L}\p{Nd}_-]',''

    if ($Item.Extension -ieq ".xmp") {
        if ($Key -and -not $XMPs.ContainsKey($Key)) { $XMPs[$Key] = $Item.FullName }
        continue
    }

    if ($Item.Extension -notin @(".jpg",".jpeg")) { continue }
    if ($Item.Name -match '(?i)\.jpegli\.di079_\.jpeg\.jpg$') { continue }

    if ($Key -and -not $Originals.ContainsKey($Key)) {
        $Originals[$Key] = $Item.FullName
    }
}
$Stats.IndexedOriginals = $Originals.Count

# -----------------------------------------------------------------
# Find converted files
# -----------------------------------------------------------------
$AllConverted = $AllFiles | Where-Object { $_.Name -match '(?i)\.jpegli\.di079_\.jpeg\.jpg$' }
$WorkList     = $AllConverted | Where-Object { -not $DoneSet.ContainsKey($_.FullName) }
$Stats.FoundConverted = $AllConverted.Count
$Total = $WorkList.Count

Write-Host "Found $($Stats.FoundConverted) converted. To process: $Total. Skipped (resume): $($Stats.SkippedResume)" -ForegroundColor Cyan

# -----------------------------------------------------------------
# 2️⃣ Test copying EXIF from original → converted
# -----------------------------------------------------------------
if ($Total -gt 0) {
    Write-Host "`nStep 2 of 5: Testing EXIF copy…" -ForegroundColor Cyan
    Set-Content -LiteralPath $LogFail    -Value "" -Encoding UTF8
    Set-Content -LiteralPath $LogMissing -Value "" -Encoding UTF8

    $Counter    = [ref]0
    $Lock       = New-Object object
    $sw         = [System.Diagnostics.Stopwatch]::StartNew()
    $LastUpdate = [ref](Get-Date)

    # Chunk the work list into batches
    $Batches = @(
        for ($i = 0; $i -lt $WorkList.Count; $i += $BatchSize) {
            $End = [Math]::Min($i + $BatchSize - 1, $WorkList.Count - 1)
            ,$WorkList[$i..$End]
        }
    )

    $Batches | ForEach-Object -Parallel {
        $Batch            = $_
        $Originals        = $using:Originals
        $DoneQueue        = $using:DoneQueue
        $FailList         = $using:FailList
        $MissingQueue     = $using:MissingQueue
        $OperationFailQueue = $using:OperationFailQueue
        $Counter          = $using:Counter
        $Lock             = $using:Lock
        $Total            = $using:Total
        $sw               = $using:sw
        $LastUpdate       = $using:LastUpdate
        $DryRun           = $using:DryRun
        $Stats            = $using:Stats

        $LocalDone   = New-Object System.Collections.ArrayList
        $LocalFails  = New-Object System.Collections.ArrayList
        $LocalOK     = 0; $LocalFAIL = 0; $LocalMISS = 0; $LocalFuzzy = 0

        foreach ($ConvertedItem in $Batch) {
            $Converted = $ConvertedItem.FullName
            $BaseKey  = [System.IO.Path]::GetFileNameWithoutExtension($ConvertedItem.Name) `
                -replace '(?i)\.jpegli\.di079_\.jpeg$','' `
                -replace '(?i)\s+-copy$','' `
                -replace '\(\d+\)$','' `
                -replace '-\d+$',''           # <-- fixed syntax
            $BaseKey = $BaseKey.ToLowerInvariant() -replace '[^\p{L}\p{Nd}_-]',''

            $Original = $null
            if ($Originals.ContainsKey($BaseKey)) {
                $Original = $Originals[$BaseKey]
                $LocalFuzzy++
            }

            if (-not $Original -or -not (Test-Path -LiteralPath $Original)) {
                $LocalMISS++
                [void]$MissingQueue.Add("$($ConvertedItem.Name) → Key:$BaseKey")
                [void]$LocalFails.Add([pscustomobject]@{
                    Original = 'MISS'; Converted = $Converted; Error = 'MISS'
                })
                continue
            }

            if ($DryRun) {
                $LocalOK++
            } else {
                $Args = @(
                    "-q","-m","-F","-overwrite_original_in_place",
                    "-charset","filename=UTF8","-charset","exif=UTF8",
                    "-TagsFromFile",$Original,"-all:all",$Converted
                )
                $Result = @(& exiftool @Args 2>&1 | Out-String)

                if ($LASTEXITCODE -eq 0) {
                    $LocalOK++
                    [void]$LocalDone.Add($Converted)
                } else {
                    $LocalFAIL++
                    [void]$LocalFails.Add([pscustomobject]@{
                        Original = $Original; Converted = $Converted; Error = $Result.Trim()
                    })
                    [void]$OperationFailQueue.Add("$Original | $Converted | $Result")
                }
            }
        }

        # ----- Sync back to shared state -----
        [System.Threading.Monitor]::Enter($Lock)
        try {
            foreach ($i in $LocalDone)   { [void]$DoneQueue.Add($i) }
            foreach ($i in $LocalFails)  { [void]$FailList.Add($i) }
            $Counter.Value += $Batch.Count

            $Stats.TestOK   += $LocalOK
            $Stats.TestFAIL += $LocalFAIL
            $Stats.TestMISS += $LocalMISS
            $Stats.FuzzyFound += $LocalFuzzy

            $Current = $Counter.Value
            $DoUpdate = ((Get-Date) - $LastUpdate.Value).TotalMilliseconds -ge 200
            if ($DoUpdate) { $LastUpdate.Value = Get-Date }

            $Percent = if ($Total -gt 0) { [Math]::Round(($Current / $Total) * 100, 1) } else { 100 }
            $Eta = if ($Current -gt 0) {
                [TimeSpan]::FromSeconds(
                    ($sw.Elapsed.TotalSeconds / $Current) * ($Total - $Current)
                )
            } else { [TimeSpan]::Zero }

        } finally {
            [System.Threading.Monitor]::Exit($Lock)
        }

        if ($DoUpdate) {
            Write-Progress -Activity "Step 2: Testing" `
                -PercentComplete $Percent `
                -CurrentOperation "$Current/$Total OK:$($Stats.TestOK) FAIL:$($Stats.TestFAIL) MISS:$($Stats.TestMISS) ETA:$($Eta.ToString('hh\:mm\:ss'))"
        }
    } -ThrottleLimit $Threads

    Write-Progress -Activity "Step 2: Testing" -Completed

    # ----- Persist results -----
    if (-not $DryRun) {
        $DoneQueue | Select-Object -Unique | Add-Content -LiteralPath $LogDone -Encoding UTF8
    }
    $Failed = @($FailList | Sort-Object Converted -Unique)
    $Failed | Where-Object { $_.Original -ne 'MISS' } |
        ForEach-Object { "$($_.Original) | $($_.Converted) | $($_.Error)" } |
        Set-Content -LiteralPath $LogFail -Encoding UTF8
    $MissingQueue | Select-Object -Unique | Set-Content -LiteralPath $LogMissing -Encoding UTF8
    $OperationFailQueue | Select-Object -Unique | Add-Content -LiteralPath $LogFail -Encoding UTF8

    $Stats.Processed = $Stats.TestOK + $Stats.TestFAIL + $Stats.TestMISS
}

# -----------------------------------------------------------------
# 3️⃣ Smart repair (optional)
# -----------------------------------------------------------------
if ($Failed.Count -gt 0) {
    Write-Host "`nStep 3 of 5: Smart repair…" -ForegroundColor Yellow
    $Choice = Read-Host "Run Smart Repair? [Y]es / [S]kip"
    if ($Choice -match '^(Y|Yes)$') {

        $RepairCandidates = $Failed | Where-Object {
            $_.Original -and $_.Original -ne 'MISS' -and
            (Test-Path -LiteralPath $_.Original) -and (Test-Path -LiteralPath $_.Converted)
        }

        $CounterFix    = [ref]0
        $TotalFix      = $RepairCandidates.Count
        $swFix         = [System.Diagnostics.Stopwatch]::StartNew()
        $LastUpdateFix = [ref](Get-Date)

        $FixBatches = @(
            for ($i = 0; $i -lt $RepairCandidates.Count; $i += $BatchSize) {
                $End = [Math]::Min($i + $BatchSize - 1, $RepairCandidates.Count - 1)
                ,$RepairCandidates[$i..$End]
            }
        )

        $RepairDoneQueue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

        if ($TotalFix -gt 0) {
            $FixBatches | ForEach-Object -Parallel {
                $Batch            = $_
                $DryRun           = $using:DryRun
                $CounterFix       = $using:CounterFix
                $TotalFix         = $using:TotalFix
                $Lock             = $using:Lock
                $swFix            = $using:swFix
                $LastUpdateFix    = $using:LastUpdateFix
                $Stats            = $using:Stats
                $RepairDoneQueue  = $using:RepairDoneQueue
                $XMPs             = $using:XMPs
                $SmartSkipQueue   = $using:SmartSkipQueue
                $OperationFailQueue = $using:OperationFailQueue
                $LastResortDays   = $using:LastResortDays

                $LocalDone       = New-Object System.Collections.ArrayList
                $LocalRepaired   = 0
                $LocalSkipped    = 0

                foreach ($Item in $Batch) {
                    $File      = $Item.Original
                    $Converted = $Item.Converted

                    $BaseKey = [System.IO.Path]::GetFileNameWithoutExtension($File) `
                        -replace '(?i)\.jpegli\.di079_\.jpeg$','' `
                        -replace '(?i)\s+-copy$','' `
                        -replace '\(\d+\)$','' `
                        -replace '-\d+$',''           # <-- fixed syntax
                    $BaseKey = $BaseKey.ToLowerInvariant() -replace '[^\p{L}\p{Nd}_-]',''

                    $ExifDate = $null
                    $Source   = $null

                    # 1️⃣ Filename pattern YYYYMMDD_HHMMSS
                    if ([System.IO.Path]::GetFileNameWithoutExtension($File) -match '(\d{8})[_-](\d{6})') {
                        try {
                            $dt = [DateTime]::ParseExact("$($Matches[1])_$($Matches[2])",
                                                         'yyyyMMdd_HHmmss',
                                                         [Globalization.CultureInfo]::InvariantCulture)
                            $ExifDate = $dt.ToString('yyyy:MM:dd HH:mm:ss')
                            $Source   = 'FILENAME'
                        } catch {}
                    }

                    # 2️⃣ XMP side‑car
                    if (-not $ExifDate -and $XMPs.ContainsKey($BaseKey)) {
                        $r = & exiftool -q -m -F -s -s -s "-charset" "filename=UTF8" "-charset" "exif=UTF8" "-EXIF:DateTimeOriginal" $XMPs[$BaseKey] 2>$null
                        $d = ($r | Out-String).Trim()
                        if ($d) {
                            try {
                                $dt = [DateTime]::Parse($d, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AllowWhiteSpaces)
                                $ExifDate = $dt.ToString('yyyy:MM:dd HH:mm:ss')
                                $Source   = 'XMP'
                            } catch {}
                        }
                    }

                    # 3️⃣ Folder date pattern \yyyy-mm-dd\
                    if (-not $ExifDate -and $File -match '\\(\d{4})[-_.](\d{2})[-_.](\d{2})(\\|$)') {
                        try {
                            $dt = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour 12 -Minute 0 -Second 0
                            $ExifDate = $dt.ToString('yyyy:MM:dd HH:mm:ss')
                            $Source   = 'FOLDER'
                        } catch {}
                    }

                    # 4️⃣ File creation time (if plausible)
                    if (-not $ExifDate -and (Test-Path -LiteralPath $File)) {
                        $dt = (Get-Item -LiteralPath $File).CreationTime
                        if ($dt.Year -gt 2000) {
                            $ExifDate = $dt.ToString('yyyy:MM:dd HH:mm:ss')
                            $Source   = 'CREATION'
                        }
                    }

                    # 5️⃣ Last‑resort: copy date from the converted file (minus 1 s)
                    if (-not $ExifDate -and $LastResortDays -gt 0) {
                        $r = & exiftool -q -m -F -s -s -s "-charset" "filename=UTF8" "-charset" "exif=UTF8" "-EXIF:DateTimeOriginal" $Converted 2>$null
                        $d = ($r | Out-String).Trim()
                        if ($d) {
                            try {
                                $dt = [DateTime]::Parse($d, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AllowWhiteSpaces).AddSeconds(-1)
                                $ExifDate = $dt.ToString('yyyy:MM:dd HH:mm:ss')
                                $Source   = 'LASTRESORT'
                            } catch {}
                        }
                    }

                    # ----- Apply the discovered date -----
                    if ($ExifDate) {
                        if ($DryRun) {
                            $LocalRepaired++
                        } else {
                            $args = @(
                                "-q","-m","-F","-overwrite_original_in_place",
                                "-charset","filename=UTF8","-charset","exif=UTF8",
                                "-EXIF:DateTimeOriginal=$ExifDate",
                                "-EXIF:CreateDate=$ExifDate",
                                "-EXIF:ModifyDate=$ExifDate",
                                $Converted
                            )
                            $r = @(& exiftool @args 2>&1 | Out-String)
                            if ($LASTEXITCODE -eq 0) {
                                $LocalRepaired++
                                [void]$LocalDone.Add($Converted)
                            } else {
                                $LocalSkipped++
                                [void]$OperationFailQueue.Add("$File | $Converted | $r")
                            }
                        }
                    } else {
                        # No date could be derived – smart skip
                        $LocalSkipped++
                        [void]$SmartSkipQueue.Add("$File | $Converted")
                    }

                    # ----- Progress bookkeeping -----
                    [System.Threading.Monitor]::Enter($Lock)
                    try {
                        foreach ($i in $LocalDone) { [void]$RepairDoneQueue.Add($i) }
                        $CounterFix.Value += $Batch.Count
                        $Stats.SmartRepaired += $LocalRepaired
                        $Stats.SmartSkipped  += $LocalSkipped
                    } finally {
                        [System.Threading.Monitor]::Exit($Lock)
                    }

                    $CurrentFix = $CounterFix.Value
                    $DoUpdateFix = ((Get-Date) - $LastUpdateFix.Value).TotalMilliseconds -ge 200
                    if ($DoUpdateFix) {
                        $LastUpdateFix.Value = Get-Date
                        # Clamp percent to 0‑100
                        $rawPct = if ($TotalFix -gt 0) { [Math]::Round(($CurrentFix / $TotalFix) * 100, 1) } else { 100 }
                        $PercentFix = [Math]::Min($rawPct,100)

                        $EtaFix = if ($CurrentFix -gt 0) {
                            [TimeSpan]::FromSeconds(
                                ($swFix.Elapsed.TotalSeconds / $CurrentFix) * ($TotalFix - $CurrentFix)
                            )
                        } else { [TimeSpan]::Zero }

                        Write-Progress -Activity "Step 3: Smart Repair" `
                            -PercentComplete $PercentFix `
                            -CurrentOperation "$CurrentFix/$TotalFix REPAIRED:$($Stats.SmartRepaired) SKIPPED:$($Stats.SmartSkipped) ETA:$($EtaFix.ToString('hh\:mm\:ss'))"
                    }
                }
            } -ThrottleLimit $Threads

            Write-Progress -Activity "Step 3: Smart Repair" -Completed
        }

        # Persist smart‑repair results
        if (-not $DryRun) {
            $RepairDoneQueue | Select-Object -Unique | Add-Content -LiteralPath $LogDone -Encoding UTF8
        }
        $SmartSkipQueue | Select-Object -Unique | Add-Content -LiteralPath $LogSmartSkip -Encoding UTF8
    } else {
        Write-Host "Smart repair skipped." -ForegroundColor DarkYellow
    }
}

# -----------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------
Write-Host "`n=== FINISHED ===" -ForegroundColor Green
$Stats | Format-List | Out-Host
