# Настройка сети MAME для тестов RTL8019AS

Этот документ описывает рабочий процесс настройки сетевого backend MAME для
проверки утилит и драйвера данного репозитория. Документ — developer-only,
он не должен попадать в `DIST_DOC_FILES` и не отгружается в floppy image
для реального Sprinter.

Низкоуровневые подробности устройства MAME (опции запуска, log-строки,
конфигурация ISA-слотов, layout PROM, reset sequence, RX ring header)
описаны в `/Users/dmitry/dev/zx/sprinter/mame/MAME_RTL8019AS.md`. Здесь —
только то, что относится к процессу разработки и тестирования в этом
репозитории.

## Когда сеть нужна

Стейджи драйвера и стека из `sprinter_rtl8019_soft.md` делятся на две группы.

Сеть НЕ нужна:

- Этап 0: `HELLO.EXE` — вход/выход DSS, печать строки.
- Этап 1: `NICINFO.EXE` — обнаружение карты, page 0 ID `Pp` (`0x0A/0x0B`),
  PROM, MAC.
- Этап 2: `NICRAM.EXE` — round-trip remote DMA в packet RAM.
- Этап 3: `NICLB.EXE` — internal MAC loopback (`TCR=0x02`). Сейчас MAME
  возвращает loopback frame в RX ring, поэтому этап проверяется без какого
  бы то ни было хостового сетевого backend.

Запускать эти стейджи можно с `-networkprovider none` или вообще без флага.

Сеть нужна:

- Этап 4: `NICTX.EXE` — отправка broadcast Ethernet frame.
- Этап 5: `NICRX.EXE` — приём frame, сгенерированного хостом.
- Этап 6+: `PING/UDPTEST/TFTP/NTP/WGET/FTP` — полноценный обмен IPv4.

Для этих стейджей выбирается host network provider, и драйвер должен видеть
кадры на реальном MAC-адресе MAME-устройства.

## Выбор network provider

Целевая платформа разработки — macOS. На текущей сборке MAME из
`/Users/dmitry/dev/zx/sprinter/mame` доступно:

- `pcap` — основной провайдер для всех сетевых стейджей;
- `none` — пустой backend, для стейджей 0..3;
- `slirp` — на этой сборке/платформе НЕ доступен и не должен использоваться
  как baseline.

TAP/bridge-helper не входит в baseline. Если pcap покажет нестабильный RX,
TAP-вариант можно рассматривать отдельно, но до этого момента не вкладывать
в него работу.

Проверка списка провайдеров и интерфейсов:

```sh
/Users/dmitry/dev/zx/sprinter/mame/mame -listnetwork
```

Команда выводит доступные провайдеры в первой строке и список интерфейсов
ниже. Если в выводе нет `pcap`, MAME собран без libpcap — пересобрать с
`USE_PCAP=1` (см. `MAME_RTL8019AS.md`).

## Запуск с pcap на macOS

Базовая команда:

```sh
/Users/dmitry/dev/zx/sprinter/mame/mame sprinter \
    -isa1 rtl8019as \
    -networkprovider pcap \
    -verbose
```

Привязка к конкретному интерфейсу (имя берётся из `-listnetwork`):

```sh
/Users/dmitry/dev/zx/sprinter/mame/mame sprinter \
    -isa1 rtl8019as \
    -networkprovider pcap \
    -verbose
# затем в MAME UI: Tab -> Network Devices -> rtl8019as -> выбрать интерфейс
```

В CLI MAME `-network` относится к slot-устройствам, а конкретный pcap-интерфейс
выбирается через MAME UI (Tab → Network Devices) и сохраняется в `cfg/`.
Для CI-/скриптового запуска заранее подготовить `cfg/sprinter.cfg` с нужным
интерфейсом или менять его через стандартные средства MAME.

Скрипт-обёртка `run_sprinter_rtl8019as.sh` уже передаёт MAME аргументы и
печатает значения переменных `RTL8019AS_IOBASE/IRQ/MAC/NETDEV`. Для тестов
с сетью добавить `-networkprovider pcap` через позиционные аргументы:

