# 31: Резерв ключа из ПДн

**What to build:** автор домена объявляет модуль ключа из ПДн (email, телефон) `personal: true`.
- В `es_key_reservations` тогда лежит индекс, посчитанный хранилищем ключей, а не значение; `find/2` ищет по
  открытому значению, как раньше.
- Usecase уничтожения снимает резерв событием агрегата-владельца в той же транзакции, и ключ снова свободен.

**Blocked by:**
- [23: ПДн-значение в `es_events` и outbox: шифрование и расшифровка](23-personal-value-in-events-and-outbox.md)

**Status:** resolved

**Spec:** [Crypto-shredding: ПДн в событиях под ключом субъекта](../spec.md) — «Резерв ключа из ПДн
(`Core.Es.KeyReservation`)»; ADR-0077

- [x] Опция `use Core.Es.KeyReservation, …, personal: true`:
      - `key` строки — `text[]` из одной строки индекса поверх `to_key/1`, одинаково на записи и в `find/2`;
      - модули без флага работают как сейчас.
- [x] `append` резервов считает индексы всех шагов `{:reserve, value}` пачки одним вызовом `index` до записи. Отказ
      откатывает транзакцию, `Es.Transact` его не повторяет.
- [x] `find/2` по-прежнему отдаёт `Agg.ID.t() | nil`, при отказе порта — `Core.Exc`.
- [x] `{:reserve, value}` с Prim `personal: true` у модуля без флага — `ArgumentError` на `append`.
- [x] Фикстура: `Account.HolderKey, personal: true` в области `fixture.holder` с `:release` на `Closed`, в составе
      `KeyedRepo`.
- [x] Тесты, `Core.DataCase`:
      - прямой `SELECT` — индекс, а не значение;
      - `find/2` по значению;
      - занятость ключа (`code:`) работает;
      - `:release` в транзакции `destroy_key/3` освобождает ключ, и другой агрегат его занимает;
      - `ArgumentError`;
      - отказ `index` откатывает `append`.
- [x] Фикстура-потребитель: модуль ключа `personal: true`, маркеры `# expect:` — по факту.
- [x] Свод:
      - `13-repos.md` «Резервы ключей» — `personal: true`;
      - 23 — следы индекса после снятия;
      - app/23 «Usecase уничтожения» — снятие резервов из ПДн событием с `:release`, MUST;
      - app/23 «Идентификатор субъекта» — идентификатор из ключа из ПДн, MUST NOT;
      - app/13 «Уникальность без индекса состояния» — ссылка; `personal: true` ставится только на область без строк.
- [x] `CHANGELOG.md`:
      - «Изменения контракта макросов» — `personal:` у `KeyReservation`;
      - сквозной пункт — резерв ключа из ПДн.
- [x] `make` зелёный.
