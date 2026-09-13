# Проверить EventStore на Elixir 1.20 и append в `Transact.run`

Type: task
Status: resolved
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Факты для тикета «Своя реализация или готовая библиотека», которые research «Готовые ES-библиотеки на
Elixir и их совместимость с принципами core» вывел только из кода или не подтвердил:

- собирается ли `eventstore` 1.4.8 на Elixir / OTP этой машины (`:core` требует `~> 1.20`) вместе с
  версиями `ecto_sql` / `postgrex` из `mix.lock` `:core`; какие предупреждения;
- `mix event_store.create` / `event_store.init` на Postgres из `make infra-up`: схема, таблицы, как это
  соседствует с таблицами Ecto;
- append через `conn:` внутри `Repo.transaction` (аналог `Transact.run(DAO)`): события и строка Ecto
  коммитятся вместе, rollback откатывает оба;
- конфликт ожидаемой версии внутри такой транзакции: что возвращается, в каком состоянии транзакция
  (aborted?), что происходит с последующими запросами;
- блокировка `$all`: ждёт ли append в **другой** поток из второй транзакции commit первой; задержка на
  простом примере;
- видит ли подписка `subscribe_to_all_streams` события, записанные через `conn:`, и когда — после commit.

Работа — одноразовый mix-проект `.scratch/event-sourcing/prototype/eventstore-spike/` и отдельная БД
с именем, говорящим «PROTOTYPE, wipe me»; `mix.exs` и код `:core` не трогать.

## Answer

- `eventstore` 1.4.8 собирается и работает на Elixir 1.20.3 / OTP 29.0.1 с `ecto_sql` 3.14.0 / `postgrex` 0.22.4
  (PostgreSQL 18.4); предупреждения только в deps: `<%#` в SQL-шаблоне, unused `require Logger`, type warnings
  struct update в `Streams.Stream` и `SubscriptionFsm` (через `fsm`), `xref: [exclude:]` у `postgrex`.
- `event_store.init` создаёт свои таблицы, функции, триггеры и строку `$all`; в `schema: "event_store"` рядом
  с `public.schema_migrations` Ecto конфликта нет, в одной схеме `schema_migrations` сталкиваются в обе стороны
  (обход — `migration_source` у Repo).
- `conn:` из `Process.get({Ecto.Adapters.SQL, pool})` (способ из moduledoc, ключ — приватный в ecto_sql): commit
  сохраняет строку Ecto и события вместе, `Repo.rollback` / `Repo.transact` с `{:error, _}` откатывают оба и
  счётчик `$all`. Вне TX `conn` = `nil`, и append молча идёт через пул store мимо транзакции.
- Устаревшая версия без гонки: `{:error, :wrong_expected_version}`, TX не aborted, строка Ecto закоммитится, если
  usecase не вернёт `{:error, _}`.
- Гонка: второй append ждёт commit первого, затем `:wrong_expected_version`, TX aborted (`25P02` на следующем
  запросе), `Repo.transaction` → `{:error, :rollback}`; гонка создания потока возвращает `%Postgrex.Error{}`
  вместо атома — повтор идёт на aborted `conn`.
- От 1000 событий ошибка версии помечает всю внешнюю TX на откат, а при нормальном выходе из fun рвёт соединение
  пула Ecto; с `{:error, _}` из `Repo.transact` — чистый откат.
- `$all`: append в любой другой поток — из TX или без неё — ждёт commit транзакции с append (2003 мс при удержании
  2000 мс, базово 1,4 мс); INSERT в таблицы Ecto и чтение `$all` не ждут.
- Подписки (persistent и transient) до commit не получают ничего, после commit — через 12–15 мс; после rollback
  не приходит ничего, `event_number` без дыры.
- Без запущенного store append/read с `conn:` бросают `RuntimeError` «could not lookup»; обходится только
  внутренним `EventStore.Streams.Stream` (`@moduledoc false`).

[Результаты](../prototype/eventstore-spike/RESULTS.md)
