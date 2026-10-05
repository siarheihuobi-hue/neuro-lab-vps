# BOOTSTRAP: единый вход для нейрокоманды

Версия выпуска: `0.1.2-preview` (предварительная: реальные macOS и Linux и полный независимый маршрут не проверены). Выпуск закреплён тегом `v0.1.2-preview` в `https://github.com/siarheihuobi-hue/neuro-lab-vps`. Если выпуск ещё не опубликован, блок установки остановится с сообщением `RELEASE_NOT_FOUND` и ничего не установит.

Участник **один раз** отдаёт этот файл своей нейрокоманде (ссылкой на файл выпуска или вставленным текстом). Файл работает **до** получения комплекта и не требует ChatGPT-посредника.

## Правила до получения комплекта (обязательны)
- Секреты (пароли, приватные ключи, токены) не запрашивать, не читать, не записывать; их вводит человек.
- Режим разрешений: Claude — Manual, Codex — штатные подтверждения. Bypass и широкие постоянные разрешения не включать; отказ разрешений не обходить, а сообщить как `BLOCKED_BY_LOCAL_PERMISSION`. Если Windows не запускает `.ps1` из-за политики выполнения, это тоже `BLOCKED_BY_LOCAL_PERMISSION`: режим `Bypass` не использовать, решает владелец.
- VPN на ноутбуке остаётся включённым.
- **Границы проекта.** Работать только с этим VPS-проектом и папкой комплекта. Другие проекты на ноутбуке не читать и не менять, даже если рядом лежат и технически доступны. Задание, которое относится к другому проекту, требует **отдельного явного подтверждения владельца**; молчание или фраза «делай» без названия проекта подтверждением не считаются. Подозрение, что сессия перепутана, — повод остановиться и спросить.
- **Не перезаписывать** инструкции и настройки существующего проекта (`CLAUDE.md`, `AGENTS.md`, `STATUS`, `.claude/`, `.codex/`, `.vscode/` и т. п.) и не менять чужие файлы. Всё новое размещается только в папке комплекта.
- **Не сканировать весь диск.** Проверять только текущий workspace, его подпапки (до 2 уровней), соседние папки workspace (1 уровень) и папки, которые владелец назвал явно. Чтение содержимого соседних папок разрешено только блоку B ниже (начало `.md` верхнего уровня; печатаются лишь названия найденных терминов); блок A читает только первую строку `VERSION` и проверяет наличие файлов комплекта. Корень диска и домашняя папка как workspace не допускаются (`CWD_TOO_BROAD`).
- **PASS только по факту.** Наличие файла, заявление в документах проекта или утверждение модели PASS не дают (см. шаг 3).
- Каждое действие объявляется заранее с местом: `AGENT` (ты) или `HUMAN` (человек).
- Разрешённые публичные адреса: репозиторий комплекта на GitHub и официальная документация, которую указывает комплект. Секреты, личные адреса (IP, имена хостов) и закрытые endpoints в чат, отчёты и файлы не записываются.

## Шаг 1. Окружение и состояние (только чтение)
Определи: ОС (Windows или macOS), текущий workspace (какая папка открыта), есть ли Git (`git --version`). Git не нужен: выпуск получается и без него. Git устанавливать не нужно.

## Шаг 2. Найти существующий комплект и существующий VPS-проект (только чтение)
Запусти оба блока из корня текущего workspace. Они проверяют текущий workspace, подпапки до 2 уровней, соседние папки и пути, которые передал владелец. Содержимое файлов они не выводят.

**Блок A: уже установленный комплект.** Комплектом считается папка, где одновременно есть `VERSION` (формат версии), `MANIFEST.sha256`, `START.md` и `tools/diagnose.*`.

