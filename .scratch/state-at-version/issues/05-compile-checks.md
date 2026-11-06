# 05: Проверки сборки read-репозитория по версии

**What to build:** ошибка объявления read-модели по версии ловится при сборке, а не в рантайме:
`use Core.Es.Aggregate.ReadRepo` и `use Core.Es.Aggregate.ReadRepo.Pg` отказывают `CompileError` с понятным
текстом на каждую неверную опцию. В первую очередь — `repo:` state-stored агрегата: его поток не
воспроизводит строку, и свёртка до версии дала бы неверное состояние. Спека
`.scratch/state-at-version/spec.md`, ADR-0094.

**Blocked by:** 02 (`get_at` над write-репозиторием без снапшотов).

**Status:** ready-for-agent

- [ ] `CompileError`: `repo:` — не behaviour write-репозитория event-sourced агрегата (`use Core.Es.Aggregate.Repo`), в том числе state-stored репозиторий с `event_codec:`.
- [ ] `CompileError`: `view:` — не `use Core.View`.
- [ ] `CompileError`: `behaviour:` — не `use Core.Es.Aggregate.ReadRepo`.
- [ ] `CompileError`: `to_view:` — не захват функции арности 1.
- [ ] `CompileError`: неизвестные и недостающие обязательные опции у обоих макросов (через `Helper.Opts`, как у write-репозитория).
- [ ] Каждая причина — тест в блоке «компиляция» по образцу тестов write-репозитория event-sourced агрегата.
- [ ] Раздел «Состояние на версии» в `13-repos.md` перечисляет проверки сборки («Проверяется: …»).
- [ ] `make` зелёный.
