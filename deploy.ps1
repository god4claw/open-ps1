<#
.SYNOPSIS
    Автодеплой CloakBrowser Pro: venv -> пакет -> лицензия -> бинарь -> smoke-тест.

.DESCRIPTION
    Идемпотентный. Повторный запуск ничего не ломает: существующий venv
    переиспользуется, пакет доводится до последней версии, бинарь не
    перекачивается, если уже стоит нужная версия.

.PARAMETER Path
    Куда ставить. По умолчанию — папка, где лежит сам скрипт.

.PARAMETER LicenseKey
    Ключ cb_*. Если не передан — берётся из CLOAKBROWSER_LICENSE_KEY
    (сначала процесс, потом User-окружение), затем из ~/.cloakbrowser/license.key.

.PARAMETER WithNode
    Дополнительно поставить JS-пакет cloakbrowser через npm.

.PARAMETER SkipBinary
    Не качать Chromium (полезно в CI, где нужен только импорт пакета).

.PARAMETER Recreate
    Снести и пересоздать venv с нуля.

.EXAMPLE
    .\deploy.ps1
.EXAMPLE
    .\deploy.ps1 -LicenseKey cb_xxx -WithNode
.EXAMPLE
    .\deploy.ps1 -Path D:\projects\scraper -Recreate
#>

