# PROTOTYPE, wipe me

Spike для [тикета 13](../../issues/13-task-eventstore-spike.md). Проверка на 2026-09-13; сырой вывод — `out/`,
скрипты — `scripts/`. Утверждения research — [05-es-libraries.md](../../research/05-es-libraries.md), раздел
«EventStore (без Commanded)».

## Окружение

| Что | Версия |
|---|---|
| Elixir / OTP | 1.20.3 / 29.0.1 (erts 17.0.1) |
| PostgreSQL | 18.4 (`postgres:18-alpine`, `make infra-up`, порт 5433) |
| `eventstore` | 1.4.8 |
| `ecto_sql` / `postgrex` / `jason` | 3.14.0 / 0.22.4 / 1.4.5 — как в `mix.lock` `:core` |
| транзитивные | `ecto` 3.14.2, `db_connection` 2.10.2, `decimal` 3.1.1, `telemetry` 1.4.2 — как в `:core`; `fsm` 0.3.1, `gen_stage` 1.3.2 |

БД: `eventstore_spike_prototype_wipe_me` (Ecto в `public`, EventStore в `schema: "event_store"`, один логин) и
`eventstore_spike_public_prototype_wipe_me` (оба в `public`). Соединение для `conn:` — способ из moduledoc
`EventStore` («Using an existing database connection or transaction»):
`%{pid: pool} = Ecto.Adapter.lookup_meta(Repo); Process.get({Ecto.Adapters.SQL, pool})`.

## a. Компиляция — `out/a_compile.txt`

Успех, `mix compile` без ошибок. Предупреждения только из зависимостей, свой код — чисто:

- `eventstore`: `<%#` deprecated ×2 (`sql/statements/insert_events.sql.eex`); unused `require Logger`
  (`Storage.Lock`, `Storage.Database`); type warning «struct expected on struct update» —
  `Streams.Stream.prepare_events/4`, `Subscriptions.SubscriptionFsm.handle_action_response/2` ×2 (через `use Fsm`);
  «clause never used» — `SubscriptionFsm.change_state/2` (макрос `fsm`);
- `gen_stage`: unused `require Logger` (`Dispatchers.PartitionDispatcher`);
- `postgrex`: `xref: [exclude: ...]` в `mix.exs` deprecated.

На проверках c–g поведение этих мест не сломано. **Research:** «1.20 не подтверждён, код не собирался» — теперь
собран и работает на 1.20.3 / OTP 29.

## b. `event_store.create` / `init` и соседство с Ecto — `out/b_init.txt`, `out/b2_*`, `out/b3_*`, `out/b4_*`

- `create` создаёт БД и схему `event_store`; `init` — таблицы `events`, `streams`, `stream_events`, `snapshots`,
  `subscriptions`, `schema_migrations` (версия 1.3.2), функции `event_store_delete`, `event_store_exception`,
  `notify_events`, триггеры запрета UPDATE/DELETE и `event_notification` на `streams`, строку `$all` (`stream_id` 0).
  Mix-задачи приложение не стартуют (`ensure_all_started(:postgrex)`, `event_store.config()`).
- В отдельной схеме: `event_store.schema_migrations` и `public.schema_migrations` Ecto живут рядом, конфликта нет.
- В одной схеме (`public`) — конфликт имени `schema_migrations` в обе стороны:
  - Ecto первым → `event_store.init`: `42P07 duplicate_table`, init откатывается целиком;
  - EventStore первым → `ecto.migrate`: `42703 column s0.version does not exist`.
  - Обход — `migration_source: "ecto_schema_migrations"` у Repo: migrate проходит (b4).

**Research:** «версия схемы — таблица `schema_migrations`», «store в разных схемах» — подтверждено; столкновение
с `schema_migrations` Ecto в одной схеме — новое.

## c. Append через `conn:` в `Repo.transaction` — `out/c_tx.txt`

- Внутри TX соединение — `%DBConnection{conn_mode: :transaction}`; вне TX `Process.get` даёт `nil`.
- Commit: строка Ecto и 2 события сохранены вместе; до commit извне не видно ни строки, ни потока, ни сдвига `$all`.
- `Repo.rollback` и `Repo.transact` с `{:error, _}` (как `Transact.run`): откатываются строка, поток и счётчик `$all`.
- 1000 событий (ветка с `Postgrex.transaction` на переданном `conn`): commit и rollback внешней TX работают так же.
- **Ловушка:** вызов вне TX передаёт `conn: nil`, а `parse_opts` делает `opts[:conn] || config[:conn]` — append
  молча идёт через пул store, мимо транзакции, с результатом `:ok` (c6).
- Ключ `{Ecto.Adapters.SQL, pool}` — приватный `defp key/1` ecto_sql, не публичный API Ecto.

**Research:** «встаёт в `Transact.run` через `conn:` из process dict Ecto» — подтверждено.

