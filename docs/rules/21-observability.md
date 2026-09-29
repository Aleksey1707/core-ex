# Наблюдаемость

- **Область.** `lib/core/otel.ex`, `lib/core/otel/**`, `lib/core/telemetry.ex`,
  `lib/core/*/prom_ex.ex`.
- **Читать перед.** Новой метрикой, span'ом или атрибутом; правкой `Core.Otel` и словарей semconv;
  переносом контекста трассировки через асинхронный транспорт; алертом на подсистему библиотеки.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Разделение труда

| Сигнал | Чем | Где живёт |
|---|---|---|
| Метрики | `:telemetry` + PromEx-плагины (`Core.*.PromEx`) | Prometheus |
| Трейсы | `opentelemetry_api` через `Core.Otel` | OTLP-коллектор потребителя |
| Логи | `Logger` в stdout + `Core.Otel.LogFilter` | агент-сборщик, связь по `trace_id` |

OTel-метрики библиотека **не** вводит: дублирование одного счётчика двумя системами
даёт два несходящихся числа и два места, где его надо чинить. Новый показатель —
это `:telemetry`-событие плюс строка в PromEx-плагине.

Метрики event sourcing собирает `Core.Es.PromEx`, рекомендованные алерты проекций —
`22-projections.md`, «Эксплуатация».

Логи в OTLP не уходят: экспортёр логов для BEAM не выпущен в hex (`otel_log_handler`
лежит в `opentelemetry_experimental` без экспортёра). Пока это так, логи остаются
текстом в stdout, а связь с трейсом даёт `trace_id` в metadata.

## Зависимость от OTel

`opentelemetry_api` — **обычная** зависимость, не optional: без SDK её вызовы no-op
(`otel_tracer_noop`), экспортёров и сетевых соединений она не тянет, и приём
`if Code.ensure_loaded?/1` (как у клиентов брокеров, `10-architecture.md`) здесь
не нужен. SDK (`opentelemetry`, `opentelemetry_exporter`) подключает потребитель;
у библиотеки он `only: :test`.

Любая правка `Core.Otel` MUST оставаться no-op без SDK: ветки «если трассировка
включена» в вызывающем коде запрещены — их роль исполняет сам no-op tracer.

## Разделение `Core.Otel` и словарей

`Core.Otel` — **предметно нейтральный** фасад: span'ы, контекст, пропагация через
carrier. Он не знает ни про MQ, ни про HTTP; атрибуты приходят готовой картой
(`attributes:`), их имена — забота вызывающего. Своего словаря атрибутов у него нет,
кроме `error.type` / `core.error.kind` у `record_error/1`.

Словари живут отдельными модулями: `Core.Otel.Messaging` — операции обмена
сообщениями по semconv (`create` / `send` / `process`), `Core.Otel.Es` — event sourcing
(`project` — пачка проекции, `await` — ожидание проекции, `execute` — команда процесса
агрегата, атрибуты `core.es.*`). Новая
предметная область (HTTP-клиент, кеш) — это новый `Core.Otel.<Область>`, а не ещё несколько
клоуз в фасаде.

Правила словаря:

- имена атрибутов — константы модуля-словаря; на call site их нет;
- набор операций выражается **сигнатурами функций**, а не маппингом ключей:
  опечатка обязана быть ошибкой компиляции, а не `FunctionClauseError` в проде
  внутри поллера или подписчика;
- в moduledoc — снимок конвенций и их статус. Messaging-конвенции ещё
  `Development`, и спека прямо требует не менять версию молча: правка имён —
  осознанный переход на новый снимок;
- **собственные** атрибуты (номер попытки, DLQ-топик) кладутся в `core.*`,
  а не в зарезервированное `messaging.*`.

Instrumentation scope по умолчанию — `:core`. Код потребителя, зовущий фасад
напрямую, передаёт `scope: <свой модуль>`, иначе его span'ы в бэкенде выглядят
как span'ы библиотеки.

## Где ставить span

Контекст трейса живёт в **process dictionary** вызывающего. Из этого следует всё остальное:

- Span ставится на **call site**, а не внутри процесса, вызванного `GenServer.call`:
  у `Stream.Writer` свой pdict, и span внутри него оказался бы корнем нового трейса.
  Поэтому span отправки открывает `Delivery.Mq`, а не writer.
- Порождённому процессу контекст передаётся **явно**: `ctx = Core.Otel.ctx()` в
  вызывающем, `Core.Otel.with_ctx(ctx, fun)` внутри `Task` / `spawn`.
