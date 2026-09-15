# OTP и конкурентность

- **Область.** `lib/core/outbox/{poller,cleaner}.ex`, `lib/core/mq/stream/**`, `lib/core/pubsub/**`,
  `lib/core/es/projection/{supervisor,reader,registry}.ex`,
  `lib/core/es/aggregate/process/server.ex`; у потребителя — его дерево супервизии.
- **Читать перед.** Новым `GenServer` или супервизором, правкой `init/1` / `handle_continue/2`,
  таймаутов `call`, backoff, mailbox, `terminate/2` и graceful shutdown.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Дерево процессов

`MyApp.Application` — композиционный корень, `strategy: :one_for_one`. Поддеревья с внутренним
порядком запуска (`Writer` → `Poller` → `Cleaner`, `Reader` → `Subscriber` → `Bootstrap`) —
собственные `Supervisor` со `strategy: :rest_for_one`: падение нижнего звена перезапускает
всё, что от него зависит.

Отключаемое поддерево MUST возвращать `:ignore` из `start_link/1` (а не стартовать пустым) и
писать в лог причину на уровне `info` — «запущен» / «отключён» / «пропущен: нет зависимости».

Каждый критичный процесс MUST быть в `MyApp.PromEx.Workers.watch_list/0` — по нему работает алерт
`WorkerDown`. Элемент выключенного поддерева MUST NOT включаться: `Core.Workers.PromEx` поле
`required:` не читает, и отсутствующий процесс даёт `up=0` на ноде с `enabled: false`. Хелпер
поддерева принимает те же опции, что и его `start_link/1`.

```elixir
# плохо — на ноде с enabled: false читателя нет, up=0
def watch_list, do: [%{component: "es_projection:account_list", name: AccountList.Projection}]

# хорошо — при enabled: false элементов нет
def watch_list, do: Core.Es.Projection.Supervisor.watch_list(MyApp.Projections.opts())
```

## `init/1`

`init/1` выполняется синхронно внутри `Supervisor.start_link` и блокирует старт всего дерева.

- MUST NOT: сетевые вызовы, запросы в БД, подписки в брокере, `sleep`, ожидание внешних систем.
- Тяжёлая инициализация → `{:ok, state, {:continue, :setup}}` + `handle_continue/2`.
- `send(self(), :setup)` в `init/1` — устаревший идиом: сообщение встаёт в общую очередь и
  может обогнаться внешним сообщением; `handle_continue` выполняется до любого другого.
- В `init/1` допустимы только разбор `opts`, сборка state, регистрация в локальном `Registry` и
  `schedule/2` таймера.
- Опции процесса MUST проверяться при разборе (`Core.Helper.StartOpts`): опечатка в них — ошибка
  конфигурации, и место ей — `ArgumentError` в `init/1`. Непроверенное значение всплывает позже и
  хуже: `FunctionClauseError` в `handle_continue/2` (супервизор уходит в цикл рестартов) либо
  молчаливый backoff, в котором опечатка неотличима от недоступной внешней системы.

Внешнее подключение (подписка на брокер, коннект) устанавливается в `handle_continue/2`
и **не** роняет процесс при сбое: попытка повторяется с backoff от `:retry_min_ms`
до `:retry_max_ms`. Образец — `Core.Mq.Stream.Reader`:

- пока подключения нет, читающий API отдаёт нейтральный ответ (`:empty`), а не ошибку:
  подписчики опрашивают процесс каждые ~100 мс, и ошибка на каждом цикле залила бы лог;
