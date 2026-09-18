# Проекции

- **Область.** `lib/core/es/projection.ex`, `lib/core/es/projection/**`; у потребителя — модули
  `use Core.Es.Projection`, таблицы их read-моделей, ReadRepo над ними и алерты проекций.
- **Читать перед.** Новой проекцией; правкой `project/1`, `clear/0`, `events:`, `version:` или
  таблиц read-модели; деревом проекций в приложении; удалением проекции; выбором между проекцией
  и подписчиком брокера; алертами проекций.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Объявление

Проекция — модуль `use Core.Es.Projection`; его место в приложении —
`deps/core/docs/rules/app/13-repos.md`, «Проекции read-модели». Она строит read-модель из событий
хранилища агрегатов обоих видов в порядке глобальной позиции и пишет чекпоинт в той же транзакции
пачки (ADR-0009). Перечень опций, шагов пачки и исходов — moduledoc `Core.Es.Projection`.

- `name:` MUST NOT меняться: строка чекпоинта привязана к имени, другое имя — новая проекция,
  которая стартует с начала истории.
- `events:` — модули событий `<Aggregate>.Event.<Name>`, а не семейство `<Aggregate>.Event`;
  кодек события — `<Aggregate>.Event.Codec` (`11-domain.md`). Тег, известный кодеку, но не
  объявленный, пачка пропускает, поэтому события, которые проекции не нужны, объявлять
  SHOULD NOT.
- Голова `project/1` MUST матчить модуль события, catch-all — MUST NOT: событие без клаузы падает
  и откатывает пачку, а catch-all пропустил бы его молча, сдвинув чекпоинт.
- `clear/0` MUST очищать каждую таблицу, которую пишет `project/1`: пачка зовёт его при старте с
  начала истории, и забытая таблица сохранит строки прошлого прогона.

Проверяется: `CompileError` в `use Core.Es.Projection` — нет `project/1` или `clear/0`; в
`events:` семейство, не событие или событие вне `tags:` кодека `<Aggregate>.Event.Codec`;
предупреждение при сборке на строке `use Core.Es.Projection` — у `project/1` нет clause модуля
`events:` или опечатка в поле нагрузки без паттерна `%Payload{}` (`make consumer-check`);
`use Core.Es.ProjectionCase` — `clear/0` очищает каждую таблицу, которую `project/1` пишет на
golden-фикстурах.

```elixir
# плохо — семейство вместо модулей событий и catch-all: необъявленное событие теряется молча
use Core.Es.Projection,
  name: "account_list",
  events: [Account.Event]

def project(_event), do: :ok

# плохо — имя из модуля: переименование модуля молча стартует проекцию с начала истории
use Core.Es.Projection,
  name: inspect(__MODULE__),
  events: [Account.Event.Opened, Account.Event.Closed]

# хорошо
use Core.Es.Projection,
  name: "account_list",
  events: [Account.Event.Opened, Account.Event.Closed]

@impl true
def project(%Account.Event.Opened{} = event), do: insert_row(event)

def project(%Account.Event.Closed{} = event), do: close_row(event)

@impl true
def clear do
  {_count, nil} = DAO.delete_all(AccountList.Row)
  :ok
end
```

## Read-модель

- Проекция MUST NOT иметь внешних эффектов — Oban, HTTP, кеш, публикация в брокер: историю через
  проекцию прогоняют заново, и эффект повторился бы на каждом событии. Реакция с внешним
  эффектом — подписчик брокера (`14-events-outbox.md`, «Идемпотентность потребителей»).
- Таблицу read-модели MUST писать ровно одна проекция — в `project/1` и `clear/0`: `clear/0`
  соседней проекции стёр бы чужие строки, а usecase или воркер, пишущий в таблицу, разошёлся бы
  с историей.
- ReadRepo MAY читать таблицы нескольких проекций.
- Таблицы read-модели MUST лежать в той же базе, что `es_events`: read-модель и чекпоинт пишет одна
  транзакция (ADR-0009). Read-модель в другом сервисе — интеграция через брокер.

```elixir
# плохо — уведомление из проекции: пересборка разошлёт его заново по всей истории
def project(%Account.Event.Closed{} = event) do
  {:ok, _job} = Oban.insert(Notify.new(%{account_id: dump(event.aggregate_id)}))
  close_row(event)
end

# плохо — таблицу AccountList.Row пишет и DeliveryList.Projection: её clear/0 сотрёт чужие строки
def project(%Delivery.Event.Registered{} = event), do: DAO.insert_all(AccountList.Row, rows(event))

# плохо — read-модель в другой базе: строки и чекпоинт пишут разные транзакции
def project(%Account.Event.Opened{} = event), do: ReportsRepo.insert_all(AccountList.Row, rows(event))

# хорошо — проекция пишет только свою таблицу в DAO, уведомление шлёт подписчик брокера
def project(%Account.Event.Closed{} = event), do: close_row(event)
```

