# ==============================================================================
# CONFIGURACIÓN
# ==============================================================================
$targetFolder = "."             # Poné la ruta de la carpeta aquí (ej: "C:\Fotos\WebP") o "." para la carpeta actual
$includeSubfolders = $true      # $true para incluir subcarpetas (recursivo), $false para solo la carpeta elegida
$exiftoolName = "exiftool.exe"
# ==============================================================================

function Install-ExifTool {
    # Chequeamos si ya está en el PATH del sistema o en la carpeta actual
    if (Get-Command $exiftoolName -ErrorAction SilentlyContinue) {
        Write-Host "ExifTool ya está instalado o disponible en el sistema. Seguimos adelante..." -ForegroundColor Cyan
        return
    }

    Write-Host "No encontré ExifTool. Bajándolo ahora mismo desde SourceForge..." -ForegroundColor Yellow
    $url = "https://sourceforge.net/projects/exiftool/files/latest/download" 
    $dest = Join-Path $PSScriptRoot $exiftoolName
    
    try {
        # Invoke-WebRequest fuerza el nombre del archivo al definido en $dest (exiftool.exe)
        Invoke-WebRequest -Uri $url -OutFile $dest
        Write-Host "ExifTool descargado y guardado como $exiftoolName" -ForegroundColor Green
    } catch {
        Write-Error "No pude descargar ExifTool. Fijate que tengas internet o bajalo a mano desde SourceForge."
        exit
    }
}

# 1. Aseguramos que ExifTool esté disponible
Install-ExifTool

# Determinamos la ruta completa de la carpeta objetivo
$fullPath = Resolve-Path $targetFolder

# 2. Armamos el comando de ExifTool
# Si $includeSubfolders es true, agregamos el flag '-r' (recursivo)
$recursiveFlag = if ($includeSubfolders) { "-r" } else { "" }
# Usamos el ejecutable local si no está en el PATH
$exePath = if (Get-Command $exiftoolName -ErrorAction SilentlyContinue) { $exiftoolName } else { ".\$exiftoolName" }

$exifCommand = "$exePath $recursiveFlag -csv -DateTimeOriginal -FileModifyDate -ext webp `"$fullPath`" > metadata.csv"

Write-Host "Analizando archivos en: $fullPath ..." -ForegroundColor Cyan
Invoke-Expression $exifCommand

# 3. Importamos el CSV y procesamos las fechas
if (-not (Test-Path "metadata.csv")) {
    Write-Host "No se encontraron archivos .webp o hubo un error al generar el CSV." -ForegroundColor Red
    exit
}

$rawPhotos = Import-Csv metadata.csv
$processedPhotos = foreach ($photo in $rawPhotos) {
    # Priorizamos la fecha de captura, si no existe, usamos la de modificación del archivo
    $dateString = if ($photo.DateTimeOriginal) { $photo.DateTimeOriginal } else { $photo.FileModifyDate }
    
    try {
        # Convertimos el string de ExifTool (YYYY:MM:DD HH:MM:SS) a objeto DateTime
        $dateObject = [DateTime]::ParseExact($dateString, "yyyy:MM:dd HH:mm:ss", $null)
    } catch {
        Write-Host "Error parseando la fecha de $($photo.SourceFile). Se saltará." -ForegroundColor Yellow
        continue
    }

    [PSCustomObject]@{
        SourceFile   = $photo.SourceFile
        ResolvedDate = $dateObject
    }
}

# 4. Ordenamos la lista de la más vieja a la más nueva
$sortedPhotos = $processedPhotos | Sort-Object ResolvedDate

# 5. Calculamos el relleno (padding) según la cantidad total de fotos
$totalPhotos = $sortedPhotos.Count
if ($totalPhotos -eq 0) {
    Write-Host "No hay fotos para renombrar." -ForegroundColor Yellow
    Remove-Item metadata.csv
    exit
}
$padding = $totalPhotos.ToString().Length

# 6. Recorremos la lista y renombramos
$index = 1
foreach ($photo in $sortedPhotos) {
    # Formateamos la fecha: yyyy-MM-dd.HHmmss
    $formattedDate = $photo.ResolvedDate.ToString("yyyy-MM-dd.HHmmss")

    # Creamos el número con ceros a la izquierda (ej. 001, 002)
    $paddedNum = $index.ToString("D$padding")
    
    # Armamos el nombre final
    $newName = "$paddedNum.$formattedDate.webp"
    
    # Obtenemos la carpeta donde está el archivo para que Rename-Item no lo mueva de lugar
    $currentDir = Split-Path $photo.SourceFile
    
    Write-Host "Renombrando: $(Split-Path $photo.SourceFile -Leaf) -> $newName" -ForegroundColor Gray
    Rename-Item -Path $photo.SourceFile -NewName $newName
    $index++
}

# Limpieza final
Remove-Item metadata.csv
Write-Host "¡Listo! Todo renombrado correctamente." -ForegroundColor Green
