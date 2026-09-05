# Ручная приёмка UNETRTL.DLL в MAME / на железе

Документ — developer-only: он не входит в `DIST_DOC_FILES` и не попадает
в ZIP/floppy image. Дополняет `docs/UNETRTL.md` (описание ABI) и
`docs/MAME_NETWORK.md` (общая настройка сети MAME); здесь -- только
сценарии для проверки `UNETRTL.DLL` через её штатный клиент
`UNETTEST.EXE` (`src/apps/unettest.asm`).

Автоматический гейт перед любой сессией:

```sh
make clean
make test-host package image
```

`make test-host` уже проверяет `UNETRTL.DLL`/`UNETTEST.EXE` под host-side
Z80-эмулятором (`tools/test-exe-dll.js`, `docs/HARNESS.md`) -- это быстрый,
но не заменяющий MAME сигнал. Ниже -- сценарии для реального MAME
(`-isa1 rtl8019as`) или платы, когда она появится.

## Что уже покрыто автоматически (история багов)

`tools/test-exe-dll.js` прогоняет через JS-harness ПОЛНЫЙ путь DLL:
NETINIT (включая загрузку cold-оверлея из хвоста файла DLL), GETCAPS,
RESOLVE (литеральный IP), PING, CONNECT/SEND/RECV/CLOSE, UDP-эхо
(21 и 1472 байта), `-l` (LISTEN/UNLISTEN, таймауты accept-ожидания) и
`-a` (SETOPT SENDSLICE + CONNECT + SEND). Три бага, которые эти векторы
однажды поймали и теперь держат как регрессионные:

- **`CHECK_ASYNC_PEND` затирал `A` перед `CHECK_CHANNEL`** -- каждый
  `CONNECT`/`CLOSE`/`UDPOPEN`/`LISTEN`/`UNLISTEN` возвращал `NERR_PARAM`
  не отправив ни байта. Исправлено (A сохраняется через L).
- **`PUT_DEC_HL` в `unettest.asm` оставляет `DE=0`** -- `-u`-поток
  грузил указатель payload до печати размера, и `SEND` уходил с 21
  байтом, прочитанным с адреса `0x0000`. Исправлено (аргументы
  грузятся после всей печати).
- **"BIOS call while ISA window is open (fn=0x0F)"** оказалась ложным
  срабатыванием самого харнесса: cold-оверлей легально исполняет свой
  диспатчер по адресам `0x0008`/`0x0010` при перемапленном окне 0, а
  харнесс трактовал любое попадание PC на RST-вектора как сервисный
  вызов. Исправлено в `tools/exe-harness/harness.js`.

Ниже -- сценарии для реального MAME/железа: то, что harness покрыть не
может (настоящий входящий accept для `-l`, настоящий `NERR_AGAIN` при
закрытом TCP-окне для `-a`, тайминги реальной сети).

## Подготовка стенда

Один раз после перезагрузки macOS (или если `feth0`/`feth1` пропали):

```sh
./tools/dev/init_interfaces.sh
```

Поднимает `feth0`/`feth1` (`192.168.7.1/24` на стороне хоста), права на
`/dev/bpf*`, NAT/forwarding на WAN (нужен, только если сценарий ниже
использует внешние ресурсы -- локальные сценарии этого документа обходятся
без него). Подробности и cleanup -- `docs/MAME_NETWORK.md`.

Привязать MAME к `feth0` (Tab -> Network Devices -> rtl8019as -> feth0),
один раз -- сохраняется в `cfg/sprinter.cfg`.

**Важно: `run_sprinter_rtl8019as.sh` сам по себе НЕ подключает
`distr/sprinter-rtl8019a.img`.** Скрипт грузит две персистентные CHD
(`sp_hdd_sys.chd` как C:, `sp_hdd_media.chd` как D:) -- это общий,
не связанный с этим репозиторием рабочий стол Sprinter DSS, куда файлы
разных проектов копировались вручную в разное время (например
`C:\RTL1`, `C:\RTL2` содержат СТАРЫЕ копии этого проекта). Второй
флоппи-привод (`beta:wd179x:1`, уже настроен как `35hd` -- 3.5" HD, тот
же формат, что и наш FAT12-образ) занят посторонним `solid.img`.
Свежий билд из `make image` нужно подключить явно:

```sh
/Users/dmitry/dev/zx/sprinter/mame/run_sprinter_rtl8019as.sh \
  -networkprovider pcap \
  -flop2 /Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a/distr/sprinter-rtl8019a.img
```