## Дерево

Проекции приложения MUST стоять в одном `Core.Es.Projection.Supervisor` со всем списком: дубль
`name:` виден только в полном списке, а второе дерево на ноде не стартует. Дерево ставится на всех
нодах — пачки одной проекции разводит её блокировка. Опции и цикл читателя — moduledoc
`Core.Es.Projection.Supervisor` и `Core.Es.Projection.Reader`; config и env библиотека не читает.

- `enabled: false` и пустой `projections:` — `:ignore` с `info`: приложение стартует без дерева.
- `Core.Es.Projection.Supervisor.watch_list/1` принимает те же опции, что и дерево
  (`17-otp-concurrency.md`, «Дерево процессов»).
- `notifications:` — сигнал чекпоинта между нодами: `true` (по умолчанию) — слушатель на
  соединении из `repo.config()`, keyword — опции соединения поверх `repo.config()`, `false` — ни
  слушателя, ни `NOTIFY` пачек ноды. `NOTIFY` пачки берёт на commit общую на кластер блокировку
  и без слушателей (ADR-0013).
- За pgbouncer в transaction mode `notifications: true` MUST NOT: `LISTEN` через пулер
  уведомлений не получает, и ожидание молча сводится к шагам. Слушателю нужен keyword с прямым
  хостом базы — опции соединения поверх `repo.config()`.
- Нода держит по соединению слушателя на каждый различный `repo:` проекций; нода с
  `enabled: false` соединений не открывает.

Env-ключи `ES_PROJECTIONS_*` и их чтение в `config/runtime.exs`, сборка списка и опций одной
функцией приложения, выбор `notifications:` и расчёт лимита соединений —
`deps/core/docs/rules/app/17-otp-concurrency.md`, «Проекции и процессы агрегата».

Проверяется: `ArgumentError` в `Core.Es.Projection.Supervisor.start_link/1` — модуль без
`use Core.Es.Projection`, дубль `name:`; второе дерево на ноде — отказ старта.

```elixir
# плохо — слушатель за pgbouncer в transaction mode: LISTEN через пулер уведомлений не получает
notifications: true

# хорошо — слушатель в обход пулера, прочее — из repo.config()
notifications: [hostname: System.fetch_env!("DB_DIRECT_HOST"), port: 5432]
```

## Read-after-write

Когда клиент сразу после команды читает read-модель, вызывающий после успеха usecase ждёт проекцию
— `Projection.await(Agg, %Agg.ID{} = aggregate_id, timeout)` у модуля своей проекции. Цель —
последнее событие потока агрегата на момент вызова; `Agg` — модуль, в котором лежит кодек событий
`<Aggregate>.Event.Codec`, то есть сам агрегат. `await/3` генерирует `use Core.Es.Projection` —
clause на каждый агрегат, чьи события есть в `events:`: агрегат не из `events:`, ID другого
агрегата и невозможная clause по результату — предупреждение при сборке. Исходы, опрос и режим
`:inline` тестового дерева — moduledoc `Core.Es.Projection`, «Ожидание»; место вызова — после
commit, вне `Transact.run` (`20-agreements.md`, CQS); тест — `19-testing.md`, «Проекции».
Реализацию `Core.Es.Projection.Await.run/5` (`@doc false`) звать MUST NOT: модуль проекции и тип
агрегата в ней — параметры, и сборка не сверяет ни агрегат, ни ID.

Проверяется: предупреждение при сборке вызывающего — агрегат не из `events:`, ID другого агрегата,
невозможная clause по результату `await/3` (`make consumer-check`).

Сломанный быстрый путь ожидания — `LISTEN` через пулер, `notifications: false` на одной из
нескольких нод — ошибкой не виден: ожидание доходит шагами страховки (ADR-0013). Медленное
ожидание SHOULD разбирать по `duration` `[:es, :projection, :await]`: держится на уровне шагов
`await_min_ms:` … `await_max_ms:`, а не пачки, — сигнал чекпоинта не доходит.

```text
# плохо — медиана ожидания кратна шагам страховки, а пачки короче: сигнала нет, ответ даёт шаг
# хорошо — медиана ожидания на уровне длительности пачки: ответ даёт сигнал
histogram_quantile(0.5, sum by (le, projection)
  (rate(my_app_prom_ex_es_projection_await_duration_milliseconds_bucket[5m])))
```