```sh
./run_sprinter_rtl8019as.sh -networkprovider pcap
RTL8019AS_VERBOSE=1 ./run_sprinter_rtl8019as.sh -networkprovider pcap
```

## Права macOS на /dev/bpf

`pcap`-провайдер MAME открывает `/dev/bpfN` и требует прав на чтение/запись
этих устройств. На macOS по умолчанию они принадлежат root. Без прав MAME
запустится, но `pcap` не сможет открыть интерфейс и сетевые стейджи будут
тихо ничего не передавать.

Рабочие варианты:

1. **ChmodBPF из Wireshark.** Установить Wireshark или отдельный пакет
   ChmodBPF; он создаёт LaunchDaemon, который выставляет права на `/dev/bpf*`
   при старте системы. Это официально рекомендованный способ.
2. **Ручное выставление прав, временное.** До перезагрузки:

   ```sh
   sudo chmod g+rw /dev/bpf*
   sudo chgrp admin /dev/bpf*
   ```

   После reboot права сбросятся.
3. **Запуск MAME под `sudo`.** Допустимо для разовой проверки, но не
   рекомендуется как baseline: MAME пишет в `cfg/`, `nvram/`, `ini/`, и под
   `sudo` эти каталоги получат root-владельца.

Проверка, что pcap-доступ работает:

```sh
sudo tcpdump -i en0 -c 1 -n 2>&1 | head -5
```

Если `tcpdump` без `sudo` тоже работает (после ChmodBPF/chmod), MAME будет
видеть интерфейс.

## Выбор host-интерфейса

`-listnetwork` на macOS выводит много виртуальных интерфейсов (`utunN`,
`anpiN`, `awdl0`, `llw0`, `bridgeN`, `gifN`, `stf0`). Для тестов RTL8019AS
имеют смысл только реальные L2-интерфейсы:

- `en0` — обычно Wi-Fi или Ethernet, в зависимости от модели Mac;
- `en1..enN` — дополнительные Ethernet/USB-Ethernet адаптеры;
- `bridge0` — если настроен мост (например, для VM).

Wi-Fi-интерфейсы (`en0` на ноутбуках) с pcap работают, но имеют ограничения:

- ARP/broadcast от MAME-устройства уйдёт в Wi-Fi-сегмент и может быть
  отфильтрован/изменён точкой доступа;
- managed-mode Wi-Fi не пропускает чужие MAC из L2-broadcast в полноценном
  виде; некоторые ARP-replies приходят с подменённым MAC.

Для стабильных стейджей 4+ предпочтителен проводной Ethernet или
USB-Ethernet адаптер. Для домашней разработки на ноутбуке Wi-Fi обычно
работает для `NICTX` (host видит broadcast от MAME) и `PING` против
default gateway, но `FTP` с двумя TCP-сессиями через Wi-Fi проверять не
рекомендуется — пусть это будет проводной канал.

## Сетевой план для стейджей 4+

DHCP в раннем стеке нет, IP назначается статически в `NET.CFG`. Базовый
план для localhost-тестов:

```text
Sprinter (MAME):    192.168.7.2
Host (MAME-side):   192.168.7.1  или адрес интерфейса в той же подсети
Netmask:            255.255.255.0
Gateway:            192.168.7.1  (если нужен — иначе 0.0.0.0)
```

Если хост подключён к Wi-Fi `192.168.1.0/24`, удобнее назначить
Sprinter-стороне свободный адрес из этой же подсети, а не разворачивать
отдельную `192.168.7.0/24` (для этого пришлось бы поднимать промежуточный
роутер). Конкретные адреса фиксировать в `config/NET.CFG.sample` и в
`docs/USAGE.md` рядом с описанием каждой утилиты.

MAC карты MAME печатает при старте:

```text
rtl8019as: start io=0300 irq=3 prom=direct mac=02:80:19:xx:xx:xx
```

Этот MAC можно зафиксировать через `RTL_MAC` override в `NET.CFG`, чтобы не
зависеть от tag-hash генерации.

## Per-stage процедура проверки

### Этап 4: NICTX

