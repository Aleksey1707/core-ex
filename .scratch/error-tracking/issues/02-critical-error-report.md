# 02: Отчёт о критической ошибке в службу учёта ошибок

**What to build:** потребитель с Sentry записывает критическую ошибку одним вызовом библиотеки
`Core.Web.CriticalError.report(reason, stacktrace)` и получает идентификатор ошибки — `event_id`
события этого же вызова — либо `nil`, если записи нет (пустой DSN, событие отброшено SDK). Событие
уходит асинхронно, запрос службу не ждёт. Форма события зависит от причины: исключение — событие
исключения со stacktrace; `%Error{}` — сообщение «Прикладная ошибка API: <текст>», fingerprint
`"<ns>/<code>"`, `inspect/1` ошибки в доп. данных; прочий term — сообщение «Необработанная ошибка
API» с `inspect/1` причины. `:sentry` — optional-зависимость: потребитель без неё собирает
библиотеку как раньше. Спека: `.scratch/error-tracking/spec.md`; решение: ADR-0071.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `:sentry ~> 14.0`, `optional: true`; модуль под `if Code.ensure_loaded?(Sentry)`
- [x] идентификатор — `event_id` события этого вызова; `Sentry.get_last_event_id_and_source/0` не используется
- [x] отправка асинхронная (`result: :none`)
- [x] тесты на `Sentry.Test` без заглушек: исключение со stacktrace; `%Error{}` с fingerprint `ns/code`; прочий term; возвращённый id равен `event_id` пойманного события; без DSN и при отброшенном событии — `nil`
- [x] значение Prim с `sensitive: true` в доп. данных события скрыто
- [x] тестовый режим SDK — `async: false` с уборкой глобального состояния (`docs/rules/19-testing.md`) — вышло `async: true`, см. «Комментарии»
- [x] `make compile-no-optional` зелёный: без `:sentry` модуль не собирается, остальное собирается
- [x] `docs/rules/10-architecture.md`: `:sentry` среди optional-зависимостей
- [x] `docs/rules/21-observability.md`: отчёт о критической ошибке — что пишет, когда звать, optional-сборка
- [x] CHANGELOG, «Новое»: модуль отчёта и требование `:sentry ~> 14.0` (потребителю на 13.x — поднять SDK)
- [x] проверить и записать в «Комментарии»: совпадает ли id в службе с локальным `event_id`; заполняется ли `contexts.trace` из OTel-спана
- [x] `make` зелёный

## Комментарии

- **id в службе и локальный `event_id`.** Синхронно (`result: :sync`) SDK возвращает id из ответа
  службы, при `result: :none` и `capture_exception/2`, и `capture_message/2` отдают `{:ok, ""}` —
  взять идентификатор из ответа нельзя. Поэтому `report/2` собирает событие сам
  (`Sentry.Event.transform_exception/2` / `create_event/1`, id — `UUID.uuid4_hex/0` SDK) и отправляет
  `Sentry.send_event/2`; возвращается `event.event_id`. Тот же id SDK пишет в заголовок конверта и в
  payload (`Sentry.Envelope.from_event/1`) — проверено тестом «в службу уходит событие с тем же
  идентификатором»: конверт, принятый HTTP-приёмником `Sentry.Test`, несёт `event_id`, равный
  возвращённому. Что служба показывает и ищет запись по этому же id — по протоколу Sentry
  (`event_id` задаёт клиент), но без живой службы **не проверено**.
- **Цена `send_event/2`:** мимо `capture_exception/2` не работает `:filter` SDK
  (`exclude_exception?/2`) — критическую ошибку зовут явно; `before_send`, `sample_rate` и
  дедупликация работают, их отказ даёт `nil`. Отказ после постановки в очередь (лимит частоты
  службы — `{:rate_limited, _}` у `TelemetryProcessor`, сетевой сбой) SDK при `result: :none` не
  возвращает: id уже выдан, записи может не быть — оговорено в `@doc` и своде.
- **`contexts.trace`.** SDK заполняет его сам из текущего OTel-спана (`Sentry.Event.create_event/1` →
  `Sentry.OpenTelemetry.TraceContext.current/0`, `:otel_tracer.current_span_ctx/0` — тот же контекст,
  что у `Core.Otel`). Но `TraceContext` компилируется, только если при сборке `:sentry` загружены все
  четыре: `opentelemetry` ≥ 1.5, `opentelemetry_api` ≥ 1.4, `opentelemetry_exporter` ≥ 1.0,
  `opentelemetry_semantic_conventions` ≥ 1.27 (`Sentry.OpenTelemetry.VersionChecker`). Проверено на
  отдельном проекте: со всеми четырьмя внутри `with_span` — `contexts.trace` с `trace_id`/`span_id`
  спана, без спана — нет; без `opentelemetry_semantic_conventions` — нет никогда. В сборке самой
  библиотеки (нет экспортёра и semconv) не заполняется — тестом библиотеки не закрыто. Для тикета 03:
  норма потребителя должна требовать эти четыре приложения (или класть `trace_id` тегом сама).
  Отображение в живой службе не проверено.
- **`async: true` вместо `async: false`.** Тестовый режим SDK 14 (`config :sentry, test_mode: true`)
  держит конфигурацию (`Sentry.Test.Config`) и пойманные события на тест и убирает их сам; общая на VM
  только таблица дедупликации — тест выключает её своей конфигурацией (`dedup_events: false`). Причины
  для `async: false` из `19-testing.md` нет; норма записана в `21-observability.md`, «Тесты».
- **`bypass` — тестовая зависимость.** `Sentry.Test.setup_sentry/1` без него не работает: HTTP-приёмник
  конверта — Bypass. Тянет `plug_cowboy`/`cowboy` только в `:test`.
- **Finch.** HTTP-клиент SDK 14 по умолчанию — `Sentry.FinchClient`, без `:finch` приложение `:sentry`
  не стартует; у потребителя `:finch` есть транзитивно через `prom_ex`.
