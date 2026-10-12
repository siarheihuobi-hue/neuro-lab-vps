# BOOTSTRAP: единый вход для нейрокоманды

Версия выпуска: `0.2.0-preview` (предварительная: реальные macOS и Linux и полный независимый маршрут не проверены). Выпуск закреплён тегом `v0.2.0-preview` в `https://github.com/siarheihuobi-hue/neuro-lab-vps`. Если выпуск ещё не опубликован, блок установки остановится с сообщением `RELEASE_NOT_FOUND` и ничего не установит.

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
$skip = @('.git', 'node_modules', 'state', '.upgrade-backups')
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
  find "$CWD" -mindepth 1 -maxdepth 2 -type d \( -name .git -o -name node_modules -o -name state -o -name .upgrade-backups \) -prune -o -type d -print 2>/dev/null
  if [ "$PARENT" != "$CWD" ]; then find "$PARENT" -mindepth 1 -maxdepth 1 -type d \( -name .git -o -name node_modules -o -name state -o -name .upgrade-backups \) -prune -o -type d -print 2>/dev/null; fi
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
$skip = @('.git', 'node_modules', 'state', '.upgrade-backups')
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
  find "$CWD" -mindepth 1 -maxdepth 2 -type d \( -name .git -o -name node_modules -o -name state -o -name .upgrade-backups \) -prune -o -type d -print 2>/dev/null
  if [ "$PARENT" != "$CWD" ]; then find "$PARENT" -mindepth 1 -maxdepth 1 -type d \( -name .git -o -name node_modules -o -name state -o -name .upgrade-backups \) -prune -o -type d -print 2>/dev/null; fi
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
1. **Блок A нашёл ровно один комплект версии `0.2.0-preview`** → сообщи владельцу и продолжай в нём (ничего не скачивай и не перезаписывай). Если он вне текущего workspace, попроси открыть эту папку в VS Code (File → Open Folder), запустить движок там и повторить фразу участника.
2. **Блок A нашёл один комплект другой версии** → не обновляй молча: спроси владельца (обновление — отдельное решение) и предложи процедуру из раздела «Обновление» ниже: резервная копия, проверка новой версии, миграция состояния, возможность отката. Состояние, проекты и ключи при этом не затираются.
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
$Tag    = 'v0.2.0-preview'
$Ver    = '0.2.0-preview'
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
  else { throw ('DIFFERENT_VERSION_PRESENT ' + $have + ': an update is a separate decision of the owner (see the Update section of BOOTSTRAP.md); nothing changed.') }
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
TAG='v0.2.0-preview'
VER='0.2.0-preview'
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
  echo "DIFFERENT_VERSION_PRESENT $have: an update is a separate decision of the owner (see the Update section of BOOTSTRAP.md); nothing changed."; exit 3
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
git clone --depth 1 --branch v0.2.0-preview https://github.com/siarheihuobi-hue/neuro-lab-vps.git <TARGET_FOLDER_PLACEHOLDER>
```
`.gitattributes` репозитория фиксирует окончания строк LF, поэтому хеши в `MANIFEST.sha256` совпадают и на Windows. После клонирования проверь `MANIFEST.sha256` (шаг 5). `state/` исключён `.gitignore` комплекта: состояние участника не попадёт в коммиты.

## Обновление с предыдущей версии (например, с 0.1.2-preview)

Обновление — отдельное решение владельца; делается только в уже установленном комплекте и **там, где он лежит**: в текущем локальном или удалённом workspace. Если комплект уже на VPS и окно Remote-SSH открыто, обновляй его в терминале этого окна (блок для bash), не создавай локальный дубликат и не открывай новое соединение с сервером без необходимости; если комплект на ноутбуке — на ноутбуке (Windows — блок PowerShell, macOS — блок bash). Обновление меняет только файлы комплекта: системные настройки сервера оно не меняет и пакеты не устанавливает (если нужного инструмента нет, блок остановится без изменений: `TOOLS_MISSING`). Следующий этап безопасности (файрвол, SSH) требует отдельного согласия и обновлением не включается. Порядок встроен в блок и не пропускается: **проверка новой версии → резервная копия → применение → миграция состояния → проверка → продолжение; при любом сбое после резервной копии откат выполняется автоматически.**

- **Проверка новой версии до любых изменений.** Блок скачивает закреплённый выпуск, сверяет хеш архива, имена записей, отсутствие ссылок и файлов вне манифеста, совпадение каждого файла с `MANIFEST.sha256`. Нет сети, нет выпуска (`RELEASE_NOT_FOUND`, `DOWNLOAD_FAILED`) или проверка не прошла — **ничего не изменено**.
- **Резервная копия** лежит внутри папки комплекта: `.upgrade-backups/<прежняя-версия>-<время>/` (файлы прежней версии из её манифеста, `state/`, `VERSION.old`). Её файл версии намеренно называется `VERSION.old`, чтобы поиск комплекта не принял копию за установленный комплект.
- **Что не затрагивается:** сам VPS (блок не подключается к серверу, не читает и не меняет SSH, ключи, файрвол, пользователей и настройки сервера); принятые этапы (они не запускаются заново: в плане остаются `SKIP`); `state/` (кроме миграции), ключи и настройки SSH, проекты и любые ваши файлы в папке комплекта, которых нет в манифесте. Заменяются только файлы комплекта по манифесту; если вы правили такой файл, блок сообщит имя (`LOCAL_MODIFIED`), а прежнее содержимое останется в резервной копии. Опубликованный тег прежней версии не меняется.
- **Миграция состояния:** новая диагностика (`-Migrate` / `--migrate`) создаёт схему 2 (`meta.tsv`, `facts.tsv`): пройденные этапы сохраняются, а факты получают источник `migrated`; копия старых `stages.tsv` и `answers.tsv` лежит в `state/backup-schema1/`. Принятые этапы не сбрасываются, интервью и карта не повторяются.
- **Откат:** `ROLLED_BACK <версия>` возвращает файлы и `state/` к состоянию до обновления (кроме файлов комплекта, которые вы сами удалили до обновления: они остаются файлами новой версии; файлы, которых в прежней версии не было, при откате удаляются); состояние на момент отката сохраняется внутри резервной копии (`state-before-rollback-...`). Ручной откат: запустить тот же блок со вторым параметром — именем резервной копии (PowerShell `-Rollback <имя>`, bash вторым аргументом).
- **Нет скрытых режимов.** В блоках и в скриптах диагностики нет переменных окружения, которые подменяют ОС, источник выпуска, найденные инструменты или результат проверки; сбой для проверок комплекта имитируется только в отдельных тестовых копиях, которые в поставку не входят.
- **Версия новее установленной не откатывается:** блок откажет (`DOWNGRADE_REFUSED`). Уже актуальная версия — `ALREADY_CURRENT`, ничего не скачивается.

Windows PowerShell 5.1 (`powershell -NoProfile -File <файл> -Target <папка комплекта>`; откат: добавить `-Rollback <имя-копии>`):
```powershell
# UPGRADE-PS:BEGIN
param([string]$Target = '<TARGET_FOLDER_PLACEHOLDER>', [string]$Rollback = '')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Repo   = 'https://github.com/siarheihuobi-hue/neuro-lab-vps'
$Tag    = 'v0.2.0-preview'
$Ver    = '0.2.0-preview'
$Zip    = 'neurokomanda-vps-kit-' + $Ver + '.zip'
if ($Target -like '*PLACEHOLDER*') { throw 'TARGET_NOT_CHOSEN: agree the folder with the owner first; nothing done.' }
$Backups = Join-Path $Target '.upgrade-backups'
foreach ($rp in @($Target, (Join-Path $Target 'state'))) {
  if ((Test-Path -LiteralPath $rp) -and ((Get-Item -LiteralPath $rp -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LINK_REFUSED: the kit folder or its state folder is a link or junction; nothing changed.' }
}

function Read-Manifest([string]$path) {
  $h = [ordered]@{}
  $bad = 0
  foreach ($l in [System.IO.File]::ReadAllLines($path)) {
    if ($l.Trim().Length -eq 0) { continue }
    if (($l -notmatch '^[0-9a-f]{64}  [A-Za-z0-9._/-]+$') -or ($l -match '(^|[ /])\.\.(/|$)') -or $l.Substring(66).StartsWith('/')) { $bad++; continue }
    $h[$l.Substring(66)] = $l.Substring(0, 64)
  }
  if (($bad -ne 0) -or ($h.Count -eq 0)) { throw 'MANIFEST_MISMATCH empty or malformed manifest: nothing changed' }
  return $h
}
function Fhash([string]$p) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
function To-Path([string]$root, [string]$rel) { return (Join-Path $root ($rel -replace '/', '\')) }
function Copy-Rel([string]$srcRoot, [string]$dstRoot, [string]$rel) {
  $s = To-Path $srcRoot $rel
  if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { return }
  $d = To-Path $dstRoot $rel
  $dir = Split-Path -Parent $d
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Copy-Item -LiteralPath $s -Destination $d -Force
}
function Ver-Gt([string]$a, [string]$b) {
  $x = @(); $y = @()
  if ($a -match '^([0-9]+)\.([0-9]+)\.([0-9]+)') { $x = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) } else { throw 'NOT_A_KIT: unreadable version' }
  if ($b -match '^([0-9]+)\.([0-9]+)\.([0-9]+)') { $y = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
  for ($i = 0; $i -lt 3; $i++) { if ($x[$i] -gt $y[$i]) { return $true }; if ($x[$i] -lt $y[$i]) { return $false } }
  return $false
}
# Restores the old kit files and the state exactly as they were before the upgrade; the current state is kept as a snapshot inside the backup.
function Do-Rollback([string]$bk, [string[]]$extraRemove) {
  if (-not (Test-Path -LiteralPath (Join-Path $bk 'VERSION.old'))) { throw 'ROLLBACK_BACKUP_INVALID: no VERSION.old' }
  $oldMan = Read-Manifest (Join-Path $bk 'MANIFEST.sha256')
  $oldVer = ([System.IO.File]::ReadAllLines((Join-Path $bk 'VERSION.old')))[0].Trim()
  $stNow = Join-Path $Target 'state'
  if (Test-Path -LiteralPath $stNow) {
    $snap = Join-Path $bk ('state-before-rollback-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    Copy-Item -LiteralPath $stNow -Destination $snap -Recurse -Force
  }
  $rm = New-Object System.Collections.ArrayList
  $cm = Join-Path $Target 'MANIFEST.sha256'
  if (Test-Path -LiteralPath $cm) { try { $cur = Read-Manifest $cm; foreach ($k in $cur.Keys) { [void]$rm.Add($k) } } catch { } }
  foreach ($k in $extraRemove) { if ($k) { [void]$rm.Add($k) } }
  foreach ($k in $rm) {
    if (-not $oldMan.Contains($k)) { $p = To-Path $Target $k; if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force } }
  }
  foreach ($k in $oldMan.Keys) { Copy-Rel $bk $Target $k }
  foreach ($k in @('MANIFEST.sha256', 'manifest.json')) { if (Test-Path -LiteralPath (Join-Path $bk $k)) { Copy-Item -LiteralPath (Join-Path $bk $k) -Destination (Join-Path $Target $k) -Force } }
  if (Test-Path -LiteralPath $stNow) { Remove-Item -LiteralPath $stNow -Recurse -Force }
  $stOld = Join-Path $bk 'state'
  if (Test-Path -LiteralPath $stOld) { Copy-Item -LiteralPath $stOld -Destination $stNow -Recurse -Force }
  Copy-Item -LiteralPath (Join-Path $bk 'VERSION.old') -Destination (Join-Path $Target 'VERSION') -Force   # written LAST
  return $oldVer
}

if ($Rollback) {
  if (($Rollback -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') -or ($Rollback -match '\.\.')) { throw 'ROLLBACK_NAME_INVALID' }
  $bk0 = Join-Path $Backups $Rollback
  if (-not (Test-Path -LiteralPath $bk0 -PathType Container)) { throw 'ROLLBACK_BACKUP_NOT_FOUND: nothing changed' }
  $ov = Do-Rollback $bk0 @()
  Write-Host ('ROLLED_BACK ' + $ov)
  exit 0
}

foreach ($f in @('VERSION', 'MANIFEST.sha256', 'START.md')) {
  if (-not (Test-Path -LiteralPath (Join-Path $Target $f) -PathType Leaf)) { throw 'NOT_A_KIT: the target folder is not an installed kit; nothing changed.' }
}
$have = (Get-Content -LiteralPath (Join-Path $Target 'VERSION') -TotalCount 1).Trim()
if ($have -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$') { throw 'NOT_A_KIT: unreadable version; nothing changed.' }
if ($have -eq $Ver) { Write-Host ('ALREADY_CURRENT ' + $have + ': nothing downloaded, nothing changed'); exit 0 }
if (Ver-Gt $have $Ver) { throw ('DOWNGRADE_REFUSED ' + $have + ' is newer than ' + $Ver + ': nothing changed.') }
$oldMan = Read-Manifest (Join-Path $Target 'MANIFEST.sha256')
$mod = @(); $miss = @()
foreach ($k in $oldMan.Keys) {
  $p = To-Path $Target $k
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $miss += $k } elseif ((Fhash $p) -ne $oldMan[$k]) { $mod += $k }
}
Write-Host ('PRECHECK version=' + $have + ' modified_kit_files=' + $mod.Count + ' missing_kit_files=' + $miss.Count)

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('nlvps-up-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  # 1. fetch and verify the new version BEFORE anything is touched
  $Base = $Repo + '/releases/download/' + $Tag
  foreach ($name in @($Zip, ($Zip + '.sha256'))) {
    try { Invoke-WebRequest -UseBasicParsing -Uri ($Base + '/' + $name) -OutFile (Join-Path $Tmp $name) }
    catch {
      $code = 0
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -eq 404) { throw ('RELEASE_NOT_FOUND: release ' + $Tag + ' is not published at ' + $Repo + ' (yet); nothing changed.') }
      throw ('DOWNLOAD_FAILED: the release file could not be fetched (HTTP ' + $code + ' or no network); nothing changed.')
    }
  }
  $want = ((Get-Content -LiteralPath (Join-Path $Tmp ($Zip + '.sha256')) -TotalCount 1) -split '\s+')[0].ToLower()
  if ($want -ne (Fhash (Join-Path $Tmp $Zip))) { throw 'ZIP_HASH_MISMATCH: nothing changed' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $za = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $Tmp $Zip))
  $unsafe = 0; $linkEntries = 0
  foreach ($en in $za.Entries) { if ((($en.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { $linkEntries++ } }
  foreach ($en in $za.Entries) { if (($en.FullName -match '(^|[/\\])\.\.([/\\]|$)') -or ($en.FullName -match '^[/\\]') -or ($en.FullName -match ':')) { $unsafe++ } }
  $za.Dispose()
  if ($linkEntries -ne 0) { throw ('ARCHIVE_LINKS entries=' + $linkEntries + ': nothing changed') }
  if ($unsafe -ne 0) { throw ('ARCHIVE_UNSAFE_PATHS entries=' + $unsafe + ': nothing changed') }
  $X = Join-Path $Tmp 'x'
  Expand-Archive -LiteralPath (Join-Path $Tmp $Zip) -DestinationPath $X
  if (@(Get-ChildItem -LiteralPath $X -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) { throw 'ARCHIVE_LINKS: nothing changed' }
  $newMan = Read-Manifest (Join-Path $X 'MANIFEST.sha256')
  $bad = 0
  foreach ($k in $newMan.Keys) {
    $f = To-Path $X $k
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $bad++; continue }
    if ((Fhash $f) -ne $newMan[$k]) { $bad++ }
  }
  $XL = (Resolve-Path -LiteralPath $X).Path.TrimEnd('\') + '\'
  foreach ($fi in (Get-ChildItem -LiteralPath $X -Recurse -File -Force)) {
    $rel = $fi.FullName.Substring($XL.Length) -replace '\\', '/'
    if ((-not $newMan.Contains($rel)) -and ($rel -ne 'MANIFEST.sha256') -and ($rel -ne 'manifest.json')) { $bad++ }
  }
  if ($bad -ne 0) { throw ('MANIFEST_MISMATCH files=' + $bad + ': nothing changed') }
  if ((Get-Content -LiteralPath (Join-Path $X 'VERSION') -TotalCount 1).Trim() -ne $Ver) { throw 'MANIFEST_MISMATCH the archive VERSION is not the pinned version: nothing changed' }
  Write-Host ('NEW_VERIFIED ' + $Ver + ' files=' + $newMan.Count)
  $coll = @()
  foreach ($k in $newMan.Keys) { if ((-not $oldMan.Contains($k)) -and (Test-Path -LiteralPath (To-Path $Target $k))) { $coll += $k } }
  if ($coll.Count -gt 0) { throw ('NEW_PATH_EXISTS: these paths already exist in your folder and the new version would overwrite them: ' + ($coll -join ',') + '; nothing changed. Rename or move them and run the update again.') }

  # 2. backup: old kit files, manifests, VERSION (as VERSION.old, so the backup is never taken for an installed kit) and the whole state
  $bkName = $have + '-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
  $bk = Join-Path $Backups $bkName
  New-Item -ItemType Directory -Path $bk -Force | Out-Null
  $n = 0
  foreach ($k in $oldMan.Keys) {
    if ($k -eq 'VERSION') { continue }
    $p = To-Path $Target $k
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      Copy-Rel $Target $bk $k
      if ((Fhash (To-Path $bk $k)) -ne (Fhash $p)) { throw 'BACKUP_FAILED: a backup copy differs from its source; nothing changed' }
      $n++
    }
  }
  foreach ($k in @('MANIFEST.sha256', 'manifest.json')) { if (Test-Path -LiteralPath (Join-Path $Target $k)) { Copy-Item -LiteralPath (Join-Path $Target $k) -Destination (Join-Path $bk $k) -Force } }
  Copy-Item -LiteralPath (Join-Path $Target 'VERSION') -Destination (Join-Path $bk 'VERSION.old') -Force
  if (Test-Path -LiteralPath (Join-Path $Target 'state')) { Copy-Item -LiteralPath (Join-Path $Target 'state') -Destination (Join-Path $bk 'state') -Recurse -Force }
  Write-Host ('BACKUP_OK ' + $bkName + ' kit_files=' + $n)

  # 3. apply; any failure from here rolls back automatically
  try {
    foreach ($k in $oldMan.Keys) {
      if (-not $newMan.Contains($k)) { $p = To-Path $Target $k; if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force } }
    }
    foreach ($k in $newMan.Keys) { if ($k -ne 'VERSION') { Copy-Rel $X $Target $k } }
    foreach ($k in @('MANIFEST.sha256', 'manifest.json')) { Copy-Item -LiteralPath (Join-Path $X $k) -Destination (Join-Path $Target $k) -Force }
    foreach ($k in $newMan.Keys) {
      if ($k -eq 'VERSION') { continue }
      if ((Fhash (To-Path $Target $k)) -ne $newMan[$k]) { throw ('VERIFY_FAILED after copy: ' + $k) }
    }
    Copy-Rel $X $Target 'VERSION'   # the new version is declared only now
    $diag = Join-Path $Target 'tools\diagnose.ps1'
    $out = & powershell -NoProfile -File $diag -Migrate 2>&1
    if (($LASTEXITCODE -ne 0) -or (-not (($out -join ' ') -match 'STATE_(MIGRATED|ALREADY_CURRENT)'))) { 
      if (($out -join ' ') -match 'ExecutionPolicy|PSSecurityException|UnauthorizedAccess|not digitally signed|running scripts is disabled') { throw 'BLOCKED_BY_LOCAL_PERMISSION: running scripts is blocked by the local execution policy; the update is rolled back; do not use Bypass, the owner decides' }
      throw 'MIGRATION_FAILED'
    }
    Write-Host ('STATE_MIGRATION ok (' + (($out -join ' ') -replace '\s+', ' ').Trim() + ')')
  }
  catch {
    $why = $_.Exception.Message
    Write-Host ('UPGRADE_FAILED ' + $why)
    try { $ov = Do-Rollback $bk @($newMan.Keys); Write-Host ('ROLLED_BACK ' + $ov + ' (automatic; backup kept as ' + $bkName + ')') }
    catch { Write-Host ('ROLLBACK_FAILED ' + $_.Exception.Message + ' - restore by hand from the backup folder ' + $bkName) }
    exit 1
  }
  Write-Host ('UPGRADED ' + $have + ' -> ' + $Ver)
  Write-Host ('LOCAL_MODIFIED ' + (($mod | Select-Object -First 20) -join ',') + ' (these kit files were replaced by the new version; their previous content is in the backup)')
  Write-Host ('TO_ROLL_BACK run this block again with -Rollback ' + $bkName)
}
finally { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
# UPGRADE-PS:END
```

macOS (и Linux) (`bash <файл> <папка комплекта>`; откат: `bash <файл> <папка комплекта> <имя-копии>`):
```bash
# UPGRADE-SH:BEGIN
set -u
REPO='https://github.com/siarheihuobi-hue/neuro-lab-vps'
TAG='v0.2.0-preview'
VER='0.2.0-preview'
TARGET="${1:-<TARGET_FOLDER_PLACEHOLDER>}"
ROLLBACK="${2:-}"
ZIP="neurokomanda-vps-kit-$VER.zip"
case "$TARGET" in *PLACEHOLDER*) echo "TARGET_NOT_CHOSEN: agree the folder with the owner first; nothing done."; exit 2 ;; esac
BACKUPS="$TARGET/.upgrade-backups"
if [ -L "$TARGET" ] || [ -L "$TARGET/state" ]; then echo "LINK_REFUSED: the kit folder or its state folder is a link; nothing changed."; exit 3; fi
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
validate_manifest() { # file: non-empty, strict format, no '..', no absolute paths
  [ -s "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] || continue
    printf '%s' "$l" | grep -Eq '^[0-9a-f]{64}  [A-Za-z0-9._/-]+$' || return 1
    if printf '%s' "$l" | grep -Eq '(^|[ /])\.\.(/|$)'; then return 1; fi
    [ "$(printf '%s' "$l" | cut -c67)" != "/" ] || return 1
  done < "$1"
  return 0
}
zip_names() { if command -v unzip >/dev/null 2>&1; then unzip -Z1 "$1"; else python3 -I -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1"; fi; }
zip_links() { if command -v unzip >/dev/null 2>&1; then unzip -Z "$1" | grep -c '^l' || true; else python3 -I -c 'import sys, zipfile; print(sum(1 for i in zipfile.ZipFile(sys.argv[1]).infolist() if ((i.external_attr >> 16) & 0xF000) == 0xA000))' "$1"; fi; }
zip_extract() { if command -v unzip >/dev/null 2>&1; then unzip -qo "$1" -d "$2"; else python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"; fi; }
man_has() { awk -v r="$2" 'substr($0,67)==r{f=1} END{exit f?0:1}' "$1"; }
man_hash() { awk -v r="$2" 'substr($0,67)==r{print substr($0,1,64); exit}' "$1"; }
ver_gt() { awk -v a="$1" -v b="$2" 'BEGIN{ split(a,x,/[.-]/); split(b,y,/[.-]/); for(i=1;i<=3;i++){ if((x[i]+0)>(y[i]+0)) exit 0; if((x[i]+0)<(y[i]+0)) exit 1 } exit 1 }'; }
# Restores the old kit files and the state exactly as they were before the upgrade; the current state is kept as a snapshot inside the backup.
do_rollback() { # backup-dir [extra-remove-list-file]
  bk="$1"; extra="${2:-}"
  [ -f "$bk/VERSION.old" ] && [ -f "$bk/MANIFEST.sha256" ] || { echo "ROLLBACK_BACKUP_INVALID: no VERSION.old or manifest"; return 1; }
  validate_manifest "$bk/MANIFEST.sha256" || { echo "ROLLBACK_BACKUP_INVALID: manifest"; return 1; }
  old_ver="$(head -n1 "$bk/VERSION.old" | tr -d '\r ')"
  if [ -d "$TARGET/state" ]; then cp -R "$TARGET/state" "$bk/state-before-rollback-$(date -u +%Y%m%dT%H%M%SZ)"; fi
  { if [ -f "$TARGET/MANIFEST.sha256" ] && validate_manifest "$TARGET/MANIFEST.sha256"; then cut -c67- "$TARGET/MANIFEST.sha256"; fi
    if [ -n "$extra" ] && [ -f "$extra" ]; then cat "$extra"; fi; } | sort -u | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    man_has "$bk/MANIFEST.sha256" "$rel" || rm -f "$TARGET/$rel"
  done
  rbfail=0
  cut -c67- "$bk/MANIFEST.sha256" > "$bk/.rollback-list"
  while IFS= read -r rel; do
    [ -f "$bk/$rel" ] || continue
    mkdir -p "$(dirname "$TARGET/$rel")"; cp "$bk/$rel" "$TARGET/$rel" || rbfail=1
  done < "$bk/.rollback-list"
  cp "$bk/MANIFEST.sha256" "$TARGET/MANIFEST.sha256" || rbfail=1
  if [ -f "$bk/manifest.json" ]; then cp "$bk/manifest.json" "$TARGET/manifest.json" || rbfail=1; fi
  rm -rf "$TARGET/state"
  if [ -d "$bk/state" ]; then cp -R "$bk/state" "$TARGET/state" || rbfail=1; fi
  while IFS= read -r rel; do
    [ -f "$bk/$rel" ] || continue
    [ "$(sha "$TARGET/$rel")" = "$(sha "$bk/$rel")" ] || rbfail=1
  done < "$bk/.rollback-list"
  if [ "$rbfail" -ne 0 ]; then echo "ROLLBACK_FAILED: some files could not be restored; restore by hand from the backup folder $bk"; return 1; fi
  cp "$bk/VERSION.old" "$TARGET/VERSION" || { echo "ROLLBACK_FAILED: VERSION could not be restored"; return 1; }   # written LAST
  echo "ROLLED_BACK $old_ver"
  return 0
}

if [ -n "$ROLLBACK" ]; then
  { printf '%s' "$ROLLBACK" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$' && ! printf '%s' "$ROLLBACK" | grep -q '\.\.'; } || { echo "ROLLBACK_NAME_INVALID"; exit 2; }
  [ -d "$BACKUPS/$ROLLBACK" ] || { echo "ROLLBACK_BACKUP_NOT_FOUND: nothing changed"; exit 3; }
  do_rollback "$BACKUPS/$ROLLBACK" || exit 1
  exit 0
fi

[ -f "$TARGET/VERSION" ] && [ -f "$TARGET/MANIFEST.sha256" ] && [ -f "$TARGET/START.md" ] || { echo "NOT_A_KIT: the target folder is not an installed kit; nothing changed."; exit 3; }
have="$(head -n1 "$TARGET/VERSION" | tr -d '\r ')"
if [ "$have" = "$VER" ]; then echo "ALREADY_CURRENT $have: nothing downloaded, nothing changed"; exit 0; fi
printf '%s' "$have" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' || { echo "NOT_A_KIT: unreadable version; nothing changed."; exit 3; }
if ver_gt "$have" "$VER"; then echo "DOWNGRADE_REFUSED $have is newer than $VER: nothing changed."; exit 3; fi
validate_manifest "$TARGET/MANIFEST.sha256" || { echo "MANIFEST_INVALID: the installed manifest is malformed; nothing changed."; exit 4; }
mod=0; miss=0; modlist=""
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  h="$(printf '%s' "$line" | cut -c1-64)"; rel="$(printf '%s' "$line" | cut -c67-)"
  if [ ! -f "$TARGET/$rel" ]; then miss=$((miss + 1)); elif [ "$(sha "$TARGET/$rel")" != "$h" ]; then mod=$((mod + 1)); modlist="$modlist${modlist:+,}$rel"; fi
done < "$TARGET/MANIFEST.sha256"
echo "PRECHECK version=$have modified_kit_files=$mod missing_kit_files=$miss"

command -v curl >/dev/null 2>&1 || { echo "TOOLS_MISSING: curl is needed; nothing changed. Installing packages is a change of the system and needs a separate consent."; exit 6; }
if command -v unzip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then :; else echo "TOOLS_MISSING: unzip or python3 is needed; nothing changed. Installing packages is a change of the system and needs a separate consent."; exit 6; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# 1. fetch and verify the new version BEFORE anything is touched
BASE="$REPO/releases/download/$TAG"
for name in "$ZIP" "$ZIP.sha256"; do
  code="$(curl -sSL -o "$TMP/$name" -w '%{http_code}' "$BASE/$name" 2>/dev/null)" || code=000
  case "$code" in
    200) ;;
    404) echo "RELEASE_NOT_FOUND: release $TAG is not published at $REPO (yet); nothing changed."; exit 5 ;;
    *) echo "DOWNLOAD_FAILED: the release file could not be fetched (HTTP $code or no network); nothing changed."; exit 5 ;;
  esac
done
want="$(head -n1 "$TMP/$ZIP.sha256" | cut -d' ' -f1 | tr 'A-Z' 'a-z')"
[ "$want" = "$(sha "$TMP/$ZIP")" ] || { echo "ZIP_HASH_MISMATCH: nothing changed"; exit 4; }
zip_names "$TMP/$ZIP" > "$TMP/names" 2>/dev/null; [ -s "$TMP/names" ] || { echo "ARCHIVE_UNREADABLE: the archive could not be listed; nothing changed"; exit 4; }
unsafe="$(grep -Ec '(^|/)\.\.(/|$)|^/|\\|:' "$TMP/names" || true)"
[ "$unsafe" -eq 0 ] || { echo "ARCHIVE_UNSAFE_PATHS entries=$unsafe: nothing changed"; exit 4; }
links="$(zip_links "$TMP/$ZIP")"
[ "$links" -eq 0 ] || { echo "ARCHIVE_LINKS entries=$links: nothing changed"; exit 4; }
mkdir "$TMP/x"; zip_extract "$TMP/$ZIP" "$TMP/x"
[ -z "$(find "$TMP/x" -type l)" ] || { echo "ARCHIVE_LINKS: nothing changed"; exit 4; }
validate_manifest "$TMP/x/MANIFEST.sha256" || { echo "MANIFEST_MISMATCH empty or malformed manifest: nothing changed"; exit 4; }
bad=0; total=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  total=$((total + 1))
  h="$(printf '%s' "$line" | cut -c1-64)"; rel="$(printf '%s' "$line" | cut -c67-)"
  if [ ! -f "$TMP/x/$rel" ] || [ "$(sha "$TMP/x/$rel")" != "$h" ]; then bad=$((bad + 1)); fi
done < "$TMP/x/MANIFEST.sha256"
( cd "$TMP/x" && find . -type f | sed 's#^\./##' ) | while IFS= read -r f; do
  if [ "$f" = "MANIFEST.sha256" ] || [ "$f" = "manifest.json" ]; then continue; fi
  man_has "$TMP/x/MANIFEST.sha256" "$f" || echo "$f"
done > "$TMP/extra"
bad=$((bad + $(wc -l < "$TMP/extra" | tr -d ' ')))
[ "$bad" -eq 0 ] || { echo "MANIFEST_MISMATCH files=$bad: nothing changed"; exit 4; }
[ "$(head -n1 "$TMP/x/VERSION" | tr -d '\r ')" = "$VER" ] || { echo "MANIFEST_MISMATCH the archive VERSION is not the pinned version: nothing changed"; exit 4; }
echo "NEW_VERIFIED $VER files=$total"

# a path that the NEW version ships but the OLD one did not must not exist yet: nothing of yours may be overwritten
cut -c67- "$TMP/x/MANIFEST.sha256" > "$TMP/newlist0"
coll=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if ! man_has "$TARGET/MANIFEST.sha256" "$rel" && [ -e "$TARGET/$rel" ]; then coll="$coll${coll:+,}$rel"; fi
done < "$TMP/newlist0"
[ -z "$coll" ] || { echo "NEW_PATH_EXISTS: these paths already exist in your folder and the new version would overwrite them: $coll; nothing changed. Rename or move them and run the update again."; exit 3; }

# 2. backup: old kit files, manifests, VERSION (as VERSION.old, so the backup is never taken for an installed kit) and the whole state
BKNAME="$have-$(date -u +%Y%m%dT%H%M%SZ)-$$"
BK="$BACKUPS/$BKNAME"
mkdir -p "$BK"
n=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  rel="$(printf '%s' "$line" | cut -c67-)"
  [ "$rel" = "VERSION" ] && continue
  [ -f "$TARGET/$rel" ] || continue
  mkdir -p "$(dirname "$BK/$rel")"; cp "$TARGET/$rel" "$BK/$rel" || { echo "BACKUP_FAILED: a file could not be copied; nothing changed"; exit 6; }
  [ "$(sha "$BK/$rel")" = "$(sha "$TARGET/$rel")" ] || { echo "BACKUP_FAILED: a backup copy differs from its source; nothing changed"; exit 6; }
  n=$((n + 1))
done < "$TARGET/MANIFEST.sha256"
cp "$TARGET/MANIFEST.sha256" "$BK/MANIFEST.sha256" || { echo "BACKUP_FAILED: manifest could not be copied; nothing changed"; exit 6; }
if [ -f "$TARGET/manifest.json" ]; then cp "$TARGET/manifest.json" "$BK/manifest.json" || { echo "BACKUP_FAILED: manifest.json could not be copied; nothing changed"; exit 6; }; fi
cp "$TARGET/VERSION" "$BK/VERSION.old" || { echo "BACKUP_FAILED: VERSION could not be copied; nothing changed"; exit 6; }
if [ -d "$TARGET/state" ]; then
  { cp -R "$TARGET/state" "$BK/state" && diff -r "$TARGET/state" "$BK/state" > /dev/null 2>&1; } || { echo "BACKUP_FAILED: the state copy is incomplete; nothing changed"; exit 6; }
fi
echo "BACKUP_OK $BKNAME kit_files=$n"

# 3. apply; any failure from here rolls back automatically
cut -c67- "$TMP/x/MANIFEST.sha256" > "$TMP/newlist"
apply_new() {
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    rel="$(printf '%s' "$line" | cut -c67-)"
    man_has "$TMP/x/MANIFEST.sha256" "$rel" || rm -f "$TARGET/$rel"
  done < "$TARGET/MANIFEST.sha256"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ "$rel" = "VERSION" ] && continue
    mkdir -p "$(dirname "$TARGET/$rel")"; cp "$TMP/x/$rel" "$TARGET/$rel" || return 1
  done < "$TMP/newlist"
  cp "$TMP/x/MANIFEST.sha256" "$TARGET/MANIFEST.sha256" && cp "$TMP/x/manifest.json" "$TARGET/manifest.json" || return 1
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ "$rel" = "VERSION" ] && continue
    [ "$(sha "$TARGET/$rel")" = "$(man_hash "$TMP/x/MANIFEST.sha256" "$rel")" ] || { echo "VERIFY_FAILED after copy: $rel"; return 1; }
  done < "$TMP/newlist"
  cp "$TMP/x/VERSION" "$TARGET/VERSION"   # the new version is declared only now
  out="$(bash "$TARGET/tools/diagnose.sh" --migrate 2>&1)" || { echo "MIGRATION_FAILED"; return 1; }
  printf '%s' "$out" | grep -Eq 'STATE_(MIGRATED|ALREADY_CURRENT)' || { echo "MIGRATION_FAILED"; return 1; }
  echo "STATE_MIGRATION ok ($(printf '%s' "$out" | tr '\n' ' '))"
  return 0
}
if ! apply_new; then
  echo "UPGRADE_FAILED"
  if do_rollback "$BK" "$TMP/newlist"; then echo "(automatic rollback finished; backup kept as $BKNAME)"; else echo "ROLLBACK_FAILED - restore by hand from the backup folder $BKNAME"; fi
  exit 1
fi
echo "UPGRADED $have -> $VER"
echo "LOCAL_MODIFIED $modlist (these kit files were replaced by the new version; their previous content is in the backup)"
echo "TO_ROLL_BACK run this block again with the target folder and the second argument $BKNAME"
# UPGRADE-SH:END
```

После `UPGRADED` выполни диагностику из `START.md` (шаг 2): версия и хеши сверяются заново, продолжай по сохранённому состоянию (ближайшее доступное незавершённое действие, не обязательно первый этап без PASS). Реальный путь обновления с опубликованного выпуска проверяется только после публикации новой версии `[?]`; до этого блок прогнан на локальной имитации репозитория.

## Шаг 5. Проверка версии и целостности
Блок варианта A уже сверил хеш архива и `MANIFEST.sha256` до установки. После установки диагностика (`tools/diagnose.*`, шаг 7) сверит версию и хеши ещё раз. При расхождении: остановись, назови владельцу, чего не хватает; к серверу не переходи.

## Шаг 6. Прочитай правила
Прочитай целиком `TARGET/CLAUDE.md` (Claude) или `TARGET/AGENTS.md` (Codex), затем `TARGET/START.md` и следуй им для работы над маршрутом. Если комплект стоит внутри существующего проекта, **правила и инструкции самого проекта остаются главными для проекта**, а комплект ведёт только маршрут и своё состояние. Посоветуй владельцу открыть папку `TARGET` в VS Code (File → Open Folder) и запускать движок там, чтобы правила комплекта загружались автоматически; продолжить можно и из текущего окна.

## Шаг 7. Диагностика и продолжение
Выполни стартовую диагностику из `START.md` (шаг 2: Windows `powershell -NoProfile -File tools\diagnose.ps1`, macOS `bash tools/diagnose.sh`, из папки `TARGET`) и веди участника по этапам до проверенного приложения. Принятые этапы пропускаются, заявленные проверяются, готовые интервью и карта не повторяются.

## Повторный запуск
Безопасен: если `TARGET` уже содержит эту версию, ничего не скачивается и не перезаписывается; `state/`, принятые этапы и изменения участника остаются нетронутыми. Другая версия — только по решению владельца. Сбой посреди копирования оставляет в `TARGET` часть файлов, но **без `VERSION`** (он копируется последним): следующий запуск не примет это за установленный комплект, а остановится с `TARGET_NOT_EMPTY`. Тогда выбери другую папку; удалять содержимое можно только с явного подтверждения владельца, ставить поверх нельзя. Временную папку блок удаляет сам.

Официальная документация, на которую опирается маршрут: [Remote-SSH в VS Code](https://code.visualstudio.com/docs/remote/ssh).