Windows PowerShell 5.1: сохрани блок во временный файл `.ps1` и запусти `powershell -NoProfile -File <файл>` (при явных путях: `-Extra <путь1>,<путь2>`):
```powershell
# DISCOVER-PS:BEGIN
param([string[]]$Extra = @())
$ErrorActionPreference = 'Stop'
$skip = @('.git', 'node_modules', 'state')
function Test-KitDir([string]$d) {
  $v = Join-Path $d 'VERSION'
  if (-not (Test-Path -LiteralPath $v -PathType Leaf)) { return $null }
  $ver = (Get-Content -LiteralPath $v -TotalCount 1).Trim()
  if ($ver -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$') { return $null }
  foreach ($f in @('MANIFEST.sha256', 'START.md')) { if (-not (Test-Path -LiteralPath (Join-Path $d $f) -PathType Leaf)) { return $null } }
  if (-not ((Test-Path -LiteralPath (Join-Path $d 'tools\diagnose.ps1')) -or (Test-Path -LiteralPath (Join-Path $d 'tools\diagnose.sh')))) { return $null }
  return $ver
}
$cwd = (Get-Location).Path
$parent = Split-Path -Parent $cwd
if ((-not $parent) -or ($cwd.TrimEnd('\') -eq [Environment]::GetFolderPath('UserProfile').TrimEnd('\'))) { Write-Host 'CWD_TOO_BROAD: open the project folder as the workspace, not a drive root or the home folder'; exit 3 }
function Get-SafeDirs([string]$d) {
  return @(Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue | Where-Object { ($skip -notcontains $_.Name) -and (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) })
}
$cands = New-Object System.Collections.ArrayList
[void]$cands.Add($cwd)
foreach ($d1 in (Get-SafeDirs $cwd)) {
  [void]$cands.Add($d1.FullName)
  foreach ($d2 in (Get-SafeDirs $d1.FullName)) { [void]$cands.Add($d2.FullName) }
}
foreach ($s in (Get-SafeDirs $parent)) { [void]$cands.Add($s.FullName) }
foreach ($e in $Extra) { if ($e -and (Test-Path -LiteralPath $e -PathType Container)) { [void]$cands.Add((Resolve-Path -LiteralPath $e).Path) } }
$seen = @{}
$n = 0
foreach ($c in $cands) {
  if ($seen.ContainsKey($c.ToLower())) { continue }
  $seen[$c.ToLower()] = $true
  $ver = Test-KitDir $c
  if ($ver) {
    $n++
    $st = 'no'
    if (Test-Path -LiteralPath (Join-Path $c 'state\stages.tsv')) { $st = 'yes' }
    Write-Host ('CANDIDATE ' + $c + ' version=' + $ver + ' state=' + $st)
  }
}
Write-Host ('DISCOVER_RESULT count=' + $n)
# DISCOVER-PS:END
```

macOS (и Linux): сохрани блок во временный файл и запусти `bash <файл>` (при явных путях: `bash <файл> <путь1> <путь2>`):
```bash
# DISCOVER-SH:BEGIN
set -u
is_kit() {
  d="$1"
  [ -f "$d/VERSION" ] || return 1
  v="$(head -n1 "$d/VERSION" | tr -d '\r ')"
  printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$' || return 1
  [ -f "$d/MANIFEST.sha256" ] && [ -f "$d/START.md" ] || return 1
  [ -f "$d/tools/diagnose.sh" ] || [ -f "$d/tools/diagnose.ps1" ] || return 1
  echo "$v"
}
CWD="$(pwd)"; PARENT="$(dirname "$CWD")"
if [ "$CWD" = "/" ] || [ "$CWD" = "${HOME:-/nonexistent}" ]; then echo "CWD_TOO_BROAD: open the project folder as the workspace, not the filesystem root or the home folder"; exit 3; fi
OUT="$({
  echo "$CWD"
  find "$CWD" -mindepth 1 -maxdepth 2 -type d \( -name .git -o -name node_modules -o -name state \) -prune -o -type d -print 2>/dev/null
  if [ "$PARENT" != "$CWD" ]; then find "$PARENT" -mindepth 1 -maxdepth 1 -type d \( -name .git -o -name node_modules -o -name state \) -prune -o -type d -print 2>/dev/null; fi
  for e in "$@"; do if [ -d "$e" ]; then (cd "$e" && pwd); fi; done
} | awk '!seen[$0]++' | while IFS= read -r c; do
  v="$(is_kit "$c")" || continue
  st=no; [ -f "$c/state/stages.tsv" ] && st=yes
  echo "CANDIDATE $c version=$v state=$st"
done)"
[ -n "$OUT" ] && printf '%s\n' "$OUT"
echo "DISCOVER_RESULT count=$(printf '%s\n' "$OUT" | grep -c '^CANDIDATE')"
# DISCOVER-SH:END
```