(скрипт передаёt лишние аргументы напрямую в MAME, а более поздний
`-flop2` перекрывает встроенный `solid.img` -- сам скрипт трогать не
нужно). Это ставит наш собранный образ в дисковод **B:**. Работать
прямо с B: -- он уже содержит все утилиты и `NETSMPL.CFG`, ничего
докопировать не нужно (в отличие от C:\RTL1/RTL2, где лежат устаревшие
билды многонедельной давности -- их использовать не надо, они не
отражают текущий код).

В DSS: `B:`, затем `COPY NETSMPL.CFG NET.CFG`, прописать
`IP=192.168.7.2`, `NETMASK=255.255.255.0`, `GATEWAY=192.168.7.1`,
затем `NETCFG -i -v` и `IFUP` (или чистый `NETCFG -c -v` +
`NETCFG -i -v`, если `IFUP`/DHCP не нужен для этой сессии -- UNETRTL
сам DHCP не делает, ему достаточно опубликованного статического
окружения). Каждый цикл `make image` перезаписывает
`distr/sprinter-rtl8019a.img` на диске -- следующий запуск MAME с той
же `-flop2` командой сразу видит свежий билд, повторный COPY не нужен.

Во всех сценариях ниже вызывайте `UNETTEST` с **литеральным IP**
(`192.168.7.1`), а не `example.com` (значение по умолчанию): `resolve_lib`
(`src/lib/resolve_lib.asm`) сначала пробует распарсить аргумент как
`a.b.c.d`, и только при неудаче идёт в DNS -- так сценарий не зависит от
DNS-инфраструктуры и требует только ARP+ICMP, которые за `192.168.7.1`
и так отвечает сетевой стек macOS (см. "Сеть на feth-паре" в
`docs/MAME_NETWORK.md`) -- никакого дополнительного responder-а для
`RESOLVE`/`PING` не нужно.

## Сценарий 0: первым делом -- преамбула до connect

```text
UNETTEST 192.168.7.1 80
```

Смотреть строго до `connect 192.168.7.1:80`:

```text
UNETTEST - universal network DLL smoke test
Loading ...UNETRTL.DLL
DLL: UNETRTL  v...
caps=0x023F
abi=0x0100
net: ...
NETINIT ok
IP: 192.168.7.2
resolve: 192.168.7.1
ping: <N> ms
connect 192.168.7.1:80
```

Если MAME зависает/крашится раньше `NETINIT ok` -- сохранить
скриншот/лог MAME на этом самом месте, это самостоятельная находка
(harness такой сбой больше не предсказывает). Если дошло до
`connect ...` -- переходить к сценарию A ниже.

## Сценарий A: TCP (CONNECT/SEND/RECV)

Терминал 1 (responder):

```sh
sudo python3 tools/dev/unettest_tcp_probe.py --bind 192.168.7.1 --port 80
```

Дождаться `READY mode=echo bind=192.168.7.1:80`. Терминал 2 (опционально,
для независимого подтверждения по проводу):

```sh
sudo tcpdump -i feth1 -nn -vv tcp port 80
```

В DSS: `UNETTEST 192.168.7.1 80`.

**Ожидаемо:** терминал 1 показывает `CONN from 192.168.7.2:...`, затем
`REQ (... bytes, matches UNETTEST shape=True): b'HEAD / HTTP/1.0\r\nHost:
192.168.7.1\r\n...'`, затем `REPLIED and closed`; в DSS -- `request
sent`, `--- reply ---` и HTTP-заголовки ответа, затем `--- closed ---`,
`done.`. Если `Connect failed.` при полном молчании responder-а (tcpdump
не видит SYN) -- байт не ушёл в сеть вовсе: это локальная проблема
DLL/драйвера, фиксировать с полным выводом отдельно.

Контрольный запуск (baseline для сравнения) -- эмулировать реальный
обрыв соединения после успешного `CONNECT`:

```sh
sudo python3 tools/dev/unettest_tcp_probe.py --bind 192.168.7.1 --port 80 --mode abort
```

Подтверждает, что `SEND`/`RECV` на разорванном соединении в `UNETTEST`
никогда не показывают `NERR_PARAM`. На практике `SEND` успевает уйти
раньше, чем RST долетает до стороны DSS, а первый же `RECV`
получает `NERR_CLOSED` (`DE=0`) и коротким путём сразу печатает
`--- closed ---` -- без отдельной строки `receive error`/`lasterr`,
это ожидаемо (см. `.recv_closed_data`/`.recv_closed` в
`unettest.asm`). Если вместо этого видно зависание или `NERR_PARAM` --
вот это уже находка, фиксировать отдельно.

## Сценарий B: UDP (`-u`)

Терминал 1:

```sh
sudo python3 tools/dev/udp_echo.py --bind 192.168.7.1 --port 7777
```

