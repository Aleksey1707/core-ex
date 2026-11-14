# 03: `metrics/0` и контракт читателя

**What to build:** читатель объявляет метрики необязательным колбэком `metrics/0`, а плагин метрик
предпочитает его и перестаёт знать адаптеры по именам; `info/1` у существующих читателей сохраняется
как запасной путь. DLQ-читатель получает метрики. Появляется общий контрактный набор тестов читателя по
образцу writer'а. Имена gauges не меняются. Спека — `.scratch/mq-lease-reader/spec.md`.

**Blocked by:** C2 (`02-reader-poll`).

**Status:** resolved

- [ ] `metrics/0` объявлен необязательным колбэком контракта чтения; свой читатель без него компилируется и работает.
- [ ] Плагин метрик зовёт `metrics/0`, если модуль его экспортирует, иначе `info/1`; отсутствие обоих не роняет сбор метрик.
- [ ] DLQ-читатель отдаёт метрики; имена существующих gauges Kafka и stream не изменились.
- [ ] Контрактный набор читателя проверяет: без `commit` то же сообщение, `commit` двигает позицию, заявка на готовность приходит один раз, `metrics/0` возвращает нужную форму.
- [ ] DLQ-читатель гоняется в обычном прогоне, stream и Kafka — под тегами брокеров.
- [ ] `make`, `make test-stream`, `make test-kafka` зелёные.
- [ ] CHANGELOG, «Новое»: необязательный `metrics/0` и метрики DLQ-читателя.

## Comments

Resolved in `aa4f5ea` and review fixes `e93c502`. The optional callback is
`metrics/1` (reader handle) per explicit user decision, not `metrics/0`; PromEx prefers it over
`info/1`, resolves the reader module from `module:` or the live process, and skips a reader with
neither. DLQ reader exposes `%{topic, pending}`; the new `dlq_readers:` group emits
`mq_dlq_reader_pending{component, topic}` (existing stream/Kafka gauge names untouched).
`Core.MqReaderContract` runs on DLQ in the normal suite, on stream/Kafka under `:rabbit_stream`
and `:kafka`, and on both `MqFake` readers. `make`, `make test-stream`, `make test-kafka` green.
