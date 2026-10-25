param(
    [Parameter(Mandatory=$true)][string]$GameRoot,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'

function Assert-GameClosed {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('ArcheAgeChronicles','xldr_ArcheageChronicles_GL_loader_x64') -or $_.ProcessName -like 'X5*'
    })
    if ($running.Count -gt 0) { throw 'Сначала закройте демо обычным способом, затем запустите этот файл ещё раз.' }
}

function Test-BytesEqual([byte[]]$A,[byte[]]$B) {
    if ($A.Length -ne $B.Length) { return $false }
    for ($i=0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Read-Settings([byte[]]$Bytes) {
    $skip=0; $preamble=[byte[]]@(); $encoding=$null
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
        $encoding=[Text.UTF32Encoding]::new($false,$false,$true); $skip=4
    } elseif ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255) {
        $encoding=[Text.UTF32Encoding]::new($true,$false,$true); $skip=4
    } elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $encoding=[Text.UTF8Encoding]::new($false,$true); $skip=3
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        $encoding=[Text.UnicodeEncoding]::new($false,$false,$true); $skip=2
    } elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        $encoding=[Text.UnicodeEncoding]::new($true,$false,$true); $skip=2
    } else {
        $encoding=[Text.UTF8Encoding]::new($false,$true)
        try { $null=$encoding.GetString($Bytes) } catch {
            $encoding=[Text.Encoding]::GetEncoding([Text.Encoding]::Default.CodePage,[Text.EncoderExceptionFallback]::new(),[Text.DecoderExceptionFallback]::new())
        }
        if ($Bytes -contains 0) {
            # Unmarked UTF16 is accepted only when exactly one decoding has an
            # INI section and no embedded NUL. Ambiguous data is not rewritten.
            $candidates=@()
            if (($Bytes.Length % 2) -eq 0) {
                foreach ($bigEndian in @($false,$true)) {
                    $candidate=[Text.UnicodeEncoding]::new($bigEndian,$false,$true)
                    try {
                        $decoded=$candidate.GetString($Bytes)
                        if (-not $decoded.Contains([string][char]0) -and $decoded -match '(?m)^[ \t]*\[[^\]\r\n]+\]') { $candidates+=,$candidate }
                    } catch { }
                }
            }
            if ($candidates.Count -ne 1) { throw 'Не удалось однозначно определить кодировку файла настроек. Файл не изменён.' }
            $encoding=$candidates[0]
        }
    }
    if ($skip -gt 0) { $preamble=[byte[]]$Bytes[0..($skip-1)] }
    $value=$encoding.GetString($Bytes,$skip,$Bytes.Length-$skip)
    if ($value.Contains([string][char]0)) { throw 'В файле настроек обнаружены недопустимые нулевые символы. Файл не изменён.' }
    $roundTrip=[byte[]]($preamble+$encoding.GetBytes($value))
    if (-not (Test-BytesEqual $Bytes $roundTrip)) { throw 'Не удалось сохранить исходную кодировку настроек. Файл не изменён.' }
    return [pscustomobject]@{ Text=$value; Encoding=$encoding; Preamble=$preamble }
}

function Set-RussianCulture([string]$Text) {
    $newline=[regex]::Match($Text,'\r\n|\r|\n').Value
    if (-not $newline) { $newline="`r`n" }
    $lines=[Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text,'([^\r\n]*)(\r\n|\r|\n|$)')) {
        if ($match.Length -gt 0) { $lines.Add([pscustomobject]@{ Value=$match.Groups[1].Value; Eol=$match.Groups[2].Value }) }
    }
    $inSection=$false; $sectionStart=-1; $sectionEnd=-1
    $cultureIndices=[Collections.Generic.List[int]]::new()
    for ($i=0; $i -lt $lines.Count; $i++) {
        $section=[regex]::Match($lines[$i].Value,'^[ \t]*\[([^\]]+)\]')
        if ($section.Success) {
            if ($inSection -and $sectionEnd -lt 0) { $sectionEnd=$i }
            $inSection=$section.Groups[1].Value.Trim() -ieq 'Internationalization'
            if ($inSection -and $sectionStart -lt 0) { $sectionStart=$i }
        } elseif ($inSection -and $lines[$i].Value -match '^[ \t]*Culture[ \t]*=') {
            $cultureIndices.Add($i)
        }
    }
    if ($cultureIndices.Count -gt 0) {
        $lines[$cultureIndices[0]].Value='Culture=ru'
        for ($j=$cultureIndices.Count-1; $j -ge 1; $j--) { $lines.RemoveAt($cultureIndices[$j]) }
    } elseif ($sectionStart -ge 0) {
        if ($sectionEnd -lt 0) { $sectionEnd=$lines.Count }
        $cultureEol=$newline
        if ($sectionEnd -eq $lines.Count -and $lines.Count -gt 0 -and -not $lines[$lines.Count-1].Eol) { $cultureEol='' }
        if ($sectionEnd -gt 0 -and -not $lines[$sectionEnd-1].Eol) { $lines[$sectionEnd-1].Eol=$newline }
        $lines.Insert($sectionEnd,[pscustomobject]@{ Value='Culture=ru'; Eol=$cultureEol })
    } else {
        $lastEol=$newline
        if ($lines.Count -gt 0 -and -not $lines[$lines.Count-1].Eol) { $lines[$lines.Count-1].Eol=$newline; $lastEol='' }
        $lines.Add([pscustomobject]@{ Value='[Internationalization]'; Eol=$newline })
        $lines.Add([pscustomobject]@{ Value='Culture=ru'; Eol=$lastEol })
    }
    $builder=[Text.StringBuilder]::new()
    foreach ($line in $lines) { $null=$builder.Append($line.Value).Append($line.Eol) }
    return $builder.ToString()
}

