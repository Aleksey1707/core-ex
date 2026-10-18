# AEAD на `:crypto` OTP и двухуровневые ключи для поля ПДн

Исследование на 2026-10-18. Версии: локально Erlang/OTP 29.0.1 (`crypto` 5.9, OpenSSL 3.0.13 30 Jan 2024),
Elixir 1.20.4 — на них проверки API и замеры; документация `crypto` на erlang.org — OTP 29.1.2 (`crypto` 5.10);
исходник `crypto.erl` 5.9 из установленного OTP; `fernetex` 0.5.0 (`deps/fernetex`, тег `0.5.0` = `0cde005`);
Fernet spec `20dead4`; NIST SP 800-38D (ноябрь 2007), его ревизия Rev. 1 — на стадии pre-draft. Цитаты — на
языке оригинала. «Вывод:» — заключение, которого в источнике прямо нет. Скрипты проверок лежат во временном
каталоге сессии и в репозиторий не входят; их результаты приведены ниже [4].

## Вопрос

[Тикет](../issues/03-research-otp-aead.md): чем шифровать значение поля средствами `:crypto` OTP 29 без новых
зависимостей — AEAD-шифры и их пределы, AAD с адресом значения, DEK субъекта под KEK и ротация KEK, формат
шифротекста в jsonb, цена на поле и на свёртку, годится ли `fernetex`.

## AEAD-шифры `:crypto`: API, nonce, тег

**API** [1]:

| Функция | С версии | Шифрование → | Расшифровка → |
|---|---|---|---|
| `crypto_one_time_aead/6` | OTP 22.0 | `{CipherText, Tag}`, тег длины по умолчанию | — |
| `crypto_one_time_aead/7` | OTP 22.0 | `{CipherText, Tag}` по `TagLength` | `PlainText \| error` по `Tag` |
| `crypto_one_time_aead_init/4` | OTP 28.0 | хэндл `crypto_state()` по ключу и длине тега | то же |
| `crypto_one_time_aead/4` | OTP 28.0 | `CipherText <> Tag` по хэндлу, IV, тексту, AAD | `PlainText \| error` |

Направление задаёт последний аргумент `EncFlag`: `true` — шифрование, `false` — расшифровка [1].

- Отказ проверки — атом `error`, а не исключение. Неверный тип или размер аргумента — исключение
  `error:{badarg, C_FileInfo, Description}` («3-tuple style») [1].
- Локально [4]: чужой AAD, чужой ключ, изменённый шифротекст, пустой тег, IV в 11 байт → `:error`. Ключ в 16 байт
  для `aes_256_gcm` → `ErlangError {:badarg, {~c"aead.c", 215}, ~c"Unknown cipher or invalid key size"}`.
- Вывод: обёртке нужна своя проверка размера ключа или `rescue`, чтобы отдать `{:error, _}`.
- Предупреждение документации: «The length of the tag at decryption is not checked by the function… Otherwise the
  decryption may succeed if the given tag only matches the start of the proper tag» [1]. Локально 4-байтовый
  префикс 16-байтового тега GCM принят расшифровкой [4]. Вывод: длину тега проверяет обёртка (ровно 16 байт).
- AAD — `iodata()`, может быть `<<>>` (тогда это AE без AD) [1]. Локально проверен iolist в тексте и AAD [4].

**Шифры.** `:crypto.supports(:ciphers)` локально содержит `aes_128_gcm`, `aes_192_gcm`, `aes_256_gcm`, `aes_*_ccm`,
`chacha20_poly1305`. Нет AES Key Wrap, SIV, OCB и XChaCha20 [4].

| Шифр | Ключ | Nonce, байт | Тег, байт | Источник |
|---|---|---|---|---|
| `aes_256_gcm` | 32 байта | ≥ 1; `cipher_info` — 12; NIST рекомендует 96 бит | 1–16, по умолчанию 16 | [1][2][5] |
| `chacha20_poly1305` | 32 байта | 1–16; локально только 12 | 16 | [2][4][7] |

Локально `chacha20_poly1305` с nonce 8, 16 и 24 байта — `badarg` «Bad IV length» [4].

**Уникальность nonce.**

- GCM: «The probability that the authenticated encryption function ever will be invoked with the same IV and the
  same key on two (or more) distinct sets of input data shall be no greater than 2^-32» (SP 800-38D, §8) [5].