**Блок B: существующий VPS-проект без комплекта.** Проект распознаётся **по содержимому, а не по имени**: в верхнем уровне папки в `.md`-файлах (до 12 файлов, первые 64 КБ каждого) встречаются **не менее 3 разных** терминов из списка `VPS`, `Remote-SSH`, `sshd`, `ufw`, `authorized_keys`, `preflight`, `known_hosts`. Блок печатает только путь и названия найденных терминов, а не текст файлов. Папки с комплектом он пропускает.

Windows PowerShell 5.1 (`powershell -NoProfile -File <файл>`, при явных путях `-Extra <путь1>,<путь2>`):
```powershell
# PROJECT-PS:BEGIN
param([string[]]$Extra = @())
$ErrorActionPreference = 'Stop'
$skip = @('.git', 'node_modules', 'state')
$terms = @('VPS', 'Remote-SSH', 'sshd', 'ufw', 'authorized_keys', 'preflight', 'known_hosts')
function Test-IsKit([string]$d) {
  return ((Test-Path -LiteralPath (Join-Path $d 'VERSION') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $d 'MANIFEST.sha256') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $d 'START.md') -PathType Leaf))
}
function Get-Terms([string]$d) {
  $found = @{}
  $files = @(Get-ChildItem -LiteralPath $d -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Select-Object -First 12)
  foreach ($f in $files) {
    $text = ''
    try {
      $fs = [System.IO.File]::OpenRead($f.FullName)
      $buf = New-Object byte[] 65536
      $len = $fs.Read($buf, 0, $buf.Length)
      $fs.Close()
      $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $len)
    } catch { continue }
    foreach ($t in $terms) { if ($text -match ('(?i)' + [regex]::Escape($t))) { $found[$t] = $true } }
  }
  return @($found.Keys | Sort-Object)
}
$cwd = (Get-Location).Path
$parent = Split-Path -Parent $cwd
if ((-not $parent) -or ($cwd.TrimEnd('\') -eq [Environment]::GetFolderPath('UserProfile').TrimEnd('\'))) { Write-Host 'CWD_TOO_BROAD: open the project folder as the workspace, not a drive root or the home folder'; exit 3 }
function Get-SafeDirs([string]$d) {
  return @(Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue | Where-Object { ($skip -notcontains $_.Name) -and (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) })
}
$cands = New-Object System.Collections.ArrayList
[void]$cands.Add($cwd)
foreach ($d1 in (Get-SafeDirs $cwd)) {
  [void]$cands.Add($d1.FullName)
  foreach ($d2 in (Get-SafeDirs $d1.FullName)) { [void]$cands.Add($d2.FullName) }
}
foreach ($s in (Get-SafeDirs $parent)) { [void]$cands.Add($s.FullName) }
foreach ($e in $Extra) { if ($e -and (Test-Path -LiteralPath $e -PathType Container)) { [void]$cands.Add((Resolve-Path -LiteralPath $e).Path) } }
$seen = @{}
$n = 0
foreach ($c in $cands) {
  if ($seen.ContainsKey($c.ToLower())) { continue }
  $seen[$c.ToLower()] = $true
  if (Test-IsKit $c) { continue }
  $hit = Get-Terms $c
  if ($hit.Count -ge 3) { $n++; Write-Host ('PROJECT_CANDIDATE ' + $c + ' terms=' + ($hit -join ',')) }
}
Write-Host ('PROJECT_RESULT count=' + $n)
# PROJECT-PS:END
```