$tempPath=$null
$tempOwned=$false
try {
    Assert-GameClosed
    $rootPath=[IO.Path]::GetFullPath($GameRoot)
    if (-not [IO.Directory]::Exists($rootPath)) { throw 'Папка игры не найдена. Скопируйте файлы перевода в папку демо.' }
    $exeAtRoot=Join-Path $rootPath 'ArcheAgeChronicles.exe'
    $exeInBin=Join-Path $rootPath 'X5\Binaries\Win64\ArcheAgeChronicles.exe'
    if (-not ([IO.File]::Exists($exeAtRoot) -or [IO.File]::Exists($exeInBin))) { throw 'Не найден ArcheAgeChronicles.exe. Запускайте этот файл из папки демо.' }
    $manifestPath=Join-Path $rootPath 'release-manifest.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'Не найден release-manifest.json. Скопируйте в папку демо всё содержимое архива перевода.' }
    $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.version -ne '8' -or $manifest.steam_app_id -ne 5280930 -or $manifest.steam_build_id -ne 26020644) { throw 'Этот пакет перевода предназначен для другой версии демо.' }
    $allowed=@(
        'X5/Content/Localization/String/ru/String.locres',
        'Engine/Plugins/Online/OnlineSubsystem/Content/Localization/OnlineSubsystem/ru/OnlineSubsystem.locres',
        'Engine/Plugins/Online/OnlineSubsystemSteam/Content/Localization/OnlineSubsystemSteam/ru/OnlineSubsystemSteam.locres',
        'Engine/Plugins/Online/OnlineSubsystemUtils/Content/Localization/OnlineSubsystemUtils/ru/OnlineSubsystemUtils.locres',
        'X5/Plugins/XeSS/Content/Localization/XeSS/ru/XeSS.locres'
    )
    $files=@($manifest.files)
    if ($files.Count -ne 5) { throw 'В списке файлов перевода должно быть ровно пять ресурсов.' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rootPrefix=$rootPath.TrimEnd([char[]]'\/')+[IO.Path]::DirectorySeparatorChar
    foreach ($file in $files) {
        if ($file.path -isnot [string] -or $allowed -cnotcontains $file.path -or -not $seen.Add($file.path)) { throw 'В списке перевода обнаружен недопустимый или повторяющийся путь.' }
        if ($file.sha256 -isnot [string] -or $file.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'В списке перевода отсутствует корректная контрольная сумма.' }
        $payload=[IO.Path]::GetFullPath((Join-Path $rootPath $file.path.Replace('/','\')))
        if (-not $payload.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Путь файла перевода выходит за пределы папки игры.' }
        if (-not [IO.File]::Exists($payload)) { throw ('Не найден файл перевода: '+$file.path+'. Скопируйте всё содержимое архива.') }
        if ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -ne $file.sha256) { throw ('Файл перевода повреждён или отличается от пакета: '+$file.path) }
    }
    if (-not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { throw 'Не найдена пользовательская папка настроек LOCALAPPDATA.' }
    $settingsPath=Join-Path ([IO.Path]::GetFullPath($env:LOCALAPPDATA)) 'X5\Saved\Config\Windows\GameUserSettings.ini'
    if ([IO.Directory]::Exists($settingsPath)) { throw 'Вместо файла настроек обнаружена папка. Настройки не изменены.' }
    $existed=[IO.File]::Exists($settingsPath)
    if ($existed) { $oldBytes=[IO.File]::ReadAllBytes($settingsPath) } else { $oldBytes=[byte[]]@() }
    $settings=Read-Settings $oldBytes
    $newText=Set-RussianCulture $settings.Text
    $newBytes=[byte[]]($settings.Preamble+$settings.Encoding.GetBytes($newText))
    if ($ValidateOnly) { Write-Host 'Проверка пройдена: пять файлов перевода на месте. Настройки не изменены.'; exit 0 }
    if ($existed -and (Test-BytesEqual $oldBytes $newBytes)) { Write-Host 'Русский язык уже включён. Демо можно запускать обычным способом.'; exit 0 }
    Assert-GameClosed
    $settingsDirectory=[IO.Path]::GetDirectoryName($settingsPath)
    $null=[IO.Directory]::CreateDirectory($settingsDirectory)
    $tempPath=Join-Path $settingsDirectory ('GameUserSettings.ini.ru-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    $stream=[IO.File]::Open($tempPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $tempOwned=$true
    try { $stream.Write($newBytes,0,$newBytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    Assert-GameClosed
    if ($existed) {
        if (-not [IO.File]::Exists($settingsPath) -or -not (Test-BytesEqual $oldBytes ([IO.File]::ReadAllBytes($settingsPath)))) { throw 'Настройки изменились во время проверки. Закройте демо и повторите запуск.' }
        [IO.File]::Replace($tempPath,$settingsPath,[System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($tempPath,$settingsPath)
    }
    $tempPath=$null
    $tempOwned=$false
    Write-Host 'Готово! Русский язык включён. Запустите демо обычным способом.'
    exit 0
} catch {
    Write-Host ('Не удалось включить русский язык: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($tempOwned -and $tempPath -and [IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
}