- Случайный nonce — «RBG-based construction» (§8.2.2): «the length of the random field shall be at least 96 bits»;
  свободное поле рекомендуется пустым, то есть весь IV случаен [5].
- Последствие повтора в GCM — восстановление hash subkey, подделка шифротекста и AAD, потеря аутентичности
  (Appendix A) [5].
- ChaCha20-Poly1305: «If a nonce is repeated, then both the one-time Poly1305 key and the keystream are identical
  between the messages. This reveals the XOR of the plaintexts» (RFC 8439, §4) [7].
- Несколько узлов на одном ключе: «those devices must coordinate to ensure that the nonces are unique» (RFC 5116,
  §3.1) [8].
- `strong_rand_bytes/1` — CSPRNG, по умолчанию `RAND_bytes` OpenSSL; может бросить `error:low_entropy` [1].
- Вывод: счётчик (§8.2.1) потребовал бы координации узлов на каждый ключ, поэтому без общего состояния остаётся
  случайный 96-битный nonce.

**Предел шифрований на ключ.**

- GCM со случайным IV (любой длины): «The total number of invocations of the authenticated encryption function
  shall not exceed 2^32 … with the given key» (§8.3) [5].
- RFC 8439 предела вызовов для случайного nonce не задаёт: только N_MIN = N_MAX = 12 октетов, P_MAX ≈ 256 GB на
  пару (ключ, nonce) [7].
- `draft-irtf-cfrg-aead-limits-13` (2026-09-03) случайные nonce в свои пределы не включает: «have a higher chance
  of nonce collisions and are not considered for the limits in this section» [9].
- Вывод: вероятность коллизии случайных 96-битных nonce при q шифрованиях ≈ q²/2^97. Это 2^-33 при q = 2^32 и
  ~10^-21 при q = 10^4. С DEK на субъекта предел 2^32 недостижим: это число значений одного субъекта.

**Длина тега.** SP 800-38D допускает t ∈ {128, 120, 112, 104, 96} бит, 64 и 32 — только для особых применений;
одна длина на ключ (§5.2.1.2) [5]. Ревизия Rev. 1: «will remove support for authentication tags whose lengths are
less than 96 bits», черновика текста нет (2nd pre-draft call, 2026-06-01) [6]. RFC 8439: «Tag truncation MUST NOT
be done» [7]. Локально `aes_256_gcm` выдал тег в 3 байта по `TagLength = 3`, то есть OTP короткий тег не
запрещает [4].

**Длина открытого текста не скрывается**: «A ciphertext, denoted C, whose bit length is the same as that of the
plaintext» (§5.2.1.2) [5]. Локально 4 байта текста дали 4 байта шифротекста [4]. Вывод: длина значения ПДн
остаётся видна и после уничтожения ключа; достаточно ли этого для уничтожения — вопрос тикета 01.

## AAD: привязка шифротекста к адресу

**Что даёт.**

- AAD аутентифицируется, но не шифруется: «addresses, ports, sequence numbers, protocol version numbers, and other
  fields that indicate how the plaintext or ciphertext should be handled» (RFC 5116, §2.1; то же в SP 800-38D,
  §5.2.1.1) [5][8]. На расшифровке AAD передаётся тот же, иначе `error` [1][4].
- Вывод: без AAD шифротекст под ключом субъекта расшифровывается в любом месте. Перенос значения в другое поле,
  событие или поток того же субъекта не обнаруживается. Угроза — запись в `es_events`, outbox или сообщение
  брокера в обход кода.
- JWE кладёт в AAD защищённый заголовок с `alg` / `enc` / `kid` (RFC 7516, §5.1 шаг 14) [14]. Вывод: версия
  формата и идентификатор ключа в AAD не дают подменить заголовок.

**Чем мешает.**

- Апкаст — колбэк `upcast(old_tag, envelope)` над сырым конвертом до `load`; меняются только тег и нагрузка
  (ADR-0010, «Решение») [20]. Вывод: ключа у апкастера нет. Если в AAD входят тег события или имя поля, апкаст,
  который переименовывает поле или переносит значение, делает его нерасшифровываемым.
