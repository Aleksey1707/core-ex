---
name: repos
description: "Свод правил репозиториев библиотеки Core: write-путь (use Core.Repo.Pg и Repo.Pg.Es, children, constraint_errors, Repo.Sc), read-путь (ReadRepo, View через Core.View, to_view, jsonb-Redump), Repo.Pg.Schema с to_entity/to_model, Specs, event store, структура путей и алиасов, safe против bang на call site. Использовать при заведении или правке репозитория, Ecto-схемы, Specs, View и read-модели."
---

# 13-repos.md

Прочитай `docs/rules/13-repos.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
