# tools/ — стартовая диагностика (read-only)

Первый исполняемый этап комплекта. Скрипт **ничего не меняет**: ни систему, ни сеть, ни VPN, ни SSH, ни ключи, ни настройки. Он пишет только в `state/` комплекта и ничего не отправляет по сети.

| ОС | Команда | Статус проверки |
|---|---|---|
| Windows | `powershell -NoProfile -File tools\diagnose.ps1` | проверено на одном ноутбуке Windows 11 (Windows PowerShell 5.1) |
| macOS | `bash tools/diagnose.sh` | **не проверено на настоящем macOS** `[?]`; логика прогнана в Git Bash с подменой метки ОС |
| Linux (удалённое окно) | `bash tools/diagnose.sh` | проверки ноутбука дают `NOT_RUN`; не проверено на настоящем сервере `[?]` |

## Что проверяется

`kit` (версия и хеши по `MANIFEST.sha256`), `os`, `exec_place` (место терминала: ноутбук или удалённый сервер; Linux или WSL на ноутбуке не VPS, при сомнении один вопрос), `vscode`, `ext_remote_ssh`, `ext_claude`, `ext_codex` (расширения, установленные **локально**; расширения на SSH-хосте отсюда не видны), `ssh_client`, `prev_state`, `map`, `workspace`, `vpn`, `perm_claude`, `perm_codex`.

Статусы: `PASS` — проверенный факт; `NOT_FOUND` — не найдено; `UNKNOWN` — скрипт не может это увидеть (задаётся вопрос, ответ не угадывается); `BLOCKED_BY_LOCAL_PERMISSION` — локальный отказ разрешений (серверные проверки `NOT_RUN`); `NOT_RUN` — не запускалось; `FAIL` — проверка выполнена и не пройдена.

`code` не найден в PATH даёт `UNKNOWN`, а не `FAIL`: VS Code может быть установлен без команды `code`. Для macOS в VS Code есть команда «Shell Command: Install 'code' command in PATH».

## Контрольные точки, попытки, контекст, экспорт

| Windows | macOS/Linux | Что делает |
|---|---|---|
| `-Checkpoints` | `--checkpoints` | HOST_IDENTITY, SSH_AUTH, ADMIN_ACCESS, RECOVERY по записанным фактам (совместимо со старыми KEY_LOGIN и ADMIN_READY) |
| `-Fact X=S -Scope S -Blocker B -Retry R` | `--fact X=S --scope S --blocker B --retry R` | факт с областью, блокером и условием повтора (коды без адресов); RECOVERY=PASS требует область `agent_channel` или `human_only` |
| `-Attempt AREA -Symptom -Hypothesis -Action -Result -Knowledge yes/no/pending` | `--attempt AREA --symptom ...` | запись в `state/attempts.tsv`; после двух подряд без нового знания следующая попытка отказывается (код 2); та же гипотеза и действие под другим названием области считаются той же попыткой; `pending` — опрос уже запущенной операции, не более 5 подряд |
| `-AttemptCheck AREA` | `--attempt-check AREA` | `OK` или `STOP` по области |
| `-Change AREA -Source KIND -Action CODE` | `--change AREA --source KIND --action CODE` | записать конкретное изменение условий (KIND из закрытого списка: other_device, other_browser, other_network, other_account, corrected_parameter, new_fact, new_candidate, provider_reply, new_generation, new_tool, owner_decision) и снять остановку; принимается только для остановленной области и не дважды подряд |
| `-Context` | `--context` | версия установки, окно, папка, сервер, инструменты, незавершённые операции |
| `-Export` | `--export` | `state/export.txt` для ручной передачи; ничего не отправляется автоматически |

Статусы фактов дополнены `DEFERRED` (отложено решением) и `NOT_APPLICABLE` (не относится к пути); `NOT_TESTED` читается как `NOT_RUN`, старые записи не переименовываются. Области попыток: HOST_IDENTITY, SSH_AUTH, ADMIN_ACCESS, RECOVERY, CONSOLE, PANEL, PROVIDER_API, ENGINE, PERMISSION, TUNNEL, MIGRATION, OTHER.

## Помощник провайдера (отдельный файл)

**Experimental, на настоящем API не проверен.** `tools/provider-api.ps1` / `tools/provider-api.sh`: фиксированные операции с API провайдера, ключ в хранилище ОС, очищенный вывод, покупка только через предпросмотр и код подтверждения. Полное описание, границы и что проверено — `procedures/provider-api.md`.