- недоступность видна по `warning` при каждой неудачной попытке (частота ограничена
  backoff'ом) и по флагу в `info/1`, который уходит в gauge PromEx;
- подключение запрашивается **явно** (`connection.connect/0`) и идемпотентно: lazy-соединение
  само не подключается и молча буферизует запросы до таймаута;
- сбой соединения приходит не как `{:error, _}`, а как `exit` по таймауту `GenServer.call` —
  такой путь нужно ловить (`catch :exit, reason`), иначе ретраи не сработают.

## `GenServer.call`

- У каждого `call` — **явный** timeout, соразмерный работе на той стороне; дефолтные 5000 мс
  писать явно, если они действительно подходят.
- Вызов, за которым стоит сеть или batch в БД, — `:infinity` только при наличии внешнего
  ограничения (например единственный писатель + fail-stop в `Stream.Writer.put_many/2`).
- `call` в процесс, который сам ходит по сети без backpressure, — источник каскадных таймаутов:
  такой обмен делать `cast` + явным ack-сообщением.

## Mailbox и backpressure

- Неограниченная очередь сообщений — дефект: процесс, принимающий сигналы чаще, чем успевает
  их обрабатывать, растит mailbox до OOM. Алерт `WorkerMailboxHigh` ловит это постфактум.
- Повторяющиеся сигналы-«будильники» MUST схлопываться: в начале и в конце цикла вычерпать
  накопившиеся сообщения (`flush_wakes/0` в `Core.Outbox.Poller`), а не обрабатывать каждое.
- Чтение из брокера — по кредитам (`Stream.Reader`, `reader_credit` = число in-flight чанков),
  а не «всё, что пришло».

## `Task` и параллелизм

- `Task.async_stream/3` — всегда с `max_concurrency:` и `on_timeout: :kill_task`; `ordered: false`
  ставить осознанно, когда порядок результатов не нужен.
- Задачи, переживающие вызывающего, — только под `Task.Supervisor`; «осиротевший» `Task.start`
  запрещён.
- Параллелизм, влияющий на порядок доставки или на инварианты агрегата, — запрещён
  (см. «Единственность поллера» в `14-events-outbox.md`).

## Имена процессов

- Статический синглтон — `name: __MODULE__` или атом из конфига (`poller_name`).
- Динамические процессы — `Registry`, не атомы: `String.to_atom` на внешних данных запрещён
  (`20-agreements.md`).
- Имя, по которому будят процесс (`Poller.wake/1`), MUST приходить из конфига, а не вычисляться:
  отсутствующий процесс → `:ok` (best-effort), а не падение.
- Исключение — получатели `wake`, которых порождает само дерево по своему списку (читатели
  проекций): получатель MUST регистрироваться в `Registry` с `keys: :duplicate` сам, под ключом
  сигнала, а отправитель будит через `Registry.dispatch/3`; Registry не запущен → `:ok`. Имена в
  конфиге дали бы второй список рядом со списком дерева.

```elixir
# плохо — имена читателей в конфиге расходятся со списком проекций дерева
config :core, Core.Es.Projection, readers: [AccountList.Projection]

# хорошо — читатель в init/1 регистрируется под типами агрегатов, append будит по типу пачки
:ok = Core.Es.Projection.Registry.register(Map.keys(declaration.streams))
AfterCommit.register(fn -> Core.Es.Projection.Registry.wake(type) end)
```

## `terminate/2` и graceful shutdown

- `terminate/2` вызывается не всегда (kill, падение супервизора) — критичное состояние на него
  не завязывать; корректность обеспечивать persist'ом до подтверждения.
- Нужен гарантированный cleanup ресурса — `try/after` внутри самой операции (`20-agreements.md`),
  а не `terminate/2`.
- `trap_exit` MUST стоять в двух случаях, иначе штатная остановка супервизором убивает процесс
  сигналом и `terminate/2` не вызывается вовсе:

| Случай | Пример | Что теряется без `trap_exit` |
|---|---|---|
| процесс владеет внешним ресурсом | `Stream.Reader` (подписка), `Stream.Writer` (producers) | ресурс висит в брокере до таймаута соединения |
| единица работы выполняется целиком в одном колбэке | `Outbox.Poller` (reserve → publish → save_results), `MqSubscriberReliable` (обработка → commit), `Es.Projection.Reader` (пачка `project/1` → чекпоинт) | результат уже сделанной работы не записан: пачка остаётся `:in_work` до истечения аренды, сообщение переотправляется, пачка проекции откатывается и идёт заново |

- У такого процесса child_spec MUST задавать `:shutdown` с запасом на единицу работы
  (`Poller` — `@shutdown_ms`, читатель проекции — `shutdown:` дерева), иначе супервизор добьёт его
  на середине.

## Backoff у периодических циклов

Цикл, ходящий в БД или сеть по таймеру, MUST различать успех и сбой при планировании
следующего тика: фиксированный интервал на лежащей зависимости даёт полную частоту запросов
и заливает лог. Схема — `retry_min_ms` × 2 до `interval_ms` (`Outbox.Cleaner`,
`Outbox.Poller.schedule_backoff/1`), сброс на первом успехе.

Сбоем считается и **успешно завершённый цикл с неуспешной работой**: `Outbox.Poller`
отдаёт `:retry`, когда пачка сохранена, но хоть одна запись не опубликована, и уходит
в backoff — иначе непроходимая голова очереди повторялась бы без паузы
(`14-events-outbox.md`, «Poller scheduling»; ADR-0002).

Следующий тик нового периодического цикла SHOULD вычислять чистая функция `@doc false` от исхода
цикла и состояния backoff'ов, с тестом таблицей исходов без процесса
(`Core.Es.Projection.Reader.next_tick/3`): ветку, спрятанную в `handle_info/2`, проверяет только
процесс с таймером.

```elixir
# плохо — задержка считается в handle_info: ветку backoff проверит только процесс с таймером
def handle_info(:tick, state) do
  result = run_batch(state)
  Process.send_after(self(), :tick, if(result == :idle, do: state.idle_ms, else: 0))
  {:noreply, state}
end

# хорошо — решение о тике отдельно, тест — таблица исходов в ExUnit.Case, async: true
{delay, backoff} = next_tick(state.backoff, result, flush_wakes())

assert Reader.next_tick(backoff, :idle, false) == {50, %{backoff | idle_ms: 100}}
```

## Тесты процессов

Правила тестов OTP-процессов — sandbox для порождённых процессов, синхронный `run_once/1`
вместо `sleep`, `async: false` у теста с именованным синглтоном — `19-testing.md`.

## Связанные правила

- Outbox / MQ / порядок доставки — `14-events-outbox.md`
- Архитектура и композиционный корень — `10-architecture.md`
- Тесты — `19-testing.md`