macOS (и Linux) (`bash <файл>`, при явных путях `bash <файл> <путь1> <путь2>`):
```bash
# PROJECT-SH:BEGIN
set -u
TERMS="VPS Remote-SSH sshd ufw authorized_keys preflight known_hosts"
CWD="$(pwd)"; PARENT="$(dirname "$CWD")"
if [ "$CWD" = "/" ] || [ "$CWD" = "${HOME:-/nonexistent}" ]; then echo "CWD_TOO_BROAD: open the project folder as the workspace, not the filesystem root or the home folder"; exit 3; fi
OUT="$({
  echo "$CWD"
  find "$CWD" -mindepth 1 -maxdepth 2 -type d \( -name .git -o -name node_modules -o -name state \) -prune -o -type d -print 2>/dev/null
  if [ "$PARENT" != "$CWD" ]; then find "$PARENT" -mindepth 1 -maxdepth 1 -type d \( -name .git -o -name node_modules -o -name state \) -prune -o -type d -print 2>/dev/null; fi
  for e in "$@"; do if [ -d "$e" ]; then (cd "$e" && pwd); fi; done
} | awk '!seen[$0]++' | while IFS= read -r c; do
  if [ -f "$c/VERSION" ] && [ -f "$c/MANIFEST.sha256" ] && [ -f "$c/START.md" ]; then continue; fi
  TXT="$(find "$c" -maxdepth 1 -type f -name '*.md' 2>/dev/null | head -n 12 | while IFS= read -r f; do head -c 65536 "$f"; echo; done)"
  [ -n "$TXT" ] || continue
  hit=""; n=0
  for t in $TERMS; do
    if printf '%s' "$TXT" | grep -qiF -- "$t"; then hit="$hit${hit:+,}$t"; n=$((n + 1)); fi
  done
  [ "$n" -ge 3 ] && echo "PROJECT_CANDIDATE $c terms=$hit"
done)"
[ -n "$OUT" ] && printf '%s\n' "$OUT"
echo "PROJECT_RESULT count=$(printf '%s\n' "$OUT" | grep -c '^PROJECT_CANDIDATE')"
# PROJECT-SH:END
```

## Шаг 3. Решение о папке
Пути показываются **только владельцу** и в `state/` не записываются.
1. **Блок A нашёл ровно один комплект версии `0.1.2-preview`** → сообщи владельцу и продолжай в нём (ничего не скачивай и не перезаписывай). Если он вне текущего workspace, попроси открыть эту папку в VS Code (File → Open Folder), запустить движок там и повторить фразу участника.
2. **Блок A нашёл один комплект другой версии** → не обновляй сам: спроси владельца (обновление — отдельное решение).
3. **Блок A нашёл несколько комплектов** → задай **один вопрос**: какую папку использовать (варианты с версией и признаком `state`).
4. **Комплекта нет, блок B нашёл ровно один VPS-проект** → назови владельцу проект и найденные термины и получи подтверждение одним словом: установка пишет в папку его проекта, поэтому согласие обязательно. После «да» комплект ставится в **отдельную подпапку** `neuro-lab-vps` этого проекта (шаг 4); файлы проекта, его `CLAUDE.md`, `AGENTS.md`, `STATUS` и конфигурация не меняются и не заменяются, **параллельный VPS-проект не создаётся**.
5. **Комплекта нет, блок B нашёл несколько проектов** → один вопрос: в какой из них продолжать.
6. **Ничего не найдено** → создай новую папку только при отсутствии подходящей: если текущий workspace пуст, комплект ставится в него; иначе в новую подпапку `neuro-lab-vps` текущего workspace. Сообщи путь владельцу до создания.
- **Не любая существующая папка допустима.** Для установки годятся: (1) уже установленный комплект; (2) пустая папка, которую одобрил владелец; (3) новая подпапка (в новом месте или в подтверждённом проекте). Папка с чужим проектом (`CLAUDE.md`, `AGENTS.md`, код, данные) как **корень** комплекта не используется: блок установки откажет (`TARGET_NOT_EMPTY`).

