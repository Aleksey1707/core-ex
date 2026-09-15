---
name: projections
description: "Свод правил проекций библиотеки Core: объявление use Core.Es.Projection (name:, events: — модули событий, а не семейство, кодек <Aggregate>.Event.Codec, version:), обязательные project/1 без catch-all и clear/0 по всем таблицам (проверяет use Core.Es.ProjectionCase), пропуск необъявленного тега, пачка run_once с чекпоинтом es_checkpoints в одной транзакции, read-модель без внешних эффектов, одна проекция на таблицу, ReadRepo над таблицами нескольких проекций, read-модель в базе es_events, дерево Core.Es.Projection.Supervisor (один на все проекции, опции из env ES_PROJECTIONS_*), read-after-write Core.Es.Projection.await (после commit вне Transact.run, :projection_timeout / :projection_rebuilding без повтора команды, await: :inline тестового дерева), пересборка подъёмом version: (когда поднимать, :outdated у старого кода, расширяющая миграция таблиц), новая проекция тремя выкладками, удаление проекции (Core.Es.Migration.delete_checkpoint, имя не переиспользуется), эксплуатация — рекомендованные алерты EsProjectionRetrying / EsProjectionLagging (при rebuilding == 0) / EsProjectionRebuildLong / EsProjectionOutdated на метриках Core.Es.PromEx и сигналы без алертов. Использовать при заведении или правке проекции, её read-модели и таблиц, при постановке дерева проекций в приложение, при ожидании проекции после записи, при подъёме version: и удалении проекции, при выборе между проекцией и подписчиком брокера, при настройке алертов проекций."
---

# 22-projections.md

Прочитай `docs/rules/22-projections.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
