# Процедура: UFW (минимальный входящий доступ)

**Статус:** выполнена один раз на эталонном контуре (Ubuntu 24.04, ufw 0.36.2, 2026-10-05) и дала PASS. Другим человеком не проверялась `[?]`. Скрипты здесь **шаблоны**: агент подставляет значения, объявляет каждую административную операцию и получает подтверждение (Manual / штатное подтверждение Codex).

**Цель:** входящий доступ только на фактический порт SSH (по умолчанию 22/tcp), исходящие разрешены. Ничего больше: не открывать 443, демо-порты, не добавлять rate-limit, Fail2ban, port knocking.

**Предусловия:** обычный пользователь входит по ключу (этап 4); есть **управляемый административный канал** (ключевой вход под root или sudo с паролем, который вводит человек, при этом агент может отправлять команды и получать вывод). Открытое окно без такого канала каналом не считается. Если канала нет — стоп, зафиксировать блокер.

## 1. Прочитать фактическое состояние (read-only)
Место: `AGENT` (административный канал).
```
ufw status verbose; ufw status numbered
grep -v '^#' /etc/ufw/user.rules | grep -v '^$'
grep -v '^#' /etc/ufw/user6.rules | grep -v '^$'
grep -E '^(ENABLED|IPV6|DEFAULT_)' /etc/ufw/ufw.conf /etc/default/ufw
sshd -T | grep -E '^port '          # порт из конфигурации SSH: не предполагать 22
ss -ltnp | grep -E 'sshd|systemd'     # реально слушаемый порт (при сокет-активации слушает systemd, а не sshd)
systemctl cat ssh.socket              # обязательно: ListenStream сокета тоже должен совпасть с портом
ss -tulnH                             # кто слушает снаружи
grep -v '^#' /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/after.rules /etc/ufw/after6.rules | grep -v ':$'
```
Если порт из `sshd -T` и порт, который реально слушает sshd, расходятся — **СТОП**, правило не добавлять, пока расхождение не объяснено. Что искать: пользовательские правила, разрешающие что-либо кроме SSH; нестандартные записи в `before*/after*` (стандартные: loopback, established, ICMP, DHCP, mDNS/SSDP на multicast, служебные порты 137–139/445 через `skip-to-policy`). **Неожиданное разрешение входящего сервиса → СТОП до включения.** Файрвол на стороне провайдера этим не проверяется `[?]`.

## 2. Резервная копия
```
umask 077
TS=$(date +%Y%m%d-%H%M%S); B=/root/ufw-backup-$TS
install -d -m700 "$B"
cp -a /etc/ufw "$B/etc-ufw" && cp -a /etc/default/ufw "$B/default-ufw"
diff -r /etc/ufw "$B/etc-ufw" && cmp /etc/default/ufw "$B/default-ufw" && echo BACKUP_VERIFIED
```

## 3. Автооткат — до включения (не зависит от SSH-сеанса)
Скрипт отката (root, 700): отключить UFW, восстановить копию, проверить `inactive`, записать результат без секретов.
```
cat > /root/ufw-rollback-$TS.sh <<EOF
#!/bin/bash
LOG=$B/rollback-result.txt
{
echo "rollback start \$(date -u +%FT%TZ)"
/usr/sbin/ufw --force disable
cp -a $B/etc-ufw/. /etc/ufw/
cp -a $B/default-ufw /etc/default/ufw
ST=\$(/usr/sbin/ufw status | head -1); echo "status: \$ST"
case "\$ST" in *inactive*) echo ROLLBACK_RESULT=OK;; *) echo ROLLBACK_RESULT=FAILED; exit 1;; esac
} >> "\$LOG" 2>&1
EOF
chmod 700 /root/ufw-rollback-$TS.sh; bash -n /root/ufw-rollback-$TS.sh
systemd-run --unit=ufw-rollback-$TS --on-active=600 --timer-property=AccuracySec=1s /root/ufw-rollback-$TS.sh
systemctl is-active ufw-rollback-$TS.timer; systemctl list-timers ufw-rollback-$TS.timer --no-pager
```
Проверка: таймер `active`, у него назначено время срабатывания. **Если подготовка отката не удалась — UFW не включать.** Механизм `systemd-run` проверяется один раз: тестовый таймер с `/usr/bin/true` должен зарегистрироваться, выполниться (журнал: Started/Deactivated successfully, `Result=success`) и самоудалиться; факт создания таймера не доказывает срабатывания.

## 4. Применить
```
ufw allow <SSH_PORT>/tcp comment 'ssh remote-ssh'
ufw --force enable
ufw status verbose; ufw status numbered
```
Ожидаемо: `Status: active`, `Default: deny (incoming), allow (outgoing)`, разрешено `<SSH_PORT>/tcp` для IPv4 и IPv6, правил для 443 и демо-портов нет.

## 5. Новый вход и отмена отката
1. **Новый отдельный SSH-процесс** с ноутбука (`BatchMode=yes`, пароль отключён, без `ControlMaster`) под обычным пользователем: `whoami`, код выхода 0.
2. Попросить человека переподключить окно Remote-SSH и открыть терминал (`whoami`). Сообщить **точное время автоотката**; до подтверждения таймер не отменять.
3. Только после обеих проверок: `systemctl stop ufw-rollback-$TS.timer`, затем `rm -f /root/ufw-rollback-$TS.sh` (скрипт отката не должен остаться и случайно отключить UFW позже); убедиться, что откат не запущен (`systemctl is-active` → inactive, файла `rollback-result.txt` нет), повторно подтвердить `ufw status` и правила. Резервную копию сохранить.
4. При неуспехе нового входа: не отменять откат, дождаться таймера (или откатить через доступный канал) и проверить восстановление доступа. UFW самостоятельно повторно не включать.

Существующие SSH-соединения при включении сохраняются благодаря правилу `RELATED,ESTABLISHED`, но это **не обещается**: проверка делается новым входом.