[CmdletBinding()]
param(
    [string] $Path,
    [string] $LicenseKey,
    [switch] $WithNode,
    [switch] $SkipBinary,
    [switch] $Recreate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- вывод ----

$script:StepNo = 0

function Write-Step {
    param([string] $Message)
    $script:StepNo++
    Write-Host ""
    Write-Host "[$script:StepNo] $Message" -ForegroundColor Cyan
}

function Write-Ok   { param([string] $m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Info { param([string] $m) Write-Host "    ..   $m" -ForegroundColor DarkGray }
function Write-Warn2{ param([string] $m) Write-Host "    !    $m" -ForegroundColor Yellow }

function Fail {
    param([string] $Message, [string] $Hint)
    Write-Host ""
    Write-Host "ОШИБКА: $Message" -ForegroundColor Red
    if ($Hint) { Write-Host "        $Hint" -ForegroundColor Yellow }
    exit 1
}

# ------------------------------------------------------------- пути ----

if (-not $Path) {
    if ($PSScriptRoot) { $Path = $PSScriptRoot } else { $Path = (Get-Location).Path }
}
$Path       = [System.IO.Path]::GetFullPath($Path)
$VenvDir    = Join-Path $Path '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$CloakHome  = Join-Path $env:USERPROFILE '.cloakbrowser'
$KeyFile    = Join-Path $CloakHome 'license.key'

Write-Host ""
Write-Host "CloakBrowser — автодеплой" -ForegroundColor White
Write-Host "Цель: $Path" -ForegroundColor DarkGray

# ------------------------------------------------- 1. системный Python ----

Write-Step "Проверка системного Python"

$sysPython = Get-Command python -ErrorAction SilentlyContinue
if (-not $sysPython) { $sysPython = Get-Command py -ErrorAction SilentlyContinue }
if (-not $sysPython) {
    Fail "Python не найден в PATH." "Поставьте Python 3.9+ с python.org и перезапустите терминал."
}

$verRaw = & $sysPython.Source -c "import sys; print('%d.%d' % sys.version_info[:2])"
if ($LASTEXITCODE -ne 0) { Fail "Не удалось запустить $($sysPython.Source)." }

$verParts = $verRaw.Trim().Split('.')
$major = [int] $verParts[0]
$minor = [int] $verParts[1]
if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 9)) {
    Fail "Нужен Python 3.9+, найден $verRaw." "Обновите Python."
}
Write-Ok "Python $verRaw — $($sysPython.Source)"

# ------------------------------------------------------- 2. резолв ключа ----

Write-Step "Резолв лицензионного ключа"

function Read-KeyFile {
    param([string] $FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    # utf-8-sig: срезает BOM, если файл писали через Set-Content -Encoding utf8
    $text = [System.IO.File]::ReadAllText($FilePath, (New-Object System.Text.UTF8Encoding($true)))
    $text = $text.Trim([char]0xFEFF, ' ', "`t", "`r", "`n")
    if ($text) { return $text } else { return $null }
}

if (-not $LicenseKey) { $LicenseKey = $env:CLOAKBROWSER_LICENSE_KEY }
if (-not $LicenseKey) { $LicenseKey = [Environment]::GetEnvironmentVariable('CLOAKBROWSER_LICENSE_KEY', 'User') }
if (-not $LicenseKey) { $LicenseKey = Read-KeyFile $KeyFile }

if (-not $LicenseKey) {
    Fail "Лицензионный ключ не найден." "Передайте -LicenseKey cb_... либо задайте CLOAKBROWSER_LICENSE_KEY."
}

$LicenseKey = $LicenseKey.Trim()
if ($LicenseKey -notmatch '^cb_[0-9a-fA-F]{32}$') {
    Write-Warn2 "Ключ не похож на формат cb_ + 32 hex — продолжаю, сервер решит."
}
$masked = $LicenseKey.Substring(0, [Math]::Min(7, $LicenseKey.Length)) + '...' + $LicenseKey.Substring($LicenseKey.Length - 4)
Write-Ok "Ключ: $masked"

# --------------------------------------------------------- 3. каталоги ----

Write-Step "Подготовка каталогов"

if (-not (Test-Path $Path))      { New-Item -ItemType Directory -Force $Path      | Out-Null }
if (-not (Test-Path $CloakHome)) { New-Item -ItemType Directory -Force $CloakHome | Out-Null }
Write-Ok "$Path"
Write-Ok "$CloakHome"

# ------------------------------------------------------------- 4. venv ----

Write-Step "Виртуальное окружение"

if ($Recreate -and (Test-Path $VenvDir)) {
    Write-Info "-Recreate: удаляю существующий venv"
    Remove-Item -Recurse -Force $VenvDir
}

if (Test-Path $VenvPython) {
    Write-Ok "venv уже есть — переиспользую"
} else {
    Write-Info "создаю venv (займёт ~10 сек)"
    & $sysPython.Source -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { Fail "Не удалось создать venv в $VenvDir." }
    Write-Ok "создан: $VenvDir"
}

if (-not (Test-Path $VenvPython)) { Fail "venv создан, но $VenvPython отсутствует." }

# ----------------------------------------------------------- 5. пакеты ----

Write-Step "Установка cloakbrowser (Python)"

Write-Info "обновляю pip"
& $VenvPython -m pip install --upgrade pip --quiet --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { Write-Warn2 "pip обновить не вышло — продолжаю" }

Write-Info "ставлю cloakbrowser (тянет playwright ~38 МБ, пара минут)"
& $VenvPython -m pip install --upgrade cloakbrowser --disable-pip-version-check
if ($LASTEXITCODE -ne 0) { Fail "pip install cloakbrowser упал." "Проверьте сеть/прокси." }

$pkgVer = & $VenvPython -c "import cloakbrowser, importlib.metadata as m; print(m.version('cloakbrowser'))"
if ($LASTEXITCODE -ne 0) { Fail "Пакет установлен, но не импортируется." }
Write-Ok "cloakbrowser $($pkgVer.Trim())"

# ---------------------------------------------------------- 6. лицензия ----

Write-Step "Валидация лицензии"

# Сначала проверяем, и только потом сохраняем. Иначе невалидный ключ,
# переданный через -LicenseKey, затрёт рабочий в keyfile и в User-окружении.
$env:CLOAKBROWSER_LICENSE_KEY = $LicenseKey

$licJson = & $VenvPython -c "import os,json,cloakbrowser as c; i=c.validate_license(os.environ['CLOAKBROWSER_LICENSE_KEY']); print(json.dumps({'valid':i.valid,'plan':i.plan,'expires':i.expires}))"
if ($LASTEXITCODE -ne 0) { Fail "Не удалось проверить лицензию." "Сервер cloakbrowser.dev недоступен?" }

$lic = $licJson | ConvertFrom-Json
if (-not $lic.valid) {
    $env:CLOAKBROWSER_LICENSE_KEY = $null
    Fail "Сервер отклонил ключ (plan=$($lic.plan)). Ничего не перезаписано." "Проверьте ключ в письме или напишите support@cloakbrowser.dev."
}
if ($null -eq $lic.expires) { $expText = 'без даты окончания' } else { $expText = $lic.expires }
Write-Ok "Лицензия валидна: plan=$($lic.plan), expires=$expText"

Write-Step "Сохранение ключа"

# БЕЗ BOM: UTF8Encoding($false). Set-Content -Encoding utf8 в PS 5.1 пишет BOM,
# он попадает в начало ключа и лицензия не проходит.
[System.IO.File]::WriteAllText($KeyFile, $LicenseKey, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "keyfile: $KeyFile"

[Environment]::SetEnvironmentVariable('CLOAKBROWSER_LICENSE_KEY', $LicenseKey, 'User')
Write-Ok "CLOAKBROWSER_LICENSE_KEY записан в User-окружение"

# ------------------------------------------------------------ 7. бинарь ----

if ($SkipBinary) {
    Write-Step "Chromium — пропущен (-SkipBinary)"
} else {
    Write-Step "Stealth Chromium"
    Write-Info "проверяю/качаю бинарь (первый раз — несколько минут)"
    $binPath = & $VenvPython -c "import cloakbrowser as c; print(c.ensure_binary())"
    if ($LASTEXITCODE -ne 0) { Fail "Не удалось получить бинарь Chromium." }
    Write-Ok "$($binPath.Trim())"
}

# -------------------------------------------------------------- 8. JS ----

if ($WithNode) {
    Write-Step "JS-пакет cloakbrowser"
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        Write-Warn2 "npm не найден — пропускаю JS-часть"
    } else {
        Push-Location $Path
        try {
            if (-not (Test-Path (Join-Path $Path 'package.json'))) {
                Write-Info "npm init -y"
                & npm init -y --silent | Out-Null
            }
            Write-Info "npm install cloakbrowser"
            & npm install cloakbrowser --silent
            if ($LASTEXITCODE -ne 0) { Write-Warn2 "npm install вернул ошибку" } else { Write-Ok "JS-пакет установлен" }
        } finally {
            Pop-Location
        }
    }
}

# --------------------------------------------------------- 9. smoke-тест ----

Write-Step "Smoke-тест (headless, реальный переход на example.com)"

$smoke = Join-Path ([System.IO.Path]::GetTempPath()) "cloak_smoke_$PID.py"
$smokeCode = @'
import os
import sys
from pathlib import Path

from cloakbrowser import launch

key = os.environ.get("CLOAKBROWSER_LICENSE_KEY")
if not key:
    kf = Path.home() / ".cloakbrowser" / "license.key"
    key = kf.read_text(encoding="utf-8-sig").strip() if kf.is_file() else None

if not key:
    print("SMOKE-FAIL: ключ не найден", file=sys.stderr)
    raise SystemExit(1)

browser = launch(license_key=key, headless=True)
try:
    page = browser.new_page()
    page.goto("https://example.com", timeout=60000)
    title = page.title()
finally:
    browser.close()

print(f"SMOKE-OK: {title}")
raise SystemExit(0 if title else 1)
'@

[System.IO.File]::WriteAllText($smoke, $smokeCode, (New-Object System.Text.UTF8Encoding($false)))
try {
    & $VenvPython $smoke
    $smokeExit = $LASTEXITCODE
} finally {
    Remove-Item $smoke -Force -ErrorAction SilentlyContinue
}

if ($smokeExit -ne 0) {
    Fail "Smoke-тест не прошёл." "Запустите '.\.venv\Scripts\python.exe -m cloakbrowser info' для диагностики."
}
Write-Ok "браузер стартует и ходит в сеть"

# ------------------------------------------------------------- 10. итог ----

Write-Step "Готово"

& $VenvPython -m cloakbrowser info

Write-Host ""
Write-Host "Запуск:" -ForegroundColor White
Write-Host "  cd `"$Path`""              -ForegroundColor Gray
Write-Host "  .\.venv\Scripts\python.exe example.py" -ForegroundColor Gray
Write-Host ""
Write-Host "Переменная CLOAKBROWSER_LICENSE_KEY подхватится в НОВЫХ терминалах." -ForegroundColor DarkGray
Write-Host ""

exit 0