`:projection_timeout` и `:projection_rebuilding` — не отказ команды: запись уже закоммичена.
Повтор команды по ним MUST NOT — команда исполнится второй раз; вызывающий отвечает успехом
записи без свежей read-модели либо ошибкой ожидания.

```elixir
# плохо — повтор команды по таймауту ожидания: запись уже закоммичена
with {:error, %Error{code: :projection_timeout}} <- open_and_await(id, params, context),
     do: open_and_await(id, params, context)

# плохо — реализация ожидания мимо await/3: ID другого агрегата сборка не видит
Core.Es.Projection.Await.run(projection, projection.__es_projection__(), "account", order_id, 5_000)

# хорошо — usecase записал и закоммитил, вызывающий ждёт проекцию и читает read-модель
with {:ok, _version} <- Accounts.Open.call(id, params, context),
     :ok <- AccountList.Projection.await(Account, id, 5_000) do
  AccountList.ReadRepo.get(id, :current, context)
end
```

## Версия и пересборка

Подъём `version:` пересобирает проекцию на месте: первая пачка новой версии очищает read-модель
через `clear/0` и прогоняет историю заново, а пачка старого кода получает `:outdated` и событий не
читает (ADR-0011). Пока чекпоинт ниже цели пересборки, read-модель неполна; достижение цели —
`info` «цель пересборки достигнута».

- `version:` MUST подниматься, если правка меняет read-модель уже обработанных событий:
  - `project/1` даёт для них другой результат;
  - в `events:` добавлен модуль, события которого уже есть в истории;
  - из `events:` удалён модуль, чьи строки остались в read-модели.
- Новый, ещё не записанный модуль события и рефакторинг без смены результата `version:`
  SHOULD NOT менять: пересборка не бесплатна и видна пользователю неполной read-моделью.
- `version:` MUST NOT понижаться: строку с версией выше пачка не перезаписывает, и проекция стоит
  в `:outdated`. Откат выкладки — новый коммит со старой логикой и `version:` выше текущей.
- Миграция таблиц read-модели при пересборке на месте SHOULD быть расширяющей — новая таблица,
  nullable-колонка, колонка с default: миграция идёт до смены кода, и старые ноды ещё пишут и
  читают эти таблицы. Несовместимая — новая проекция («Новая проекция»); сужение схемы —
  отдельной выкладкой после пересборки.

```elixir
# плохо — project/1 стал писать статус, версия прежняя: у строк обработанных событий статуса нет
use Core.Es.Projection,
  name: "account_list",
  events: [Account.Event.Opened, Account.Event.Closed],
  version: 1

def project(%Account.Event.Opened{} = event), do: insert_row(event, status: :open)

# плохо — несовместимая миграция: старые ноды до смены кода пишут и читают колонку name
rename table(:account_list), :name, to: :title

# хорошо — версия поднята, миграция расширяющая
use Core.Es.Projection,
  name: "account_list",
  events: [Account.Event.Opened, Account.Event.Closed],
  version: 2

alter table(:account_list) do
  add :status, :string
end

# плохо — версия поднята за переименование хелпера: результат прежний, read-модель неполна зря
version: 3

# плохо — откат выкладки понижением: строку версии 2 пачка не перезапишет, проекция в :outdated
version: 1

# хорошо — откат новым коммитом: логика версии 1, версия выше текущей
version: 3
```

## Новая проекция

Read-модель без окна неполных данных строит новая проекция под новым `name:` со своими таблицами;
кода для этого в библиотеке нет (ADR-0011). Переход на неё SHOULD идти в три выкладки:

1. Новый модуль (`version: 1`) и миграция его таблиц, read-путь прежний; ждать `info` «цель
   пересборки достигнута» с новым `projection=`.
2. ReadRepo читает новые таблицы, модуль старой проекции удалён.
3. Миграция удаляет таблицы старой проекции и её строку чекпоинта («Удаление»).

- Таблицы проекции MUST NOT удаляться в выкладке, которая убирает её модуль или читающий их
  ReadRepo: миграция идёт до смены кода, и старые ноды ещё проецируют и читают.
- Выкладки 2 и 3 MAY совмещаться, если миграции потребителя идут после смены кода на всех нодах.

```text
# плохо — таблицу account_list удаляет миграция выкладки, которая убирает её проекцию и ReadRepo
выкладка 1: AccountListV2.Projection, create table(:account_list_v2)
выкладка 2: ReadRepo → account_list_v2, AccountList.Projection удалён, drop table(:account_list)

# хорошо
выкладка 1: AccountListV2.Projection, create table(:account_list_v2); ждать info о цели
выкладка 2: ReadRepo → account_list_v2, AccountList.Projection удалён
выкладка 3: drop table(:account_list), delete_checkpoint("account_list")
```