**Связь с проектом и подтверждённые этапы (пункт 4).** После установки и первой диагностики выполни `project_link=parent` (команда в `START.md`). Прочитай документы проекта: этапы, которые они называют выполненными, записываются только как **заявления** (`-Claim`), а не как PASS. Каждое заявление проверяется фактом (read-only проверки, вывод инструментов) или подтверждается словами владельца с источником; только тогда `-Accept`. Наличие файла и утверждение модели PASS не дают.

## Шаг 4. Получить закреплённый выпуск
Хеш архива берётся из файла `.sha256` рядом с архивом в том же выпуске: он защищает от повреждения при загрузке, а подлинность обеспечивают сам репозиторий и закреплённый тег. Перед установкой проверяются имена записей архива (без `..`, абсолютных путей и двоеточий), отсутствие ссылок, непустой манифест строгого формата, совпадение хешей **и** отсутствие файлов вне манифеста. GitHub отдаёт файлы выпуска через собственное хранилище (домены GitHub); разрешёнными считаются только адреса GitHub. Целостность файлов дополнительно проверяется по `MANIFEST.sha256` **до** установки. Файлы комплекта и состояние участника разделены: выпуск содержит только файлы комплекта, а `state/` создаётся на ноутбуке участника и никогда не входит в выпуск, не перезаписывается и не удаляется.