Цель: убедиться, что host видит исходящий broadcast frame.

1. Запустить MAME с `-networkprovider pcap` и привязанным интерфейсом.
2. На хосте параллельно:

   ```sh
   sudo tcpdump -i en0 -e -nn -vv ether proto 0x88b5
   ```

   `0x88b5` — тестовый EtherType из спецификации.
3. В DSS запустить `NICTX.EXE`. Ожидать в MAME log:

   ```text
   rtl8019as: tx len=60
   ```

4. Ожидать в `tcpdump`:

   ```text
   ff:ff:ff:ff:ff:ff > 02:80:19:..:..:.., 88b5, length 46
   ```

Если `tx len=60` появляется, а `tcpdump` молчит — это проблема pcap-доступа
или выбора интерфейса, а не драйвера.

### Этап 5: NICRX

Цель: принять frame, отправленный с хоста.

Готовый host-side генератор: `tools/dev/send_frame.py` (требует `scapy`,
`pip install --user scapy`). По умолчанию шлёт unicast `0x88B5`-frame на
`02:80:19:11:22:33` с payload `"SPRINTER NICRX TEST"`:

```sh
sudo python3 tools/dev/send_frame.py --iface en0
```

В DSS:

```text
[X2] RX LEN=003C SRC=<host-MAC> TYPE=88B5
[X3] PAYLOAD=SPRINTER NICRX TEST...
[X4] HDR STS=01 NEXT=48 LEN=0040
RESULT OK
```

`STS=01` (PRX без PHY) — приём через physical match с PAR. Для unicast
это нормально; broadcast дал бы `STS=21`.

#### Важное ограничение macOS pcap для self-loopback

**Кадр, отправленный со стороны хоста через BPF, на macOS не возвращается
обратно в pcap-listener'ы той же машины.** На Wi-Fi: AP получает кадр, но
локальный интерфейс собственный TX обратно не получает. На проводном
Ethernet через свитч: то же самое. tcpdump кадр видит (через TX-tap), но
MAME-устройство — нет.

То есть `send_frame.py --iface en0` + `NICRX` на одной машине → `[E41]
PRX timeout`, даже если tcpdump показывает кадр уехавшим.

Признак этой проблемы в tcpdump: `src=00:00:00:00:00:00` (kernel
помечает self-traffic особым src), длина без padding'а до 60.

Workarounds (в порядке практичности):

1. **Тест с другой машины в той же сети.** Запустить
   `send_frame.py` на другом хосте, MAME с NICRX — на основном. AP
   доставит unicast обоим. Чистое решение, ничего не настраивать.