## Удаление

Проекция, убранная из кода, просто не запускается, а её строку `es_checkpoints` библиотека сама
не удаляет: при поэтапной выкладке проекция ещё жива на старых нодах.

- Строку удалённой проекции MUST удалять миграция потребителя, которая удаляет её таблицы, —
  `Core.Es.Migration.delete_checkpoint/1`.
- Имя удалённой проекции MUST NOT переиспользоваться: забытая строка вернула бы новую проекцию на
  чужой чекпоинт, без `clear/0` и с середины истории.

```elixir
# плохо — новая проекция под именем удалённой: её version: 1 застанет чужую строку чекпоинта
use Core.Es.Projection,
  name: "account_list",
  events: [Account.Event.Opened, Account.Event.Renamed]

# хорошо — миграция выкладки 3: таблицы и строка чекпоинта удалённой проекции
def up do
  drop table(:account_list)
  Core.Es.Migration.delete_checkpoint("account_list")
end

def down, do: raise(Ecto.MigrationError, "удаление проекции account_list необратимо")
```

## Эксплуатация

Метрики проекций отдаёт `Core.Es.PromEx`: перечень — его moduledoc, подключение — README. Алерты
проекций приложение SHOULD заводить по таблице; пороги — `<порог>` и `for:` — выбирает само, по
объёму истории и нагрузке. Имена метрик — с префиксом PromEx `my_app_prom_ex_es_`.

| Алерт | PromQL | Смысл |
|---|---|---|
| `EsProjectionRetrying` | `sum by (projection, error) (increase(my_app_prom_ex_es_projection_retry_total[5m])) > 0`, `for: <порог>` | пачка отказывает подряд и чекпоинт стоит; событие отказа — `event_id=` в `warning` читателя |
| `EsProjectionLagging` | `max by (projection) (my_app_prom_ex_es_projection_lag_seconds) > <порог> and on (projection) max by (projection) (my_app_prom_ex_es_projection_rebuilding) == 0` | проекция не успевает за записью: read-модель отстаёт, `await` уходит в `:projection_timeout` |
| `EsProjectionRebuildLong` | `max by (projection) (my_app_prom_ex_es_projection_rebuilding) == 1`, `for: <порог>` | пересборка идёт дольше ожидаемого; прогресс — убывание `my_app_prom_ex_es_projection_lag_seconds` |
| `EsProjectionOutdated` | `max by (projection) (my_app_prom_ex_es_projection_outdated) == 1`, `for: <порог>` | код проекции на ноде старше строки чекпоинта дольше выкладки: выкладка застряла или `version:` понижена |

- `EsProjectionLagging` MUST идти с условием `rebuilding == 0`: при пересборке отставание равно
  возрасту непройденной истории, и алерт горел бы на каждой пересборке — её ведёт
  `EsProjectionRebuildLong`.
- Отставание одинаково на всех нодах: агрегировать его SHOULD через `max by (projection)`, а не
  `sum` — сумма умножила бы значение на число нод.
- Алерт SHOULD NOT заводиться на падение читателей и процессов агрегата — его ведёт
  `WorkerDown` (`21-observability.md`, «Рекомендованные алерты»); на `checkpoint_orphan` —
  сирота штатна между выкладками 2 и 3 новой проекции; на отказ записи снапшота,
  `version_mismatch` процесса агрегата и `await` с `:timeout`.

```yaml
# плохо — отставание без условия пересборки: алерт горит на каждой пересборке
- alert: EsProjectionLagging
  expr: max by (projection) (my_app_prom_ex_es_projection_lag_seconds) > 300

# хорошо
- alert: EsProjectionLagging
  expr: >
    max by (projection) (my_app_prom_ex_es_projection_lag_seconds) > 300
    and on (projection) max by (projection) (my_app_prom_ex_es_projection_rebuilding) == 0
  for: 5m
```

## Связанные правила

- События, кодек и совместимость тегов — `14-events-outbox.md`
- Дерево процессов и `watch_list` — `17-otp-concurrency.md`
- Дерево проекций в приложении — `deps/core/docs/rules/app/17-otp-concurrency.md`
- ReadRepo и View — `13-repos.md`
- Раскладка проекций и read-модели — `deps/core/docs/rules/app/13-repos.md`
- Тесты проекций — `19-testing.md`
- Span пачки проекции — `21-observability.md`
