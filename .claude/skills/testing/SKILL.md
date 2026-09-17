---
name: testing
description: "Свод правил тестов библиотеки Core: выбор case-модуля (ExUnit.Case, Core.DataCase, Core.Es.EventCompatCase, Core.Es.ProjectionCase), async, round-trip кодеков и property-based, контракт jsonb на read-пути, golden-фикстуры событий и use Core.Es.EventCompatCase (event_codec: / aggregate:), тесты event-sourced агрегата без БД (Core.Es.Aggregate.Test.given, then в короткой форме), тесты проекций (запись через репозиторий → Core.Es.Projection.Test.run_until_idle → ReadRepo на Core.DataCase async: false, прямой project/1, await: :inline тестового дерева), тесты usecase с процессом агрегата на enabled: false, тесты Enum и constraint_errors, контрактные тесты behaviour, negative-тесты ACL, работа со временем, Oban, процессы, чувствительные данные, внешние зависимости под тегом. Использовать при написании или правке тестов в test/**, заведении golden-фикстуры события или тест-модуля совместимости событий агрегата, тестов решений event-sourced агрегата и тестов проекций."
---

# 19-testing.md

Прочитай `docs/rules/19-testing.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
