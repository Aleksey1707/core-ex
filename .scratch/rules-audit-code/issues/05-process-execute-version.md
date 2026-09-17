# 05: `Agg.Process.execute` отдаёт версию

**Status:** needs-triage

**What to build:** `<Aggregate>.Process.execute` возвращает `{:ok, Version.t()}` (версия состояния после
commit) вместо `:ok`. Ломающее изменение.

**Why:** `app/10-architecture.md`, «Usecases» требует версию в результате команды для ответа 202
(`app/15-web-api.md`, «Ожидание проекции»); `Execution` отбрасывает состояние после commit. Из-за этого
приложение не пользуется процессом агрегата и пишет свою обёртку над `Transact.run`.

- [ ] код, `13-repos.md` «Процесс агрегата», `app/10` «Usecases», примеры в `22-projections.md`, маркеры
      `fixtures/consumer`; CHANGELOG «Ломающие изменения контракта»
