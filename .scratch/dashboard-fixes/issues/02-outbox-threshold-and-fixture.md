# 02: Порог outbox и провайдер фикстуры

**What to build:** критический порог панели «Oldest new age» на графике outbox берётся из
`outbox_oldest_age_critical` в `dashboard_assigns/0`, как у stat-панели: при нестандартном пороге
график и stat показывают одно значение. Фикстура MQ перестаёт ссылаться на несуществующий
`readers/0` — общий провайдер `Core.PromExFixture.readers/0` используют `MqStream`, `MqKafka` и
`MqReaders`, сбор метрик с фикстурой не падает. Спека: `.scratch/dashboard-fixes/spec.md`.

**Blocked by:** 01 — только из-за общего файла тестов дашбордов; логической зависимости нет.

**Status:** resolved

- [x] Критический порог графика «Oldest new age» — `outbox_oldest_age_critical`; шаг warning на график не добавлен
- [x] Тест с нестандартным `outbox_oldest_age_critical` подтверждает совпадение графика и stat
- [x] Провайдер `{Core.PromExFixture, :readers, []}` у `MqStream`, `MqKafka` и `MqReaders`; вложенных `readers/0` и `:missing_reader` нет
- [x] CHANGELOG не трогаем: существующий пункт уже говорит, что пороги берутся из `dashboard_assigns/0`
- [x] `make` зелёный
