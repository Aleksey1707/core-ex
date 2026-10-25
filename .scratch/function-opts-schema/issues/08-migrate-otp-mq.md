# 08: Перевод OTP на схему — брокеры

**What to build:** читатели и писатели брокеров проверяют опции старта схемой над `init/1`;
опечатка в дереве супервизии — `ArgumentError` в `init/1` с именем ключа, а не молчаливый backoff,
неотличимый от недоступного брокера.

Спека — «Объём перевода», волна 2.

**Blocked by:** 07

**Status:** resolved

- [x] Схема над `init/1` у `Mq.Stream.Reader`, `Mq.Stream.Writer`, `Mq.Kafka.Reader`,
      `Mq.Dlq.Reader`, `Mq.Dlq.Writer`; вызовы `StartOpts` убраны; `child_spec` / `start_link` без
      схемы; опции в `@moduledoc` из схемы.
- [x] `Mq.Client.ensure_available!` переведён на схему.
- [x] После правки `lib/core/mq/**` — `make compile-no-optional` зелёный.
- [x] Тесты старта с неверными опциями зелёные (тексты обновлены); тесты под тегами
      `:rabbit_stream` / `:kafka` не ломаются.
- [x] CHANGELOG: функции, где неизвестный ключ раньше проходил, добавлены в список «Ломающих».
- [x] `make` зелёный.

## Comments

- Схема над `init/1` у пяти процессов — по шаблону `Outbox.Cleaner`: `@init_opts_schema` выше
  `@moduledoc` (полные имена модулей), раздел «Опции старта» через `Core.Options.docs/1`, в теле —
  `Keyword.fetch!/2`. Атрибуты умолчаний (`@retry_min_ms`, `@prefetch_count`, …) и `@label` / `@keys`
  удалены: умолчание живёт в схеме. `@shutdown_ms` остаётся выше схемы — его читают и схема
  (умолчание для описания), и `child_spec/1`.
- `child_spec/1` у `Kafka.Reader` и `Dlq.Reader` — без `StartOpts`: `Keyword.get/2`, как у
  `Cleaner`; `shutdown:` не той формы отклоняет супервизор, имя — `GenServer.start_link/3`, оба
  ключа ещё раз проверяет схема `init/1`. В CHANGELOG не вынесено (прецедент 07).
- `initial_offset:` у `Stream.Reader` — встроенный `{:or, [{:in, …}, {:tuple, [{:in, [:offset]},
  :non_neg_integer]}]}` вместо ручной клаузы; у `Kafka.Reader` — `{:in, …}`. Обоим — `type_doc:`:
  для `:in` / `:or` NimbleOptions тип в описании не выводит.
- Custom-валидаторы `StartOpts.atom/1` (атом, кроме `nil`) и `StartOpts.binary/1` (непустая
  строка) — те же, что завёл тикет 09 (при слиянии взята его версия). Встроенные `:atom` / `:string` ослабили бы прежние
  `atom!` / `binary!`: `client: nil` у `Kafka.Reader` ушёл бы в backoff `:brod`, а пустой
  `reference_prefix:` у `Stream.Writer` дал бы двум writer'ам общий producer reference. Применены к
  `Kafka.Reader` `client:`, `Stream.Writer` `reference_prefix:`, `Mq.Client` `label:` / `dep:` /
  `requirement:`.
- `Mq.Client.ensure_available!/1` — обычная функция со схемой (`@opts_schema` между `@doc` и
  `@spec`); проза о составе опций из `@doc` убрана, раздел «Опции» собирается из схемы.
- CHANGELOG: в список «Ломающих» — `Stream.Reader`, `Stream.Writer`, `Kafka.Reader` и
  `Mq.Client.ensure_available!/1` (неизвестный ключ раньше проходил). `Dlq.Reader` / `Dlq.Writer`
  неизвестный ключ отклоняли и раньше (`keys!`) — сменился только текст, в CHANGELOG не попали.
- `@spec init` — `{:ok, %__MODULE__{}}` (и `{:continue, _}`): `t()` у этих модулей —
  `GenServer.server()`, а не состояние.