- Заголовок события — `id`, `aggregate_id`, `aggregate_version`, `at`, `by` (`Core.Es.Event`); по ADR-0010 апкаст
  его не меняет [20]. Вывод: AAD из полей заголовка и заголовка формата переживает апкаст, AAD с тегом и именем
  поля — нет.
- Кодек сейчас видит только значение поля, `%Context{}` и адреса у него нет (`map.md`, Notes) [20]. Вывод: любой
  AAD, кроме заголовка формата, требует доставить адрес в `dump` / `load` поля. Это вопрос тикета 05.
- Случайный nonce делает шифротекст недетерминированным: одинаковый текст даёт разные шифротексты [4]. Вывод:
  `es_key_reservations.key` и поиск точным совпадением на шифротексте не работают — тикет 10.

## Двухуровневая схема: DEK субъекта под KEK

- Термины: «The key used to encrypt data itself is called a data encryption key (DEK). The DEK is encrypted (also
  known as wrapped) by a key encryption key (KEK)» [13].
- Google Cloud KMS: «Generate DEKs locally», «Use a strong algorithm such as 256-bit … (AES) in Galois Counter Mode
  (GCM)», «store the DEK near the data that it encrypts», «Do not use the same DEK to encrypt data from two
  different users», «Do NOT store a plaintext DEK» [13].
- Там же: «Generate a new DEK every time you write the data. This means you don't need to rotate the DEKs» [13].
  Вывод: DEK на запись снимает срок DEK, но уничтожение субъекта тогда — удаление всех его DEK, а не одного.
- Один ключ — одно назначение: «a single key shall be used for only one purpose (e.g., encryption, integrity
  authentication, key wrapping…)» (SP 800-57 Pt1 Rev5, §5.2) [12]. Вывод: KEK — не `secret_key`
  `Core.Security.Secret`: тот уже шифрует секреты через Fernet [19][20].
- Рекомендуемый срок использования (Table 1): DEK и KEK — по < 2 лет на создание шифротекстов, < OUP + 3 лет на
  чтение; дольше — «serious consideration should be given to the risks» [12]. Вывод: события хранятся без срока,
  так что DEK субъекта со временем выходит за рекомендованный срок; смена DEK субъекта — открытый вопрос.
- Вывод: DEK — 32 случайных байта из `strong_rand_bytes/1`. Вывести DEK из KEK и id субъекта (KDF) нельзя: такой
  ключ восстанавливается из KEK, и удаление его не уничтожает.

**Чем обернуть DEK.**

| Вариант | Размер обёртки DEK (32 байта) | Nonce | AAD | В OTP 29 | Источник |
|---|---|---|---|---|---|
| AES-256-GCM под KEK | 12 + 32 + 16 = 60 байт | случайный, ≤ 2^32 на версию KEK | да | да | [1][4][5] |
| AES-KW (RFC 3394) | n + 1 блок по 64 бита = 40 байт | нет, детерминирован | нет | нет | [4][10] |
| AES-KWP (RFC 5649) | 40 байт; key data от 1 октета | нет | нет | нет | [4][11] |
| Fernet (`fernetex`) | 57 + 48 = 105 байт, 140 символов | случайный IV 128 бит | нет | зависимость есть | [18][19] |

- AAD у обёртки GCM — например, id субъекта и версия KEK. Вход AES-KW — только key data и KEK (RFC 3394, §2.2.1)
  [10].
- AES-KW: целостность — константа `A6A6A6A6A6A6A6A6` в A[0], проверяется при развёртке (RFC 3394, §2.2.3) [10].
  KWP: AIV из `A65959A6` и 32-битного MLI (RFC 5649, §3) [11].
- В `cipher_info/1` есть режим `wrap_mode`, но шифров Key Wrap нет ни в `supports(:ciphers)`, ни в Algorithm
  Details [1][2][4].
- Вывод: AES-KW на `:crypto` — ручная реализация §2.2.1 (6n вызовов `aes_256_ecb`), то есть своя криптография.

**Ротация KEK без перешифровки данных.**

- Cloud KMS: ротация не перешифровывает данные — «data encrypted with previous key versions isn't automatically
  re-encrypted with the new key version». Старые версии ключа остаются, пока их не уничтожат; «Destroying a key
  version that is still in use can cause permanent data loss» [13].
