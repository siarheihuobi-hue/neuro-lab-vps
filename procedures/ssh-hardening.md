# Процедура: SSH hardening с автооткатом и завершением без root

**Статус:** выполнена один раз на эталонном контуре (Ubuntu 24.04, OpenSSH 9.6, 2026-10-05) и дала PASS. Другим человеком не проверялась `[?]`. Скрипты — **шаблоны**: агент подставляет значения, объявляет каждую административную операцию и получает подтверждение (Manual / штатное подтверждение Codex).

**Цель (политика):** `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`, порт без изменений.

**Предусловия:** (1) вход обычного пользователя по ключу работает (этап 4, 5); (2) на момент применения есть управляемый административный канал: либо ключевой root-сеанс (ключ root устанавливается человеком временно и **удаляется из `authorized_keys` после завершения hardening**), либо обычный пользователь с паролем sudo, который вводит человек; в любом случае агент должен мочь отправлять команды и получать вывод; (3) UFW процедура завершена или осознанно отложена. Открытое окно само по себе канал не доказывает. После hardening **root-вход закрыт**: административные операции дальше — обычный пользователь и пароль sudo, который вводит человек.

## Ключевая проблема и решение
После hardening нет root-входа, а у обычного пользователя нет passwordless sudo, поэтому он не может остановить root-таймер отката. Решение — узкий механизм из **временных** units (никаких постоянных сервисов):
- каталог результатов `/run/ssh-hardening-<TS>/` принадлежит root (755), все результаты пишутся только в него: пользовательский каталог для записи root не используется, иначе возможна подмена через симлинк;
- внутри `confirm.d/` (владелец — обычный пользователь, 700): пользователь может только создать файл-запрос `ok`; **содержимое запроса не читается и не исполняется**;
- transient **path-unit** (`PathExists=…/confirm.d/ok`) запускает фиксированный root-скрипт; тот под блокировкой останавливает таймер отката, пишет `FINALIZED` и результаты, чистит временные файлы.

## 0. Проверка механизма завершения до изменений SSH (безвредный тест)
Создать тестовый каталог, тестовый скрипт (пишет `TEST_OK` и останавливает свой path-unit), `systemd-run --path-property=PathExists=...`. Обычный пользователь создаёт запрос; результат `TEST_OK ... uid=0` подтверждён; запрос не исполнен (в запрос кладётся строка с командой-приманкой, она не должна выполниться); пользователь **не может** писать в root-каталог, в скрипт и в `/run/systemd/transient/`. Тест не прошёл → СТОП, SSH не менять. Тестовые units и файлы удалить.

## 1. Конфигурация (read-only, root)
```
sshd -t
sshd -V 2>&1 | head -1
ls -l /etc/ssh/sshd_config /etc/ssh/sshd_config.d
grep -nEi '^\s*(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|port|usepam|authenticationmethods|allowusers|allowgroups|denyusers|denygroups|match|include)\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
for u in root <user>; do sshd -T -C user=$u,host=client.invalid,addr=<адрес-из-документации> | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods) '; done
systemctl is-active ssh ssh.socket
```
OpenSSH берёт **первое** найденное значение директивы. Директива `Include` в основном файле подключает drop-in файлы **до** следующих строк, поэтому drop-in побеждает значения ниже `Include`, а лексически более ранний drop-in побеждает более поздний. Имя `00-…conf` само по себе победы не гарантирует: победу доказывает эффективная конфигурация конкретного сервера. Проверить кандидата без изменений: временный каталог вне `/etc/ssh`, копия drop-in'ов + кандидат, копия `sshd_config` с `Include` на временный каталог, `sshd -t -f` и `sshd -T -f ... -C user=...` для root и обычного пользователя. Любые `Match`-блоки учитываются отдельно (`-C`).

## 2. Резервная копия и подготовка отката
```
umask 022; TS=$(date +%Y%m%d-%H%M%S)
B=/root/ssh-hardening-backup-$TS; D=/run/ssh-hardening-$TS
DROP=/etc/ssh/sshd_config.d/00-vps-reference-hardening.conf      # проверить: файла ещё нет, иначе СТОП
[ ! -e "$DROP" ] || { echo STOP; exit 1; }
install -d -m700 "$B"; cp -a /etc/ssh/sshd_config "$B/sshd_config"; cp -a /etc/ssh/sshd_config.d "$B/sshd_config.d"
diff -r /etc/ssh/sshd_config.d "$B/sshd_config.d" && cmp /etc/ssh/sshd_config "$B/sshd_config" && echo BACKUP_VERIFIED
install -d -m755 -o root -g root "$D"; install -d -m700 -o <user> -g <user> "$D/confirm.d"
```

Скрипты V, RB и FIN хранятся в каталоге `/root/ssh-hardening-$TS/` (владелец root, права 700; все файлы 700); перед взведением таймера проверь `stat` каталога и скриптов (владелец root, нет прав группы и остальных). Пути в шаблонах ниже подставляй из этого каталога.

Скрипт проверки `V` (root, 700):
```
#!/bin/bash
sshd -t || { echo SSHD_T_FAIL; exit 1; }
EXP=$(printf '%s\n' 'port <SSH_PORT>' 'permitrootlogin no' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' | sort)
for u in root <user>; do
  OUT=$(sshd -T -C "user=$u,host=client.invalid,addr=<адрес-из-документации>" | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) ' | sort)
  [ "$OUT" = "$EXP" ] || { echo "MISMATCH user=$u"; echo "$OUT"; exit 1; }
  echo "-- effective user=$u"; echo "$OUT"
done
echo SSHD_T=PASS
```