2. **`feth`-пара на macOS** (macOS 10.15+, без kext'ов):

   ```sh
   sudo ifconfig feth0 create
   sudo ifconfig feth1 create
   sudo ifconfig feth0 peer feth1
   sudo ifconfig feth0 up
   sudo ifconfig feth1 up
   ```

   `feth0` <-> `feth1` — внутренняя L2-пара, всё что идёт в один peer
   приходит в другой. Привязать MAME к `feth0` (Tab → Network Devices →
   rtl8019as → feth0), а `send_frame.py --iface feth1`. Кадр уйдёт в
   feth1 → попадёт во feth0 → MAME получит.

3. **Отдельная USB-Ethernet карта в шлейфе с другим устройством.**
   Если есть свободный port + второй девайс (ноутбук, RPi) — кабель
   между ними, `send_frame.py` со второго.

4. **Скип stage 5 в single-machine setup.** RX-цепочка карты уже
   доказана NICLB (internal loopback через `recv()`); NICRX в этом
   случае не валидирует ничего нового сверх pcap → MAME → driver
   delivery, что зависит от настройки сети, а не от драйвера.

Для CI/автоматики удобнее всего вариант (2) — `feth`-пара, без внешних
зависимостей.

### Этап 6+: PING / UDP / TCP

После NICRX/PING весь дальнейший обмен делается уже не через ручные
host-генераторы, а против обычных хостовых сервисов:

- `PING.EXE` против `192.168.7.1` (default gateway) или против самого хоста;
- `UDPTEST.EXE` против скрипта `examples/UDP_ECHO.PY` (по образцу
  `sprinter_wifi/network/examples/UDP_ECHO.PY`);
- `TFTP.EXE` против локального `tftp-hpa`/`atftpd` на хосте;
- `NTP.EXE` против локального mock-сервера (deterministic time) или
  публичного `pool.ntp.org`;
- `WGET.EXE` против локального `python3 -m http.server` с тестовыми
  файлами размером 2 KB / 24 KB / 56 KB;
- `FTP.EXE` против `vsftpd`/`pyftpdlib` в passive mode.

Все host-side helper-скрипты держать в `examples/` (батники для DSS) и в
`tools/dev/` (host-side python/shell). В дистрибутив `tools/dev/` не
попадает.

## Acceptance criteria для сетевого окружения

Окружение считается готовым к stage 4+, когда выполнены все пункты:

- `mame -listnetwork` показывает `pcap` среди провайдеров и видит хотя бы
  один реальный L2-интерфейс;
- `sudo tcpdump -i <iface> -c 1 -n` без `sudo` тоже работает (т.е. права на
  `/dev/bpf*` выставлены);
- `NICTX.EXE` приводит к строке `rtl8019as: tx len=60` в MAME log и к
  фиксации broadcast frame в `tcpdump` на хосте;
- `NICRX.EXE` принимает frame, сгенерированный `tools/dev/send_frame.py`;
- хост и MAME-Sprinter в одной IPv4-подсети согласно `NET.CFG`.

Если любое из условий не выполняется, сетевые стейджи отмечаются как
заблокированные и не записываются в `RESULT OK` — даже если код стейджа
визуально отработал.

## Известные ограничения и fallback'и

- **Wi-Fi на macOS** искажает L2-семантику (managed-mode AP, MAC randomization
  на target side). Для стабильных тестов FTP/большой WGET использовать
  проводное подключение.
- **slirp недоступен** в текущей сборке MAME. Не закладывать его в скрипты.
- **TAP** требует отдельного драйвера на macOS и не входит в baseline. Если
  pcap нестабилен, отдельной задачей описать TAP-helper и обновить этот
  документ.
- **BPF-права слетают после reboot** при ручном `chmod`. Постоянное решение —
  ChmodBPF.
- **RX через pcap получает все кадры интерфейса**, кроме собственного
  TX-трафика хоста (см. ниже). На шумной сети без аппаратного фильтра
  карта захлёбывается broadcast'ами, поэтому NICRX держит `RCR=0`
  (только physical match с PAR). На стейджах 6+ потребуется RX-фильтр
  по EtherType/IP в драйвере.
- **macOS pcap не loopback'ит self-traffic.** Кадры отправленные через
  BPF на той же машине (например, `send_frame.py --iface en0`) MAME
  через pcap не получает. Workaround: либо отправлять с другой машины
  в той же сети, либо использовать `feth0`/`feth1` пару (см. раздел
  "Этап 5: NICRX"). Признак: tcpdump видит TX, MAME — нет, и
  `src=00:00:00:00:00:00` в выводе tcpdump.
- **MAME release-сборка** в `mame_images/mame_release_v306_25.05.2025` не
  содержит RTL8019AS. Скрипт `run_sprinter_rtl8019as.sh` сначала ищет
  свежесобранный `../mame/mame`, иначе фоллбэчится на release. Перед
  каждой сессией проверять, что используется именно собранный из исходников
  binary, и `-listslots` показывает `rtl8019as`.

## Что прислать при ошибке сетевого стейджа

- команду запуска MAME (с `-networkprovider`, выбранным интерфейсом, путём
  к binary);
- фрагмент MAME log вокруг строк `rtl8019as: ...`;
- параллельный вывод `tcpdump`/`scapy` с хоста;
- скриншот DSS с stage-кодами и регистрами NIC;
- содержимое `NET.CFG` (без чувствительных данных);
- `mame -listnetwork` и имя выбранного интерфейса;
- проверку `ls -l /dev/bpf0` (права).