- Вывод: шифротекст поля ссылается на DEK, а не на KEK. Ротация — развернуть каждый DEK старым KEK, обернуть новым,
  записать с идентификатором версии KEK (аналог `kid`, RFC 7516 §4.1.6 [14]).
- Вывод: данные не трогаются, старый KEK живёт до конца перевёртки. Каждая перевёртка — вызов GCM под новым KEK и
  идёт в его предел 2^32.
- Вывод: уничтожение KEK — массовое уничтожение всех DEK под ним; копии обёрнутого DEK в бэкапах таблицы ключей
  читаются, пока жив KEK — тикет 07.

## Формат шифротекста в jsonb

- В jsonb нет двоичного типа: примитивы `string` (`text`, `\u0000` запрещён), `number`, `boolean`, `null`
  (PostgreSQL 18, Table 8.23) [16]. Вывод: шифротекст кодируется в строку; base64 (RFC 4648 §4) или base64url
  (§5) [17].
- Прецеденты бинарной раскладки:
  - Fernet: `Version ‖ Timestamp ‖ IV ‖ Ciphertext ‖ HMAC`, версия `0x80`, весь токен в base64url [18];
  - Tink: «prefix || IV || ciphertext || tag», префикс — байт версии `0x01` и 4 байта идентификатора ключа [15];
  - JWE compact: пять частей base64url через `.`; заголовок несёт `kid`, `alg`, `enc` [14].
- `crypto_one_time_aead/4` выдаёт `CipherText <> Tag` [1][4]. Вывод: раскладка `nonce ‖ ct ‖ tag` совпадает с ним
  и с Tink.
- Размеры для 64 байт текста [4][18]:

| Раскладка | Байт | Символов base64 |
|---|---|---|
| версия 1 + id ключа 16 (UUID) + nonce 12 + тег 16 + текст | 109 | 148 (146 base64url без padding) |
| то же без id ключа (ключ определяется адресом) | 93 | 124 |
| Fernet | 137 | 184 |

- Вывод: байт версии формата задаёт шифр, длины nonce и тега. Смена алгоритма — новая версия, старая читается
  дальше, как теги в ADR-0010 [20].
- Вывод: id ключа в шифротексте нужен, если ключ не выводится из адреса значения. С версиями DEK субъекта в id
  входит и версия. Единица ключа — тикет 04.
- Вывод: отличить шифротекст от открытого значения в jsonb помогает маркер: зарезервированный ключ объекта или
  префикс строки. Он же нужен, чтобы распознать значение после уничтожения ключа — тикет 06.

## Цена: шифрование и расшифровка

Грубый замер на машине разработчика, не проверено на нагрузке [4]. AMD Ryzen 7 8845HS (флаги `aes`, `vaes`,
`pclmulqdq`, `vpclmulqdq`), 16 планировщиков, один процесс, без конкуренции. OTP 29.0.1, `crypto` 5.9, OpenSSL
3.0.13, Elixir 1.20.4. Метод — `:timer.tc/2` в наносекундах после прогрева:

- одно значение — 25 серий по 20 000 вызовов, медиана серий;
- пачка из 500 — 400 повторов, медиана.

Два прогона, значение — 64 байта, AAD — 50 байт.

| Операция на одно значение | Медиана |
|---|---|
| `strong_rand_bytes(12)` | 0,74–0,75 мкс |
| AES-256-GCM шифрование: nonce + `/6` + сборка двоичной раскладки | 1,51–1,55 мкс |
| то же + `Base.encode64` | 1,88 мкс |
| AES-256-GCM расшифровка `/7` | 0,44–0,49 мкс |
| `Base.decode64!` + расшифровка `/7` | 1,21–1,23 мкс |
| расшифровка `/4` по готовому хэндлу / создание хэндла `init/4` | 0,50–0,54 / 0,79–0,80 мкс |
| ChaCha20-Poly1305: шифрование (+ nonce) / расшифровка | 1,62–1,65 / 0,62 мкс |
| развёртка DEK: AES-256-GCM, 32 байта под KEK | 0,41–0,42 мкс |
| `Fernet.generate` / `Fernet.verify` (`enforce_ttl: false`) | 7,7 / 7,1–7,2 мкс |
| `Base.decode64!` / `:base64.decode` (148 символов) | 0,56 / 0,43 мкс |