- Через асинхронный транспорт (строка в БД, сообщение брокера) контекст переносится
  заголовками: `Core.Otel.inject/1` на записи, `Core.Otel.with_span_from/4` на чтении.
  Схема цепочки outbox — `14-events-outbox.md`.
- `with_span_from/4` восстанавливает прежний контекст процесса в `after`. Процесс,
  обрабатывающий поток чужих сообщений (подписчик), MUST NOT уносить контекст одного
  сообщения в обработку следующего.

Span на периодический опрос (тик поллера, цикл cleaner'а) — **MUST NOT**: это шум,
в котором тонет трейс запроса. Трассируется работа, а не расписание.

Пачка проекции MUST идти в корневом span'е `Core.Otel.Es.project/3` только когда у неё есть
работа — старт с начала истории или события после чекпоинта; холостая и заблокированная пачки —
то же расписание, span'а у них нет. Родителя у span'а нет: пачка несёт события разных команд.

Проверяется: `test/core/es/projection_test.exs`, describe «span».

Ожидание проекции MUST идти в span'е `Core.Otel.Es.await/4` на call site — в процессе
вызывающего, дочерним span'у usecase, а не корневым: ожидание — часть запроса, и его длительность
видна в трейсе рядом с записью. Span открывает сам `Projection.await/3`,
`:projection_timeout` и `:projection_rebuilding` отмечаются `record_error/1`.

Проверяется: `test/core/es/projection/await_test.exs`, describe «span».

Команда процесса агрегата MUST идти в span'е `Core.Otel.Es.execute/4` на call site
`Agg.Process.execute` — в процессе вызывающего, дочерним span'у usecase, а не в процессе, который
исполняет команду: контекст трейса живёт в pdict вызывающего. Span открывает сам `execute`; режим
и число повторов — атрибуты, прикладная ошибка — `record_error/1`, доменный отказ статус span'а не
меняет. У восстановления агрегата (`get` / `get_decision` / `get_many` / `refresh`) span'а нет.

Проверяется: `test/core/es/aggregate/process_test.exs`, describe «span».

Контекст трейса в `es_events` MUST NOT храниться: хранилище вечное, baggage пропагатора лёг бы в
него навсегда, а пересборка ссылалась бы на истёкшие трейсы. Обработку события с командой
связывает `event_id` — атрибут `core.es.event.id` на отказе пачки.

```elixir
# плохо — контекст трейса команды в нагрузке события: переживёт трейс и уйдёт в пересборку
payload = %{"name" => name, "traceparent" => Otel.inject(%{})["traceparent"]}

# хорошо — событие без контекста трейса: связь с командой — его event_id
payload = %{"name" => name}
```

## Атрибуты

- Чувствительные данные в атрибутах — **MUST NOT** (тот же запрет, что для логов,
  `12-errors.md`): span уходит во внешний коллектор целиком.
- Ошибка отмечается `Core.Otel.record_error/1`: `error.type` = `ns/code`,
  `core.error.kind`, статус `:error` с `Error.format_chain/1`. Причину отдельным
  атрибутом не дублировать — она уже в сообщении статуса.
- Атрибут, значение которого неизвестно, **не ставится** вовсе: `nil` в атрибутах —
  это `nil` в бэкенде, а не отсутствие. Так же и с `messaging.system`: адаптер знает
  клиента, а не брокера за ним, поэтому система приходит опцией и дефолта не имеет.
- Ошибка наблюдаемости MUST NOT ронять работу: фасад тотален по значениям
  (невалидные атрибуты и ссылки отбрасывает сам `opentelemetry_api`), а span вне
  контекста — no-op, а не исключение.

## Логи

Формат сообщений и уровни не меняются от того, что появился трейс, — см.
«Логирование» в `20-agreements.md`. `trace_id` / `span_id` приходят из metadata
(`Core.Otel.LogFilter`), а не интерполируются в текст.

Фильтр регистрирует потребитель:

```elixir
:logger.add_primary_filter(:otel_trace, {&Core.Otel.LogFilter.filter/2, []})
config :logger, :default_formatter, metadata: [:request_id, :trace_id, :span_id]
```

Собственная metadata `opentelemetry_api` (`otel_trace_id`) для этого не годится:
она пишется при смене контекста и остаётся в процессе после закрытия span'а, а
фильтр читает контекст на момент записи.

## Baggage

Пропагаторы выбирает потребитель (`config :opentelemetry, text_map_propagators:`);
по умолчанию SDK ставит `[:trace_context, :baggage]`. Тогда вместе с трейсом в
строку outbox и в сообщение брокера уйдёт и baggage — со всем, что в него положили
выше по стеку. Если baggage не должен покидать процесс, потребитель сужает список
до `[:trace_context]`. Библиотека выбор не навязывает: `Core.Otel.inject/1` работает
через настроенный пропагатор, а не через захардкоженный `traceparent`.

## Тесты

- Экспортёр span'ов глобален: тест, вызывающий `Core.OtelFixture.attach/0`, —
  `async: false` (`19-testing.md`).
- Связность цепочки проверяется сквозным тестом (`test/core/otel_chain_test.exs`):
  один `trace_id` от изменяющего usecase до обработчика сообщения, без живого брокера.
- Утверждать MUST по родителю (`parent_span_id`) и ссылкам (`links`), а не только
  по совпадению `trace_id`: общий трейс проходит и там, где звено потеряло родителя.

## Рекомендованные алерты

Метрики подсистем отдают плагины `Core.*.PromEx`, имена — с префиксом PromEx
`my_app_prom_ex_<плагин>_` (`PromEx.metric_prefix/2`, если плагину не задан `metric_prefix:`).
Приложение, поднимающее подсистему, SHOULD заводить её алерты по таблице; `<порог>` и `for:`
выбирает само. Алерты проекций — `22-projections.md`, «Эксплуатация».

| Алерт | PromQL | Смысл |
|---|---|---|
| `OutboxQueueFailedGrowing` | `max(my_app_prom_ex_outbox_queue_count{status="failed"}) > 0`, `for: <порог>` | записи в `:failed` ждут оператора: `Cleaner` их не удаляет |
| `OutboxFailedDelivery` | `sum(increase(my_app_prom_ex_outbox_delivery_total{outcome="failed"}[5m])) > 0 or sum(my_app_prom_ex_outbox_delivery_total{outcome="failed"} unless last_over_time(my_app_prom_ex_outbox_delivery_total{outcome="failed"}[5m] offset 5m)) > 0` | запись исчерпала `max_attempts` и ушла в `:failed` |
| `OutboxOldestNewHigh` | `max(my_app_prom_ex_outbox_queue_oldest_age_seconds) > <порог>`, `for: <порог>` | очередь не разгребается: поллер не запущен, брокер недоступен или голова очереди раз за разом уходит в backoff |
| `OutboxExpiredLocks` | `max(my_app_prom_ex_outbox_queue_expired_locks_count) > 0`, `for: <порог>` | аренда `:in_work` истекла: поллер остановлен посреди пачки или цикл дольше `lock_duration` |
| `MqPublishErrors` | `sum by (topic) (increase(my_app_prom_ex_mq_publish_total{result!="ok"}[5m])) > 0 or sum by (topic) (my_app_prom_ex_mq_publish_total{result!="ok"} unless last_over_time(my_app_prom_ex_mq_publish_total{result!="ok"}[5m] offset 5m)) > 0` | публикация в RabbitMQ Stream отказала или не подтверждена брокером; у Kafka — то же условие по `my_app_prom_ex_mq_kafka_publish_total{result="error"}` |
| `MqDecodeDrops` | `sum by (topic) (increase(my_app_prom_ex_mq_decode_drop_total[5m])) > 0 or sum by (topic) (my_app_prom_ex_mq_decode_drop_total unless last_over_time(my_app_prom_ex_mq_decode_drop_total[5m] offset 5m)) > 0` | reader пропустил запись без обработки: конверт не разобран, в конверте чужой топик или чанк с sub-entry batching |
| `MqSubscriberDlq` | `sum by (topic, dlq_topic) (increase(my_app_prom_ex_mq_subscriber_dlq_total[5m])) > 0 or sum by (topic, dlq_topic) (my_app_prom_ex_mq_subscriber_dlq_total unless last_over_time(my_app_prom_ex_mq_subscriber_dlq_total[5m] offset 5m)) > 0` | подписчик отправил «ядовитое» сообщение в DLQ (`14-events-outbox.md`, «Runbook: сообщения в DLQ») |
| `WorkerDown` | `my_app_prom_ex_workers_up == 0`, `for: <порог>` | процесса из `watch:` нет на ноде |
| `WorkerMailboxHigh` | `my_app_prom_ex_workers_message_queue_len > <порог>`, `for: <порог>` | mailbox процесса растёт быстрее, чем он обрабатывает сообщения (`17-otp-concurrency.md`, «Mailbox и backpressure») |
| `CacheUnavailable` | `sum by (cache) (increase(my_app_prom_ex_cache_requests_total{result="cache_error"}[5m])) > 0 or sum by (cache) (my_app_prom_ex_cache_requests_total{result="cache_error"} unless last_over_time(my_app_prom_ex_cache_requests_total{result="cache_error"}[5m] offset 5m)) > 0` | процесс кеша недоступен, чтение идёт мимо кеша в store |
| `CacheStoreErrors` | `sum by (cache) (increase(my_app_prom_ex_cache_requests_total{result="store_error"}[5m])) > 0 or sum by (cache) (my_app_prom_ex_cache_requests_total{result="store_error"} unless last_over_time(my_app_prom_ex_cache_requests_total{result="store_error"}[5m] offset 5m)) > 0` | отказывает store за кешем, а не кеш: сброс кеша не поможет |
| `PromExCollectFailing` | `sum by (instance, collector) (increase({__name__=~"my_app_prom_ex_.+_collect_errors_total"}[5m])) > 0`, `for: <порог>` | сбор polling-группы `collector` отказывает (`Core.PromEx.Safe`): её gauge'и застыли на последнем значении, и алерты на них недостоверны |
| `EsKeyReservationUnresolved` | `sum by (scope) (increase(my_app_prom_ex_es_key_reservation_total{result="unresolved"}[5m])) > 0 or sum by (scope) (my_app_prom_ex_es_key_reservation_total{result="unresolved"} unless last_over_time(my_app_prom_ex_es_key_reservation_total{result="unresolved"}[5m] offset 5m)) > 0` | резерв ключа области `scope` не разрешился после повтора (`:reservation_unresolved`): конкурентная запись в области сверх ожидаемой (`13-repos.md`, «Резервы ключей») |

- Условие MUST брать имя метрики с префиксом PromEx: серии без префикса не существует, и алерт
  на неё молчит всегда, не выдавая ошибки.
- Gauge очереди outbox (`queue_count`, `queue_oldest_age_seconds`, `queue_expired_locks_count`)
  каждая нода считает по одной таблице: агрегировать SHOULD через `max`, а не `sum` — сумма
  умножила бы значение на число нод.
- `WorkerDown` верен, только пока в `watch:` нет элементов выключенного поддерева
  (`17-otp-concurrency.md`, «Дерево процессов»).
- `PromExCollectFailing` SHOULD нести `for:`: единичный отказ опроса (таймаут пула на пике)
  gauge'и не портит — следующий цикл их обновит; недостоверны они, только пока сбор отказывает
  подряд.
- `EsKeyReservationUnresolved`: засеять серию нулём некому — у резервов нет процесса-владельца.
  Отказ `:taken` — доменный исход, алерта на него нет.

```yaml
# плохо — имя без префикса PromEx: такой серии нет, алерт не сработает никогда
- alert: OutboxQueueFailedGrowing
  expr: outbox_queue_count{status="failed"} > 0

# хорошо
- alert: OutboxQueueFailedGrowing
  expr: max(my_app_prom_ex_outbox_queue_count{status="failed"}) > 0
  for: 10m
```

### Первое событие серии счётчика

Серия `counter` у `telemetry_metrics_prometheus_core` появляется после первого события сразу со
значением 1, и `increase(x[w]) > 0` этот инкремент не видит: прироста в окне нет. Условие алерта на
единичное событие по незасеянному счётчику MUST нести правую ветку — серию, которая есть сейчас и
у которой не было точек окно назад (ADR-0029). В таблице это все строки на `increase(...) > 0` без
`for:`.

```text
sum by (<метки>) (increase(x{<фильтр>}[w])) > 0
  or sum by (<метки>) (x{<фильтр>} unless last_over_time(x{<фильтр>}[w] offset w)) > 0
```

- `offset` и диапазон `last_over_time` MUST равняться окну `increase`: при меньшем `offset` серия,
  появившаяся раньше него, но внутри окна, выпадает из обеих веток; при меньшем диапазоне ложное
  срабатывание даёт уже разрыв скрейпа длиннее диапазона.
- `x offset w` вместо `last_over_time` — MUST NOT: единичный пропуск скрейпа оставляет staleness
  marker, и через окно правая ветка поднимает алерт по каждой ненулевой серии цели.
- Фильтр по меткам MUST повторяться в каждом `x`: без него правая ветка подняла бы алерт на новую
  серию чужого исхода (`result="ok"`).
- Значение правой ветки — полный счёт серии с запуска ноды, а не прирост за окно.
- Цена — ложное срабатывание, когда скрейп цели не проходил дольше окна: серия вернулась со старым
  значением, и правая ветка видит её новой. Проверка `up` в условии MUST NOT: после простоя ноды
  дольше окна она снова прячет первое событие.
- `EsProjectionRetrying` (`22-projections.md`) и `PromExCollectFailing` правой ветки не несут: у
  них `for:`, а отказ повторяется каждый цикл, пока длится, — второй инкремент рост видит.

```yaml
# плохо — серия появилась сразу с 1: прироста в окне нет, первое сообщение в DLQ молчит
- alert: MqSubscriberDlq
  expr: sum by (topic, dlq_topic) (increase(my_app_prom_ex_mq_subscriber_dlq_total[5m])) > 0

# хорошо
- alert: MqSubscriberDlq
  expr: >
    sum by (topic, dlq_topic) (increase(my_app_prom_ex_mq_subscriber_dlq_total[5m])) > 0
    or sum by (topic, dlq_topic) (my_app_prom_ex_mq_subscriber_dlq_total
      unless last_over_time(my_app_prom_ex_mq_subscriber_dlq_total[5m] offset 5m)) > 0
```

Новый счётчик под алерт на единичное событие с закрытым множеством меток SHOULD объявляться `sum`
по measurement `count` и засеваться `count: 0` по каждому значению меток при старте
процесса-владельца: серия существует до первого события, и условию в таблице хватает
`increase(x[w]) > 0`. Засевает владелец, а не плагин PromEx: метрики плагина подключаются к
telemetry после его сборки. `counter` прибавил бы 1 на событие засева; `sum` экспортируется в
Prometheus с типом `counter`, имя серии не меняется. Так засеяны
`es_projection_signal_{sent,received}_total` (`Core.Es.Projection.Listener`, ADR-0028).

```elixir
# плохо — `counter` прибавляет 1 на событие: засев `count: 0` дал бы серию с 1
counter(
  prefix ++ [:sync, :failed, :total],
  event_name: Telemetry.event([:sync, :failed]),
  tags: [:reason]
)

# хорошо — плагин считает `sum` по `count`
sum(
  prefix ++ [:sync, :failed, :total],
  event_name: Telemetry.event([:sync, :failed]),
  measurement: :count,
  tags: [:reason]
)

# хорошо — процесс-владелец засевает каждое значение закрытой метки при старте,
# отказ эмитит с `%{count: 1}`
@impl true
def handle_continue(:seed, state) do
  for reason <- ~w(timeout rejected)a,
      do: :telemetry.execute(Telemetry.event([:sync, :failed]), %{count: 0}, %{reason: reason})

  {:noreply, state}
end
```

Тест `MqSubscriberDlq` на `promtool test rules` (правило «хорошо» в `alerts.yml`): серия `orders`
появляется сразу с 1 — алерт; `users` стоит на 1 с начала — тишина; `bills` растёт — алерт;
`audit` пропустила один скрейп — тишина.

```yaml
rule_files: [alerts.yml]
tests:
  - interval: 1m
    input_series:
      - series: 'my_app_prom_ex_mq_subscriber_dlq_total{topic="orders", dlq_topic="orders.dlq"}'
        values: '_x5 1x20'
      - series: 'my_app_prom_ex_mq_subscriber_dlq_total{topic="users", dlq_topic="users.dlq"}'
        values: '1x25'
      - series: 'my_app_prom_ex_mq_subscriber_dlq_total{topic="bills", dlq_topic="bills.dlq"}'
        values: '1+1x25'
      - series: 'my_app_prom_ex_mq_subscriber_dlq_total{topic="audit", dlq_topic="audit.dlq"}'
        values: '1x2 stale 1x21'
    alert_rule_test:
      - eval_time: 8m
        alertname: MqSubscriberDlq
        exp_alerts:
          - exp_labels: {topic: orders, dlq_topic: orders.dlq}
          - exp_labels: {topic: bills, dlq_topic: bills.dlq}
```

## Связанные правила

- Цепочка outbox и её спаны — `14-events-outbox.md`
- Границы библиотеки и конфигурация — `10-architecture.md`
- Уровни и формат логов — `20-agreements.md`
- Тесты — `19-testing.md`
- Алерты проекций — `22-projections.md`
- Разбор записей `:failed` по алертам очереди — `deps/core/docs/rules/app/14-events-outbox.md`
