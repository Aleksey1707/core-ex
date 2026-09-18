---
name: repos
description: "Свод правил репозиториев библиотеки Core: write-путь (use Core.Repo.Pg и Repo.Pg.StateStored с event_codec:, children, constraint_errors и составной unique-индекс, Repo.Sc, ArgumentError на изменение состояния без события при эталоне), write event-sourced агрегата (use Core.Es.Aggregate.Repo и Core.Es.Aggregate.Repo.Pg: get / get_many / append / refresh / page_stream, один репозиторий в common-слое, снапшоты snapshot: с маркером и version:, резервы изменяемых уникальных ключей key_reservations: — use Core.Es.KeyReservation, reservation/1 и to_key/1, порядок события → резервы → outbox, отказ code:, find/2, es_key_reservations), транзакция команды (Core.Es.Transact.run/2 и run_counted/2: повтор по источнику отказа записи source: :storage против :expected, запрет своей обёртки повтора), процесс агрегата (use Core.Es.Aggregate.Process: Agg.Process.execute одной транзакцией с колбэком и повтором после отказа записи, enabled: false, команда на несколько агрегатов — usecase → repo), read-путь (ReadRepo, View через Core.View, to_view, jsonb-Redump), Repo.Pg.Schema с to_entity/to_model, Specs, хранилище событий (Core.Es.Store, es_events и аддитивные изменения её схемы, страница потока @repo.page_stream/4 у репозитория агрегата любого вида, ID другого агрегата проверяет сборка, права до чтения), DI через Core.Config.repo!/1 (конвенция <Behaviour>.Pg, литерал модуля, ключ только на подмену), safe против bang на call site; раскладка файлов у потребителя — в deps/core/docs/rules/app/13-repos.md. Использовать при заведении или правке репозитория, Ecto-схемы, Specs, View и read-модели."
---

# 13-repos.md

Прочитай `docs/rules/13-repos.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