| Пачка из 500 значений (одно поле на событие свёртки) | Медиана | p95 |
|---|---|---|
| 500 × шифрование AES-256-GCM | 0,74–0,75 мс | 0,91–0,92 мс |
| 500 × расшифровка `/7` | 0,22 мс | 0,24–0,29 мс |
| 500 × (`Base.decode64!` + расшифровка) | 0,61 мс | 0,69–0,85 мс |
| развёртка DEK + 500 × (`Base.decode64!` + расшифровка) | 0,60–0,61 мс | 0,71–0,84 мс |
| `init/4` + 500 × `/4` | 0,26–0,27 мс | 0,30–0,32 мс |

- Вывод: на записи половина цены шифрования — генерация nonce. На чтении Base64 дороже самого шифра.
- Вывод: хэндл OTP 28 на коротких значениях выигрыша не даёт.
- Вывод: свёртка 500 событий с одним полем ПДн добавляет порядка 0,6 мс CPU. Чтение ключа из хранилища, разбор
  JSON и `load` кодека не измерялись.
- Опубликованных замеров `crypto_one_time_aead` на BEAM не найдено: поиск по вебу дал только замеры AES-GCM вне
  BEAM [21].

## `fernetex` и `Core.Security.Secret`

**Что делает `fernetex` 0.5.0** (`lib/fernetex.ex`) [19]:

- Ключ 32 байта = 16 байт подписи + 16 байт шифрования (стр. 142, 240).
- Шифр — `:crypto.crypto_one_time(:aes_128_cbc, …)` с PKCS#7-padding (стр. 266–267, 290–298), MAC —
  `:crypto.mac(:hmac, :sha256, …)` над `Version ‖ Timestamp ‖ IV ‖ Ciphertext` (стр. 178–179, 241–242).
- IV — `strong_rand_bytes(16)` (стр. 312), токен — `Base.url_encode64` с padding (стр. 243).
- Сравнение MAC — за постоянное время (стр. 181, 195–206), расшифровка — только после проверки MAC
  (encrypt-then-MAC, как в спецификации [18]).
- `verify/2` по умолчанию проверяет TTL 60 с (стр. 27–28, 99–100); `Core.Security.Secret` передаёт
  `enforce_ttl: false` [20].
- Ключ по умолчанию — `Application.get_env(:fernetex, :key)` (стр. 310); `Secret` всегда передаёт `key:` явно [20].
- Первый байт токена (`0x80`) не сверяется (стр. 138, 144–155), хотя спецификация требует «Ensure the first byte of
  the token is 0x80» [18]. Вывод: на безопасность не влияет — версия входит в HMAC.
- Спецификация задаёт только версию `0x80`, AES-128-CBC и HMAC-SHA256. В токене нет AAD и идентификатора ключа;
  метка времени — открытый заголовок [18].
- В `fernetex` нет проверки несколькими ключами: `verify/2` принимает один `key:` [19].
- Активность: 0.5.0 — 2024-11-27, прошлый релиз 0.4.0 — 2022-03-14. После тега — один коммит, правка README
  (`a2aa700`, 2024-11-27) [19].

**`Core.Security.Secret`** — один глобальный ключ `config :core, Core.Security.Secret, secret_key:`; `new/1` →
`Fernet.generate`, `reveal/1` → `Fernet.verify` [20]. Ключа на субъекта, AAD и id ключа нет.

**Годится ли.**

- Вывод: Fernet шифрует любым 32-байтовым ключом, поэтому технически годится и как шифр поля под DEK, и как
  обёртка DEK под KEK.
- Против:
  - нет AAD — адрес пришлось бы класть в открытый текст и сверять после расшифровки;
  - накладные расходы 57 байт + padding против 28 у GCM (nonce + тег; 45 — с версией и id ключа);
  - на 64 байтах медленнее GCM в 5 раз на шифровании и в ~15 раз на расшифровке [4];
  - CBC + HMAC вместо готового AEAD из `:crypto` [1].
- Вывод из кода: медленность — от Elixir-кода вокруг NIF: `Enum.reduce` при padding, `list_to_binary`, разбор и
  форматирование ISO 8601 времени на каждый вызов (стр. 235–237, 246–264, 290–298, 314).

## Развилки

