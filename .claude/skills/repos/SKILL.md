---
name: repos
description: "Свод правил репозиториев библиотеки Core: write-путь (use Core.Repo.Pg и Repo.Pg.StateStored с event_codec:, children, constraint_errors, Repo.Sc), write event-sourced агрегата (use Core.Es.Aggregate.Repo и Core.Es.Aggregate.Repo.Pg: get / get_many / append / refresh, один репозиторий в common-слое, снапшоты snapshot: с маркером и version:), процесс агрегата (use Core.Es.Aggregate.Process: Agg.Process.execute одной транзакцией с колбэком и повтором после :version_mismatch, enabled: false, команда на несколько агрегатов — usecase → repo), read-путь (ReadRepo, View через Core.View, to_view, jsonb-Redump), Repo.Pg.Schema с to_entity/to_model, Specs, хранилище событий (Core.Es.Store, es_events, страница потока page_stream), структура путей и алиасов, safe против bang на call site. Использовать при заведении или правке репозитория, Ecto-схемы, Specs, View и read-модели."
---

# 13-repos.md

Прочитай `docs/rules/13-repos.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