**Вариант A: без Git (основной). Windows, Windows PowerShell 5.1.** Сохрани блок во временный файл `.ps1` и запусти `powershell -NoProfile -File <файл> -Target <папка из шага 3>` (путь передаётся параметром, а не вставляется в текст блока, поэтому апострофы и кавычки в имени папки безопасны):
```powershell
# BOOTSTRAP-PS:BEGIN
param([string]$Target = '<TARGET_FOLDER_PLACEHOLDER>')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Repo   = 'https://github.com/siarheihuobi-hue/neuro-lab-vps'
$Tag    = 'v0.1.2-preview'
$Ver    = '0.1.2-preview'
$Zip    = 'neurokomanda-vps-kit-' + $Ver + '.zip'
if ($Target -like '*PLACEHOLDER*') { throw 'TARGET_NOT_CHOSEN: agree the folder with the owner first; nothing done.' }
function Get-Release([string]$Uri, [string]$Out) {
  try { Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Out }
  catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 404) { throw ('RELEASE_NOT_FOUND: release ' + $Tag + ' is not published at ' + $Repo + ' (yet); nothing installed.') }
    throw ('DOWNLOAD_FAILED: the release file could not be fetched (HTTP ' + $code + ' or no network); nothing installed.')
  }
}
$VerFile = Join-Path $Target 'VERSION'
if (Test-Path -LiteralPath $VerFile) {
  $have = (Get-Content -LiteralPath $VerFile -TotalCount 1).Trim()
  if ($have -eq $Ver) { Write-Host ('ALREADY_INSTALLED ' + $have + ': nothing downloaded, nothing overwritten') }
  else { throw ('DIFFERENT_VERSION_PRESENT ' + $have + ': an update is a separate decision of the owner; nothing changed.') }
}
else {
  if ((Test-Path -LiteralPath $Target) -and (Get-ChildItem -LiteralPath $Target -Force | Select-Object -First 1)) { throw 'TARGET_NOT_EMPTY: not a kit install; choose another folder; nothing changed.' }
  $Tmp = Join-Path ([IO.Path]::GetTempPath()) ('nlvps-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $Tmp | Out-Null
  try {
    $Base = $Repo + '/releases/download/' + $Tag
    Get-Release ($Base + '/' + $Zip) (Join-Path $Tmp $Zip)
    Get-Release ($Base + '/' + $Zip + '.sha256') (Join-Path $Tmp ($Zip + '.sha256'))
    $want = ((Get-Content -LiteralPath (Join-Path $Tmp ($Zip + '.sha256')) -TotalCount 1) -split '\s+')[0].ToLower()
    $got  = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Tmp $Zip)).Hash.ToLower()
    if ($want -ne $got) { throw 'ZIP_HASH_MISMATCH: nothing installed' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $Tmp $Zip))
    $unsafe = 0
    $linkEntries = 0
    foreach ($en in $za.Entries) { if ((($en.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { $linkEntries++ } }
    if ($linkEntries -ne 0) { $za.Dispose(); throw ('ARCHIVE_LINKS entries=' + $linkEntries + ': the archive contains links; nothing installed') }
    foreach ($en in $za.Entries) { if (($en.FullName -match '(^|[/\\])\.\.([/\\]|$)') -or ($en.FullName -match '^[/\\]') -or ($en.FullName -match ':')) { $unsafe++ } }
    $za.Dispose()
    if ($unsafe -ne 0) { throw ('ARCHIVE_UNSAFE_PATHS entries=' + $unsafe + ': nothing installed') }
    $X = Join-Path $Tmp 'x'
    Expand-Archive -LiteralPath (Join-Path $Tmp $Zip) -DestinationPath $X
    if (@(Get-ChildItem -LiteralPath $X -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) { throw 'ARCHIVE_LINKS: the archive contains links; nothing installed' }
    $listed = @{}
    $bad = 0
    $lines = @([System.IO.File]::ReadAllLines((Join-Path $X 'MANIFEST.sha256')) | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -eq 0) { throw 'MANIFEST_MISMATCH empty manifest: nothing installed' }
    foreach ($l in $lines) {
      if (($l -notmatch '^[0-9a-f]{64}  [A-Za-z0-9._/-]+$') -or ($l -match '(^|[ /])\.\.(/|$)') -or $l.Substring(66).StartsWith('/')) { $bad++; continue }
      $rel = $l.Substring(66)
      $listed[$rel] = $true
      $f = Join-Path $X ($rel -replace '/', '\')
      if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $bad++; continue }
      if ((Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower() -ne $l.Substring(0, 64)) { $bad++ }
    }
    $listed['MANIFEST.sha256'] = $true
    $listed['manifest.json'] = $true
    $XL = (Resolve-Path -LiteralPath $X).Path.TrimEnd('\') + '\'
    foreach ($fi in (Get-ChildItem -LiteralPath $X -Recurse -File -Force)) {
      $rel = $fi.FullName.Substring($XL.Length) -replace '\\', '/'
      if (-not $listed.ContainsKey($rel)) { $bad++ }
    }
    if ($bad -ne 0) { throw ('MANIFEST_MISMATCH files=' + $bad + ': nothing installed') }
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target | Out-Null }
    if ((Get-Content -LiteralPath (Join-Path $X 'VERSION') -TotalCount 1).Trim() -ne $Ver) { throw 'MANIFEST_MISMATCH the archive VERSION is not the pinned version: nothing installed' }
    Move-Item -LiteralPath (Join-Path $X 'VERSION') -Destination (Join-Path $Tmp 'VERSION.last')
    Get-ChildItem -LiteralPath $X -Force | Copy-Item -Destination $Target -Recurse
    Copy-Item -LiteralPath (Join-Path $Tmp 'VERSION.last') -Destination (Join-Path $Target 'VERSION')   # written LAST: a folder without VERSION is a failed install
    Write-Host ('INSTALLED ' + $Ver)
  }
  finally { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
# BOOTSTRAP-PS:END
```

