---
name: testing
description: "Свод правил тестов библиотеки Core: выбор case-модуля (ExUnit.Case, DataCase приложения / Core.DataCase, Core.Es.EventCompatCase, Core.Es.ProjectionCase), причины async: false и уборка после них (глобальное состояние — on_exit, общий sandbox, гонка транзакций мимо sandbox через unboxed_run), доменные фикстуры и тест репозитория через behaviour, round-trip кодеков и property-based, контракт jsonb на read-пути, golden-фикстуры событий и use Core.Es.EventCompatCase (event_codec: / aggregate:), тесты event-sourced агрегата без БД (Core.Es.Aggregate.Test.given на draft, then в короткой форме), уникальное значение ключа резерва в async-тестах, записанные события Core.Es.Store.Test.events!, тесты проекций (запись через репозиторий → Core.Es.Projection.Test.run_until_idle → ReadRepo на DataCase async: false, прямой project/1, обязательный await: :inline тестового дерева), тесты usecase с процессом агрегата на enabled: false, коды Enum и сверка constraint_errors, контрактные тесты behaviour, negative-тесты ACL, работа со временем, процессы и shared mode sandbox, чувствительные данные, внешние зависимости под тегом. Использовать при написании или правке тестов в test/**, заведении golden-фикстуры события или тест-модуля совместимости событий агрегата, тестов решений event-sourced агрегата, тестов проекций и тестов гонки транзакций."
---

# 19-testing.md

Прочитай `docs/rules/19-testing.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