Скрипт отката `RB` (root, 700; запускается таймером):
```
#!/bin/bash
umask 022
D=<D>; B=<B>; LOG=$D/rollback.log
exec 9>"$D/lock"; flock 9
if [ -e "$D/FINALIZED" ]; then echo "$(date -u +%FT%TZ) ROLLBACK_SKIPPED_FINALIZED" >> "$LOG"; exit 0; fi   # пропуск только по root-отметке, а не из-за запроса пользователя
: > "$D/ROLLBACK_STARTED"
{
echo "$(date -u +%FT%TZ) ROLLBACK_START"
rm -f <DROP>
if diff -r "$B/sshd_config.d" /etc/ssh/sshd_config.d && cmp "$B/sshd_config" /etc/ssh/sshd_config; then echo FILES_MATCH_BACKUP
else echo FILES_DIFFER_RESTORING; rm -rf /etc/ssh/sshd_config.d; cp -a "$B/sshd_config.d" /etc/ssh/sshd_config.d; cp -a "$B/sshd_config" /etc/ssh/sshd_config; fi
if sshd -t; then if systemctl reload ssh; then echo RELOAD_OK; else echo RELOAD_FAILED; fi; else echo SSHD_T_FAILED_NO_RELOAD; fi
echo "$(date -u +%FT%TZ) ROLLBACK_DONE"
} >> "$LOG" 2>&1
```

Скрипт завершения `FIN` (root, 700; запускается path-unit'ом):
```
#!/bin/bash
umask 022
D=<D>; B=<B>; LOG=$D/final.log
exec 9>"$D/lock"; flock 9
systemctl stop <FIN_PATH_UNIT>
if [ -e "$D/ROLLBACK_STARTED" ]; then echo "$(date -u +%FT%TZ) FINALIZE_REFUSED_ROLLBACK_STARTED" >> "$LOG"; exit 0; fi
if ! OUT=$(<V> 2>&1); then { echo "$(date -u +%FT%TZ) FINALIZE_REFUSED_CHECK_FAILED"; echo "$OUT"; } >> "$LOG"; exit 0; fi
systemctl stop <RB_TIMER>
if [ "$(systemctl is-active <RB_TIMER>)" = active ]; then echo "$(date -u +%FT%TZ) FINALIZE_REFUSED_TIMER_STILL_ACTIVE" >> "$LOG"; exit 0; fi
: > "$D/FINALIZED"
echo "$OUT" > "$D/effective.txt"
echo "$(date -u +%FT%TZ) FINALIZED" >> "$LOG"
rm -rf --one-file-system "$D/confirm.d"
cp -a "$D/final.log" "$D/effective.txt" "$B/" 2>/dev/null
rm -f <RB> <V> "$0"
```
В шаблонах `<...>` заменяются реальными значениями (`sed`); перед запуском `bash -n` для каждого скрипта.

## 3. Взвести ДО изменения
```
systemd-run --unit=ssh-hard-rb-$TS --on-active=600 --timer-property=AccuracySec=1s <RB>
systemd-run --unit=ssh-hard-fin-$TS --path-property=PathExists="$D/confirm.d/ok" <FIN>
systemctl is-active ssh-hard-rb-$TS.timer ssh-hard-fin-$TS.path
systemctl list-timers ssh-hard-rb-$TS.timer --no-pager      # время срабатывания назначено
```
Любая ошибка — остановить оба unit'а и **не менять SSH**. Время срабатывания по `list-timers` (не по `systemctl show ... NextElapseUSecRealtime`: для монотонного таймера свойство пустое).

## 4. Применить
```
( umask 077; printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' > "$DROP" )
chown root:root "$DROP"; chmod 600 "$DROP"
<V>   # sshd -t и sshd -T для root и обычного пользователя
```
При расхождении: удалить созданный файл, остановить unit'ы, **не делать reload**, не подбирать конфигурацию заново. После успешной проверки: `systemctl reload ssh`.

## 5. Проверки с ноутбука (отдельные новые SSH-процессы, без ControlMaster)
1. Обычный пользователь по ключу: `BatchMode=yes`, пароль и keyboard-interactive отключены → `whoami`, код 0.
2. `root` с ранее рабочим ключом должен получить **явный отказ** (`Permission denied (publickey)`). Таймаут сети доказательством запрета не считается.
3. Отключение пароля: эффективная конфигурация (`V`) и список методов, который предлагает сервер (`ssh -v` с отключённым ключом показывает `Authentications that can continue: publickey`). Пароль не вводить и не передавать.
4. Человек переподключает окно Remote-SSH и сообщает `whoami`. Агент называет **точное время автоотката**; до подтверждения таймер не отменять.
5. При неуспехе любой проверки запрос завершения **не создавать**; откат выполнить через доступный канал либо дождаться таймера; проверить восстановление доступа. Hardening повторно самостоятельно не включать.

## 6. Завершение
Обычный пользователь (по ключу, без sudo) создаёт запрос: `touch /run/ssh-hardening-<TS>/confirm.d/ok`. Через несколько секунд читает (каталог результатов доступен на чтение): `final.log` должен содержать `FINALIZED`, `effective.txt` — пять целевых значений, `rollback.log` отсутствует, `systemctl is-active <RB_TIMER> <FIN_PATH_UNIT>` → inactive, `ssh-hard-*` units отсутствуют. Резервная копия и результаты в `$B` сохраняются. Постоянного административного механизма не остаётся.

Если сервер перезагрузится в окне ожидания, временные units и каталог в `/run` пропадут: конфигурация останется ужесточённой (проверенной `V`), а автооткат исчезнет; после перезагрузки выполни проверки раздела 5 заново.

Если откат по времени всё же сработал — признать откат, SSH-hardening **не включать повторно** без нового решения человека.