**Вариант A: без Git. macOS (и Linux).** Сохрани блок во временный файл и запусти `bash <файл> <папка из шага 3>` (путь — параметр, а не часть текста блока):
```bash
# BOOTSTRAP-SH:BEGIN
set -eu
REPO='https://github.com/siarheihuobi-hue/neuro-lab-vps'
TAG='v0.1.2-preview'
VER='0.1.2-preview'
TARGET="${1:-<TARGET_FOLDER_PLACEHOLDER>}"
ZIP="neurokomanda-vps-kit-$VER.zip"
case "$TARGET" in *PLACEHOLDER*) echo "TARGET_NOT_CHOSEN: agree the folder with the owner first; nothing done."; exit 2 ;; esac
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fetch() {
  code="$(curl -sSL -o "$2" -w '%{http_code}' "$1" 2>/dev/null)" || code=000
  case "$code" in
    200) return 0 ;;
    404) echo "RELEASE_NOT_FOUND: release $TAG is not published at $REPO (yet); nothing installed."; exit 5 ;;
    *) echo "DOWNLOAD_FAILED: the release file could not be fetched (HTTP $code or no network); nothing installed."; exit 5 ;;
  esac
}
if [ -f "$TARGET/VERSION" ]; then
  have="$(head -n1 "$TARGET/VERSION" | tr -d '\r ')"
  if [ "$have" = "$VER" ]; then echo "ALREADY_INSTALLED $have: nothing downloaded, nothing overwritten"; exit 0; fi
  echo "DIFFERENT_VERSION_PRESENT $have: an update is a separate decision of the owner; nothing changed."; exit 3
fi
if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then echo "TARGET_NOT_EMPTY: not a kit install; choose another folder; nothing changed."; exit 3; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BASE="$REPO/releases/download/$TAG"
fetch "$BASE/$ZIP" "$TMP/$ZIP"
fetch "$BASE/$ZIP.sha256" "$TMP/$ZIP.sha256"
want="$(head -n1 "$TMP/$ZIP.sha256" | cut -d' ' -f1 | tr 'A-Z' 'a-z')"; got="$(sha "$TMP/$ZIP")"
[ "$want" = "$got" ] || { echo "ZIP_HASH_MISMATCH: nothing installed"; exit 4; }
unsafe="$(unzip -Z1 "$TMP/$ZIP" | grep -Ec '(^|/)\.\.(/|$)|^/|\\|:' || true)"
[ "$unsafe" -eq 0 ] || { echo "ARCHIVE_UNSAFE_PATHS entries=$unsafe: nothing installed"; exit 4; }
links="$(unzip -Z "$TMP/$ZIP" | grep -c '^l' || true)"
[ "$links" -eq 0 ] || { echo "ARCHIVE_LINKS entries=$links: the archive contains links; nothing installed"; exit 4; }
mkdir "$TMP/x"; unzip -qo "$TMP/$ZIP" -d "$TMP/x"
[ -z "$(find "$TMP/x" -type l)" ] || { echo "ARCHIVE_LINKS: the archive contains links; nothing installed"; exit 4; }
bad=0; total=0
: > "$TMP/listed"
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  total=$((total + 1))
  if ! printf '%s' "$line" | grep -Eq '^[0-9a-f]{64}  [A-Za-z0-9._/-]+$' || printf '%s' "$line" | grep -Eq '(^|[ /])\.\.(/|$)' || [ "$(printf '%s' "$line" | cut -c67)" = "/" ]; then bad=$((bad + 1)); continue; fi
  h="${line%% *}"; rel="${line#*  }"
  echo "$rel" >> "$TMP/listed"
  if [ ! -f "$TMP/x/$rel" ] || [ "$(sha "$TMP/x/$rel")" != "$h" ]; then bad=$((bad + 1)); fi
done < "$TMP/x/MANIFEST.sha256"
[ "$total" -gt 0 ] || { echo "MANIFEST_MISMATCH empty manifest: nothing installed"; exit 4; }
echo "MANIFEST.sha256" >> "$TMP/listed"; echo "manifest.json" >> "$TMP/listed"
( cd "$TMP/x" && find . -type f | sed 's#^\./##' ) | while IFS= read -r f; do grep -qxF -- "$f" "$TMP/listed" || echo "$f"; done > "$TMP/extra"
bad=$((bad + $(wc -l < "$TMP/extra" | tr -d ' ')))
[ "$bad" -eq 0 ] || { echo "MANIFEST_MISMATCH files=$bad: nothing installed"; exit 4; }
[ "$(head -n1 "$TMP/x/VERSION" | tr -d '\r ')" = "$VER" ] || { echo "MANIFEST_MISMATCH the archive VERSION is not the pinned version: nothing installed"; exit 4; }
mkdir -p "$TARGET"; mv "$TMP/x/VERSION" "$TMP/VERSION.last"; cp -R "$TMP/x/." "$TARGET/"
cp "$TMP/VERSION.last" "$TARGET/VERSION"   # written LAST: a folder without VERSION is a failed install
echo "INSTALLED $VER"
# BOOTSTRAP-SH:END
```