1. **Шифр значения.**
   - AES-256-GCM: режим NIST SP 800-38D с явным пределом 2^32 на ключ и случайным IV ≥ 96 бит. Локально расшифровка
     быстрее ChaCha20-Poly1305 (0,44 против 0,62 мкс) — на CPU с AES-NI. Ревизия NIST уберёт теги < 96 бит;
     фиксированный тег в 16 байт её не задевает.
   - ChaCha20-Poly1305: тот же API и те же 12 / 16 байт. Предела для случайного nonce RFC 8439 и черновик CFRG не
     задают. Статус в FIPS-режиме OTP документация не называет. Вариант с 24-байтовым nonce (XChaCha) в OTP
     недоступен.
2. **Обёртка DEK.**
   - AES-256-GCM под KEK: есть в OTP, AAD привязывает обёртку к субъекту и версии KEK, 60 байт, предел 2^32 обёрток
     на версию KEK.
   - AES-KW / KWP: детерминирован, без nonce, 40 байт, без AAD. В OTP нет — своя реализация на `aes_256_ecb`.
   - Fernet: зависимость уже есть, без AAD, 140 символов.
3. **Состав AAD.**
   - пустой;
   - только заголовок формата (версия, id ключа) — не требует адреса в кодеке;
   - плюс `aggregate_id` / `aggregate_version` / `id` события — переживает апкаст, требует адрес в `dump` / `load`
     поля (тикет 05);
   - плюс тег и имя поля — ломает апкаст с переименованием или переносом поля.
4. **Формат в jsonb.**
   - строка base64 / base64url одной двоичной раскладки `версия ‖ [id ключа] ‖ nonce ‖ ct ‖ tag`;
   - JSON-объект с отдельными полями: длиннее, но поля видны проекции и при отладке.
   - id ключа — в шифротексте или из адреса (тикет 04).
5. **Источник KEK.**
   - отдельный ключ конфигурации (не `secret_key` `Secret`: SP 800-57 §5.2);
   - внешнее хранилище за портом (тикет 07).
   - Ротация в обоих случаях — перевёртка обёрток DEK с версией KEK, данные не трогаются.
6. **`fernetex`.**
   - остаётся только у `Core.Security.Secret`;
   - или служит шифром поля / обёрткой DEK ценой AAD, размера и скорости.

## Не найдено

- **AES-KW / KWP, SIV, OCB, XChaCha20-Poly1305** в `crypto` OTP 29: нет ни в документации, ни в
  `supports(:ciphers)`. Сторонние hex-пакеты не искались — новые зависимости вне границ карты.
- **HKDF** в `:crypto`: среди экспортов только `pbkdf2_hmac/5` [4]. Понадобится ли вывод подключей — не
  исследовалось.
- **Расхождение документации и сборки**:
  - Algorithm Details называет для `chacha20_poly1305` IV 1–16 байт, локальный OpenSSL 3.0.13 принимает только 12;
  - для GCM документация допускает тег 1–16 байт, локально принят 3-байтовый — NIST допускает от 4 байт [2][4][5].
- **Хэндл `crypto_one_time_aead_init/4`**: можно ли делить его между процессами — документация не говорит [1].
- **ChaCha20-Poly1305 в FIPS-режиме OTP** — страница FIPS шифр не называет [3]; локально FIPS-провайдера нет.
- **Dirty-планировщики**: уходят ли AEAD-NIF на коротких входах на dirty-планировщик — не проверено, C-исходник
  `crypto` в установке отсутствует.
- **Замеры под нагрузкой**: конкурентное шифрование, чтение ключа из БД, разбор JSON и `load` кодека не
  измерялись.
- **NIST SP 800-38F** (KW / KWP как одобренные режимы) не читался — вопрос отвечен по RFC 3394 / 5649.

## Источники

1. Erlang/OTP `crypto` reference manual (OTP 29.1.2, crypto 5.10): `crypto_one_time_aead/4,6,7`,
   `crypto_one_time_aead_init/4`, `strong_rand_bytes/1`, `cipher_info/1`, «Exceptions» —
   https://www.erlang.org/doc/apps/crypto/crypto.html ; локально `lib/crypto-5.9/src/crypto.erl`
   (стр. 111–135, 1440–1483, 1759–1900, 2015–2030)