## d. Конфликт ожидаемой версии в TX — `out/d_conflict.txt`, `out/d7_bulk_no_query.txt`

| Случай | append вернул | Состояние TX | Следующий запрос | Итог TX |
|---|---|---|---|---|
| d1: версия устарела (проверка SELECT-ом) | `{:error, :wrong_expected_version}` | не aborted (`:transaction`) | проходит | fun вернулся нормально → **commit** строки Ecto |
| d2/d3: гонка, T1 не закоммичен | через ~1000 мс ожидания T1 — `{:error, :wrong_expected_version}` (unique `ix_stream_events`) | aborted (`:error`) | `25P02 in_failed_sql_transaction` | `Repo.transaction` → `{:error, :rollback}` без исключения; `Repo.transact` → `{:error, {:error, :wrong_expected_version}}` |
| d4: гонка создания потока, `:any_version` | `{:error, %Postgrex.Error{code: :in_failed_sql_transaction}}` — повтор `maybe_retry_once` на aborted `conn` | aborted | `25P02` | `{:error, :rollback}` |
| d5: то же без внешней TX у T2 | `:ok` (повтор на пуле store прошёл) | — | — | — |
| d6/d7: 1000 событий, версия устарела | `{:error, :wrong_expected_version}` | `:error` — вложенный `Postgrex.rollback` помечает всю внешнюю TX | `DBConnection.ConnectionError` | `{:error, :rollback}`; соединение пула Ecto **разорвано** (`[error] … disconnected: transaction rolling back`) |
| d8: то же, `Repo.transact` с `{:error, _}` | `{:error, :wrong_expected_version}` | — | — | `{:error, {:error, …}}`, без разрыва |

**Research:** «после ошибки SQL TX aborted, повтор на `:duplicate_stream_uuid` не пройдёт» — подтверждено. Уточнения:
при устаревшей версии без гонки TX **не** aborted, и без `{:error, _}` из usecase строка Ecto коммитится; «все
ошибки — `{:error, атом}`» — опровергнуто для d4 (возвращается `%Postgrex.Error{}`).

## e. Блокировка `$all` — `out/e_lock.txt`

Базово: append 1 события — медиана 1,38 мс без TX, 1,49 мс в `Repo.transaction` (30 прогонов). T1 делает append
в новый поток A и держит TX 2000 мс, T2 стартует сразу после append T1:

| T2 | Длительность T2 | Завершился после commit T1 |
|---|---|---|
| e1: `Repo.transaction` + append в новый поток B | 2003 мс | +1 мс |
| e2: append в новый поток B без внешней TX | 2004 мс | +1 мс |
| e3: append в существующий поток без TX | 2004 мс | +1 мс |
| e4: `Repo.transaction` + INSERT в таблицу Ecto | 1 мс | не ждал |
| e5: `read_all_streams_backward` без TX | 2 мс | не ждал |

`pg_stat_activity` во время ожидания: `Lock / transactionid`, `ShareLock` — ожидание xid T1 на строке `$all`.
**Research** (отчёт 01): «строка `$all` заблокирована до commit внешней транзакции» — подтверждено: любой append
в любой поток store сериализуется на всё время самой длинной транзакции с append; чтение и чужие таблицы не ждут.

## f. Подписки — `out/f_subscribe.txt`

- `subscribe_to_all_streams` (persistent, `start_from: :current`) и transient `subscribe("$all")`.
- Append через `conn:` в TX, 1000 мс ожидания внутри TX: до commit не пришло ничего; после commit — через
  12–15 мс оба получили события (transient — пачкой, persistent — по одному, дальше после `ack`).
- `Repo.rollback`: за 1500 мс не пришло ничего; следующий append — `event_number` без дыры (1090 → 1091).
- Append без TX: доставка через 2 мс.

**Research:** «подписки увидят события после commit usecase» — подтверждено.

## g. Append через `conn:` без запущенного store — `out/g_no_store.txt`

- OTP-приложение `:eventstore` запущено как зависимость, `EventstoreSpike.EventStore` — нет; `Store.config()` работает.
- `append_to_stream`, `read_stream_forward`, `stream_info` с `conn:` → `RuntimeError` «could not lookup
  EventstoreSpike.EventStore because it was not started or it does not exist»; SQL не отправлен, TX жива.
- Недокументированно: внутренний `EventStore.Streams.Stream.append_to_stream/5` (`@moduledoc false`) с `schema:` и
  `serializer:` пишет в TX без супервизора — это не публичный API.

**Research:** «supervisor store должен быть запущен и с `conn:`» — подтверждено.

## Не проверено

- Совместимость `conn:` из process dict с `Ecto.Adapters.SQL.Sandbox` (`Core.DataCase`).
- Число соединений store (пул 10 + advisory locks + notifications), `shared_connection_pool`, `column_data_type: "jsonb"`.
- Нагрузка: только пара конкурирующих транзакций; потеря notifications при `auto_reconnect` (#309); другие версии PostgreSQL.