**Вариант B: с Git (если Git уже есть).** Только в пустую или несуществующую папку, не внутрь чужого репозитория:
```
git clone --depth 1 --branch v0.1.2-preview https://github.com/siarheihuobi-hue/neuro-lab-vps.git <TARGET_FOLDER_PLACEHOLDER>
```
`.gitattributes` репозитория фиксирует окончания строк LF, поэтому хеши в `MANIFEST.sha256` совпадают и на Windows. После клонирования проверь `MANIFEST.sha256` (шаг 5). `state/` исключён `.gitignore` комплекта: состояние участника не попадёт в коммиты.

## Шаг 5. Проверка версии и целостности
Блок варианта A уже сверил хеш архива и `MANIFEST.sha256` до установки. После установки диагностика (`tools/diagnose.*`, шаг 7) сверит версию и хеши ещё раз. При расхождении: остановись, назови владельцу, чего не хватает; к серверу не переходи.

## Шаг 6. Прочитай правила
Прочитай целиком `TARGET/CLAUDE.md` (Claude) или `TARGET/AGENTS.md` (Codex), затем `TARGET/START.md` и следуй им для работы над маршрутом. Если комплект стоит внутри существующего проекта, **правила и инструкции самого проекта остаются главными для проекта**, а комплект ведёт только маршрут и своё состояние. Посоветуй владельцу открыть папку `TARGET` в VS Code (File → Open Folder) и запускать движок там, чтобы правила комплекта загружались автоматически; продолжить можно и из текущего окна.

## Шаг 7. Диагностика и продолжение
Выполни стартовую диагностику из `START.md` (шаг 2: Windows `powershell -NoProfile -File tools\diagnose.ps1`, macOS `bash tools/diagnose.sh`, из папки `TARGET`) и веди участника по этапам до проверенного приложения. Принятые этапы пропускаются, заявленные проверяются, готовые интервью и карта не повторяются.

## Повторный запуск
Безопасен: если `TARGET` уже содержит эту версию, ничего не скачивается и не перезаписывается; `state/`, принятые этапы и изменения участника остаются нетронутыми. Другая версия — только по решению владельца. Сбой посреди копирования оставляет в `TARGET` часть файлов, но **без `VERSION`** (он копируется последним): следующий запуск не примет это за установленный комплект, а остановится с `TARGET_NOT_EMPTY`. Тогда выбери другую папку; удалять содержимое можно только с явного подтверждения владельца, ставить поверх нельзя. Временную папку блок удаляет сам.

Официальная документация, на которую опирается маршрут: [Remote-SSH в VS Code](https://code.visualstudio.com/docs/remote/ssh).