2. Erlang/OTP `crypto` User's Guide, Algorithm Details, таблица «AEAD ciphers» —
   https://www.erlang.org/doc/apps/crypto/algorithm_details.html
3. Erlang/OTP `crypto` User's Guide, FIPS mode — https://www.erlang.org/doc/apps/crypto/fips.html
4. Локальные проверки и замеры, 2026-10-18: OTP 29.0.1, `crypto` 5.9, OpenSSL 3.0.13, Elixir 1.20.4, AMD Ryzen 7
   8845HS. Проверялись `supports(:ciphers)`, `cipher_info/1`, `crypto_one_time_aead/4,6,7` на граничных
   аргументах, `module_info(:exports)`; замеры — `:timer.tc/2`, медиана серий.
5. NIST SP 800-38D, Dworkin, «Recommendation for Block Cipher Modes of Operation: Galois/Counter Mode (GCM) and
   GMAC», November 2007: §5.2.1.1, §5.2.1.2, §8, §8.2.2, §8.3, Appendix A —
   https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
6. NIST, SP 800-38D Rev. 1, 2nd Pre-Draft Call for Comments, 2026-06-01 —
   https://csrc.nist.gov/pubs/sp/800/38/d/r1/2prd ;
   https://csrc.nist.gov/news/2026/gcm-and-gmac-block-cipher-modes-of-operation
7. RFC 8439, ChaCha20 and Poly1305 for IETF Protocols, June 2018: §2.3, §2.8, §4 —
   https://www.rfc-editor.org/rfc/rfc8439
8. RFC 5116, An Interface and Algorithms for Authenticated Encryption, January 2008: §2.1, §3.1 —
   https://www.rfc-editor.org/rfc/rfc5116
9. draft-irtf-cfrg-aead-limits-13, Usage Limits on AEAD Algorithms, 2026-09-03 —
   https://datatracker.ietf.org/doc/draft-irtf-cfrg-aead-limits/
10. RFC 3394, Advanced Encryption Standard (AES) Key Wrap Algorithm, September 2002: §2, §2.2.1, §2.2.3 —
    https://www.rfc-editor.org/rfc/rfc3394
11. RFC 5649, AES Key Wrap with Padding Algorithm, August 2009: §1, §3 — https://www.rfc-editor.org/rfc/rfc5649
12. NIST SP 800-57 Part 1 Rev. 5, Recommendation for Key Management, May 2020: §5.2, Table 1 —
    https://doi.org/10.6028/NIST.SP.800-57pt1r5
13. Google Cloud KMS: Envelope encryption; Key rotation —
    https://docs.cloud.google.com/kms/docs/envelope-encryption ; https://docs.cloud.google.com/kms/docs/key-rotation
14. RFC 7516, JSON Web Encryption (JWE): §4.1.6, §5.1, §7.1 — https://www.rfc-editor.org/rfc/rfc7516
15. Tink, Wire format — https://developers.google.com/tink/wire-format
16. PostgreSQL 18, JSON Types, Table 8.23 — https://www.postgresql.org/docs/current/datatype-json.html
17. RFC 4648, The Base16, Base32, and Base64 Data Encodings: §4, §5 — https://www.rfc-editor.org/rfc/rfc4648
18. Fernet spec `20dead4`, `Spec.md` —
    https://github.com/fernet/spec/blob/20dead475f53f11d20592baf29ad697163afc0cd/Spec.md
19. kennyp/fernetex `0.5.0` (`0cde005`), `lib/fernetex.ex` (локально `deps/fernetex`); hex.pm API —
    https://github.com/kennyp/fernetex/blob/0.5.0/lib/fernetex.ex ; https://hex.pm/api/packages/fernetex
20. Этот репозиторий: [`lib/core/security/secret.ex`](../../../lib/core/security/secret.ex),
    [`lib/core/es/event.ex`](../../../lib/core/es/event.ex),
    [ADR-0010](../../../docs/adr/0010-event-evolution-tag-upcast.md), [`map.md`](../map.md) (Notes), `config/test.exs`
21. Поиск замеров: веб-поиск «erlang crypto crypto_one_time_aead aes_256_gcm benchmark»; найдены eBACS
    (https://bench.cr.yp.to/results-nistlwc-aead/amd64-hiphop.html) и замеры на Rust — не BEAM