## Ответы человека (`-Answer` / `--answer`)

Принимаются только значения из белого списка; произвольный текст и секреты не принимаются.

| Ключ | Значения |
|---|---|
| `vpn` | `on`, `off`, `unknown` |
| `claude_permission` | `manual`, `other`, `bypass`, `none`, `unknown` |
| `codex_confirmations` | `default`, `other`, `bypass`, `none`, `unknown` |
| `workspace_selected` | `yes`, `no` |
| `map_ready` | `yes`, `no` |
| `project_link` | `parent` (комплект лежит в подпапке существующего VPS-проекта), `standalone` |
| `entry_mode` | `gpt_guide` (с GPT-проводником), `vscode_direct` (сразу в VS Code) |
| `server_state` | `none`, `existing_active`, `replaced`, `unknown` |
| `purchase_profile` | `base`, `recommended`, `existing`, `undecided` |
| `engine_mode` | `claude_only`, `codex_only`, `both`, `undecided` |
| `exec_place` | `laptop_windows`, `laptop_macos`, `remote_linux`, `local_linux`, `wsl`, `unknown` |
| `account_state` | `new`, `existing`, `unknown` |
| `region_state` | `available`, `unavailable`, `unknown` |
| `panel_access` | `ok`, `unreachable_via_vpn`, `other` |
| `neurolab_member` | `yes`, `no`, `unknown` |
| `neurolab_offer` | `shown`, `declined`, `interested`, `already_member` |
| `cheat_sheet_local` | `yes`, `no` (разрешение хранить личную памятку в `state/`) |
| `admin_sudo_actor` | `working_ssh_user`, `other_account`, `untested` (кто выполнял последний `sudo`) |
| `admin_sudo_result` | `ok`, `auth_failed`, `no_sudo_rights`, `no_interactive_input`, `agent_context_unavailable`, `other`, `untested` (точный исход, без догадок о причине) |
| `admin_candidate` | `none`, `current_user_in_sudo_group`, `other_account_in_sudo_group`, `unknown` (кандидат, не `ADMIN_READY`) |
| `admin_context` | `human_terminal`, `agent_channel`, `none` (где подтверждено администрирование) |

`bypass` фиксируется как `FAIL`: комплект не работает с режимом без подтверждений.

## Принятие и сброс этапов

- `-Accept N -Source <источник> -Evidence L|U|LU` (macOS: `--accept N --source ... --evidence ...`): ставит PASS. **Без источника и метки команда отказывает; метка `?` для PASS недопустима.** Заметка — только короткий код `A-Za-z0-9_.+-`.
- `-Claim N -Source <источник>` (macOS: `--claim N --source ...`): записывает **заявление** из документов существующего проекта «этап N выполнен» со статусом `CLAIMED`. Это не PASS: этап остаётся в плане как `RUN`, его нужно проверить и принять командой `-Accept`. Уже принятый этап заявление не трогает.
- `-Reset N` / `--reset N`: возвращает этап в `PENDING` (при изменении входных данных).

## Факты, поколение сервера, итог (схема состояния 2)

