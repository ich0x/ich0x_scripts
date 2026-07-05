# ==============================================================================
# CONFIGURACIÓN
# ==============================================================================
$targetFolder = "."             # Ruta de la carpeta (ej: "C:\Fotos") o "." para la actual
$includeSubfolders = $true      # $true para incluir subcarpetas, $false para solo la carpeta elegida
$extensions = "webp,jpg,png"    # Extensiones a procesar (separadas por coma, sin el punto)
$exiftoolName = "exiftool.exe"
# ==============================================================================

function Install-ExifTool {
    # 1. Chequeamos si ya está en el PATH del sistema
    if (Get-Command $exiftoolName -ErrorAction SilentlyContinue) {
        Write-Host "ExifTool ya está instalado en el sistema. Seguimos adelante..." -ForegroundColor Cyan
        return
    }

    # 2. Buscamos si ya existe el exe en la carpeta actual
    $existingExe = Get-ChildItem -Path $PSScriptRoot -Filter "exiftool*.exe" | Select-Object -First 1
    if ($existingExe) {
        Write-Host "Encontré un ejecutable existente: $($existingExe.Name). Configurando..." -ForegroundColor Cyan
        Move-Item -Path $existingExe.FullName -Destination (Join-Path $PSScriptRoot $exiftoolName) -Force
        return
    }

    Write-Host "No encontré ExifTool. Bajando paquete desde SourceForge..." -ForegroundColor Yellow
    $url = "https://sourceforge.net/projects/exiftool/files/latest/download" 
    $downloadPath = Join-Path $PSScriptRoot "exiftool_package"
    
    try {
        Invoke-WebRequest -Uri $url -OutFile $downloadPath
        $tempFolder = Join-Path $PSScriptRoot "exiftool_temp"
        
        try {
            if (-not (Test-Path $tempFolder)) { New-Item -ItemType Directory -Path $tempFolder | Out-Null }
            Expand-Archive -Path $downloadPath -DestinationPath $tempFolder -Force
            
            # Buscamos el EXE y la carpeta de archivos de soporte (exiftool_files)
            $extractedExe = Get-ChildItem -Path $tempFolder -Filter "exiftool*.exe" -Recurse | Select-Object -First 1
            $supportFolder = Get-ChildItem -Path $tempFolder -Filter "exiftool_files" -Recurse -Directory | Select-Object -First 1
            
            if ($extractedExe) {
                # Movemos el EXE
                Move-Item -Path $extractedExe.FullName -Destination (Join-Path $PSScriptRoot $exiftoolName) -Force
                
                # MUY IMPORTANTE: Movemos la carpeta de soporte exiftool_files al lado del exe
                if ($supportFolder) {
                    Move-Item -Path $supportFolder.FullName -Destination $PSScriptRoot -Force
                }
                Write-Host "ExifTool y sus dependencias instaladas correctamente." -ForegroundColor Green
            } else {
                throw "No se encontró el ejecutable dentro del paquete."
            }
        } catch {
            Write-Host "Error al descomprimir. Probando si es un ejecutable directo..." -ForegroundColor Gray
            Move-Item -Path $downloadPath -Destination (Join-Path $PSScriptRoot $exiftoolName) -Force
        }
    } catch {
        Write-Error "Problema crítico instalando ExifTool: $($_.Exception.Message)"
        exit
    } finally {
        if (Test-Path $downloadPath) { Remove-Item $downloadPath -Force }
        if (Test-Path $tempFolder) { Remove-Item $tempFolder -Recurse -Force }
    }
}

# 1. Instalación
Install-ExifTool

$fullPath = Resolve-Path $targetFolder

# 2. Armado dinámico de extensiones
# Convierte "webp,jpg" en "-ext webp -ext jpg"
$extFlags = ""
$extList = $extensions.Split(",").Trim()
foreach ($ext in $extList) {
    $extFlags += "-ext $ext "
}

$recursiveFlag = if ($includeSubfolders) { "-r" } else { "" }
$exePath = if (Get-Command $exiftoolName -ErrorAction SilentlyContinue) { $exiftoolName } else { ".\$exiftoolName" }

# Generamos el CSV
$exifCommand = "$exePath $recursiveFlag $extFlags -csv -DateTimeOriginal -FileModifyDate `"$fullPath`" > metadata.csv"

Write-Host "Analizando archivos con extensiones [$extensions] en: $fullPath ..." -ForegroundColor Cyan
Invoke-Expression $exifCommand

# 3. Procesamiento de datos
if (-not (Test-Path "metadata.csv")) {
    Write-Host "No se encontraron archivos compatibles o hubo un error." -ForegroundColor Red
    exit
}

$rawPhotos = Import-Csv metadata.csv
$processedPhotos = foreach ($photo in $rawPhotos) {
    $dateString = if ($photo.DateTimeOriginal) { $photo.DateTimeOriginal } else { $photo.FileModifyDate }
    
    try {
        $dateObject = [DateTime]::ParseExact($dateString, "yyyy:MM:dd HH:mm:ss", $null)
    } catch {
        Write-Host "Error en fecha de $($photo.SourceFile). Saltando..." -ForegroundColor Yellow
        continue
    }

    [PSCustomObject]@{
        SourceFile   = $photo.SourceFile
        ResolvedDate = $dateObject
        Extension    = [System.IO.Path]::GetExtension($photo.SourceFile)
    }
}

# 4. Ordenamiento
$sortedPhotos = $processedPhotos | Sort-Object ResolvedDate

# 5. Padding
$totalPhotos = $sortedPhotos.Count
if ($totalPhotos -eq 0) {
    Write-Host "No hay archivos para renombrar." -ForegroundColor Yellow
    Remove-Item metadata.csv
    exit
}
$padding = $totalPhotos.ToString().Length

# 6. Renombrado
$index = 1
foreach ($photo in $sortedPhotos) {
    $formattedDate = $photo.ResolvedDate.ToString("yyyy-MM-dd.HHmmss")
    $paddedNum = $index.ToString("D$padding")
    
    # Usamos la extensión original del archivo en lugar de una fija
    $newName = "$paddedNum.$formattedDate$($photo.Extension)"
    
    $currentDir = Split-Path $photo.SourceFile
    
    Write-Host "Renombrando: $(Split-Path $photo.SourceFile -Leaf) -> $newName" -ForegroundColor Gray
    Rename-Item -Path $photo.SourceFile -NewName $newName
    $index++
}

Remove-Item metadata.csv
Write-Host "¡Listo! Todo renombrado correctamente." -ForegroundColor Green