В DSS: `UNETTEST -u 7777 192.168.7.1`. Ожидать `udp poll0 ok`,
`request sent`, `udp reply: len=21 data=SPRINTER UNETTEST UDP`,
`udp echo ok`. Дополнительно повторить с явным размером
(`UNETTEST -u 7777 1472 192.168.7.1`) -- проверяет zero-copy путь на
границе стандартного MTU -- и `UNETTEST -u 7777 1473 192.168.7.1`, где
ожидается локальный `NERR_PARAM` от самого бэкенда (payload больше
лимита), см. `docs/UNETRTL.md`.

## Сценарий C: два канала (`-2`, MULTICHAN)

Терминал 1:

```sh
python3 tools/dev/dual_server.py --host 192.168.7.1 --control-port 9099 --data-port 9100
```

(остальные флаги -- см. `tools/dev/dual_server.py --help`; порт по
умолчанию 9099 -- control, 9100 -- data). В DSS:
`UNETTEST -2 9100 192.168.7.1 9099`. Ожидать `dual channel ports
9099/9100`, оба `connect ...`, `request sent`, `reply rode our ACK`/`no
reply on our ACK`, поток `data bytes: N` + `data stream continuous`,
`control reply: ...`.

## Сценарий D: passive open (`-l`, LISTEN/UNLISTEN)

`UNETTEST -l LISTENPORT` арендует `LISTENPORT` на канале 0 и принимает
(accept + `SEND`/`RECV`) ровно двух пиров подряд на том же канале,
чтобы доказать документированный авто-re-arm (`docs/UNETRTL.md`,
"Passive open (LISTEN)"), затем вызывает `UNLISTEN`. Тестовый клиент
(`unettest_listen_client.py`) закрывает соединение сам сразу после
чтения ответа, поэтому re-arm обычно срабатывает через собственный
`NERR_CLOSED` внутри `RECV` (drain-вызов видит FIN пира), а не через
явный `CLOSE` со стороны `UNETTEST` -- оба пути документированы как
эквивалентные.

Терминал 1 (после того как `UNETTEST` напечатает `listening; connect a
peer now`):

```sh
python3 tools/dev/unettest_listen_client.py --host 192.168.7.2 --port 9000
```

В DSS: `UNETTEST -l 9000 192.168.7.1`.

**Ожидаемо:** после `listening; connect a peer now` запустить терминал 1
-- ожидать `waiting for peer #1`, `peer accepted`, `request sent`,
затем (клиент читает ответ и сам закрывается) `peer closed after
reading reply (re-armed)`. Запустить терминал 1 **второй раз** (`re-arm`
проверяется именно повторным подключением на тот же порт) -- ожидать
`waiting for peer #2`, снова `peer accepted`/`request sent`/`peer
closed after reading reply (re-armed)`, затем `unlisten done`. Если
второе подключение не
проходит -- это находка про сам re-arm; зафиксировать отдельно.
(Harness уже проверяет арминг/таймауты/UNLISTEN этого режима; настоящий
входящий accept возможен только здесь.)

## Сценарий E: non-blocking SEND (`-a`, ASYNCSEND)

`UNETTEST -a` делает `SETOPT SENDSLICE`, затем `CONNECT HOST:PORT`,
затем `SEND` ~1200 байт против пира, который намеренно не читает сокет
(закрывая TCP receive window), чтобы поймать хотя бы один `NERR_AGAIN`.

Терминал 1:

```sh
python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080
```

В DSS: `UNETTEST -a 192.168.7.1 8080`.

**Ожидаемо:** терминал 1 покажет `CONN from 192.168.7.2:...`, паузу
`--stall` секунд, затем `drained N bytes total` (N должно быть 1200).
В DSS -- одну или несколько строк `SEND suspended (NERR_AGAIN),
confirmed so far: <n>`, затем `request sent` и `resumes needed: <k>`
(k >= 1 подтверждает, что `NERR_AGAIN`/resume реально отработали, а не
молча проскочили; harness покрывает только k=0 -- его скриптовый пир
ACKает мгновенно). Если `resumes needed: 0` -- `SEND` ни разу не
приостановился; увеличить `--stall` в `unettest_asyncsend_stall.py` или
уменьшить `--rcvbuf` (ОС может округлять запрошенный размер вверх).

## Что сохранить в evidence

Шаблон: `docs/evidence/UNETRTL_TEST_TEMPLATE.md`. На каждый сценарий:
полный текстовый вывод DSS (или скриншот), полный вывод responder-а
(терминал 1), при желании `tcpdump`, версия/SHA-256 `distr/*.img`.