- **Факты** (`facts.tsv`): `-Fact ИМЯ=СТАТУС -Source <источник> -Evidence L|U|LU` (macOS: `--fact ... --source ... --evidence ...`, можно несколько `--fact`). Имена: `SERVER_PURCHASED`, `SERVER_ACTIVE`, `HOST_IDENTITY`, `KEY_READY`, `KEY_INSTALLED`, `KEY_LOGIN`, `PREFLIGHT`, `ADMIN_READY`, `UFW`, `SSH_HARDENING`, `ENGINE_READY`, `TEAM_LOADED`, `QA`, `APP_BROWSER`, `RECONNECT`, `TRAIN_REMOTE_WINDOW`, `TRAIN_OPEN_PROJECT`, `TRAIN_NEW_PROJECT`, `TRAIN_SESSION`, `TRAIN_TASK`, `TRAIN_PORTS`, `TRAIN_DISK`, `TRAIN_RESUME`, `TRAINING`. Статусы: `PASS`, `OPEN`, `BLOCKED`, `NOT_RUN`, `UNVERIFIED`, `ACCEPTED_RISK`, `SKIPPED`. Метка `L` — заявление агента о том, что проверка выполнена им самим в его канале; скрипт этого не проверяет, поэтому `L` не считается самостоятельным независимым доказательством, и для `ADMIN_READY=PASS` дополнительно требуются ответы `admin_context=agent_channel` и `admin_sudo_result=ok`. `-Source` и `-Note` не должны содержать IP-подобных строк. Правила скрипта: `UNVERIFIED` и `ACCEPTED_RISK` — только для `HOST_IDENTITY` (принятый риск требует метку `U` и не превращается в `PASS`); `SKIPPED` — только для обучения; `TRAINING` вычисляется (`TRAINING=PASS` отказ), пропуск — `TRAINING=SKIPPED`; `KEY_LOGIN`, `ADMIN_READY`, `UFW`, `SSH_HARDENING` не принимаются только по слову человека (метка должна включать `L`); `HOST_IDENTITY=PASS` требует подтверждения человеком независимой сверки (`U` или `LU`).
- **Ворота этапов:** `-Accept N` без своих фактов отказывает (`ACCEPT_NEEDS_FACTS`). Этап 3 — `SERVER_PURCHASED`, `SERVER_ACTIVE`; 4 — `HOST_IDENTITY` (`PASS` или `ACCEPTED_RISK`), `KEY_READY`, `KEY_INSTALLED`, `KEY_LOGIN`; 5 — `PREFLIGHT`; 6 — `ADMIN_READY`, `UFW`, `SSH_HARDENING`; 7 — `ENGINE_READY`; 9 — `TEAM_LOADED`; 10 — `QA`; 11 — `APP_BROWSER`; 12 — `RECONNECT`. Этапы 1, 2, 8 берут факты из диагностики и ответов человека.
- **Новый сервер** (`-NewServer -Source <код>` / `--new-server --source <код>`): поколение +1; серверные факты и этапы 3–12 прежнего сервера не переносятся (их список сохраняется в `history.tsv`), ответы о прежнем сервере сбрасываются; интервью, карта, этапы 1–2, `KEY_READY` и пройденное обучение остаются.
- **Миграция** (`-Migrate` / `--migrate`, также при обычном запуске): состояние версии 0.1.2 (схема 1) переносится в схему 2 с копией в `state/backup-schema1/`; PASS-этапы становятся фактами с источником `migrated`. Повторный вызов ничего не меняет.
- **Итог** (`-Summary` / `--summary`): пять отдельных результатов `WORKSPACE`, `APP`, `RECONNECT`, `SECURITY`, `TRAINING`, строка `ADMIN` (`READY`, `CANDIDATE_ONLY` или `NOT_PROVEN` с последним исходом `sudo`), пометка `NOTE host_identity`, `OVERALL` (`FULL_PASS` только при всех пяти и подтверждённом отпечатке, иначе `PARTIAL`), `OFFER` (подходит ли предложение Neuro-lab, ветка и готовность ссылки по `config/neurolab-offer.json`) и поколение сервера. Скрипт не знает ничего о событиях демо: итог строится только по записанным этапам и фактам.
- Повторный запуск диагностики не перезаписывает уже принятые этапы, заменяет `diagnostics.tsv` (последний запуск) и дописывает события в локальный журнал.

## Файлы состояния (`state/`, не входят в Git и ZIP)

`stages.tsv` (этап, статус, метка, источник, дата UTC, код), `facts.tsv` (факт, статус, метка, источник, дата, поколение), `meta.tsv` (схема, случайный `target_id`, поколение), `history.tsv` (снятые с поколения факты), `answers.tsv`, `diagnostics.tsv`, `state/backup-schema1/` (после миграции), `telemetry/events.jsonl`, `map.md` (готовая архитектурная карта, если есть), `state-card.md`, `continuation-report.md` и по желанию `cheat-sheet.md` (ведёт агент по шаблонам).

## Если PowerShell не запускает скрипт

Распакованный из интернета архив может нести пометку «из интернета» (политика `RemoteSigned`). Тогда скрипт не стартует. Это `BLOCKED_BY_LOCAL_PERMISSION`, не ошибка сервера. Агент называет одну точную операцию: человек снимает блокировку именно с файлов комплекта (`Unblock-File` на папке комплекта, подтверждение вручную). Режим `Bypass` политики и постоянные послабления не используются.

## Телеметрия

Схема — `telemetry/schema.json`. События только локальные, поля закрытого списка, команд, вывода, путей, адресов, имён и секретов нет. Сетевая отправка выключена (`telemetry/config.json`), в комплекте нет кода отправки. Приёмник, HTTPS-отправка и дашборд не созданы; **готовность полной телеметрии не заявляется**. В bash-ветке время выполнения измеряется с точностью до секунды; ожидание человека скрипт не измеряет (`wait_ms` пуст).
