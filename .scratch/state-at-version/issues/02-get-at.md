# 02: `get_at` над write-репозиторием без снапшотов

**What to build:** потребитель объявляет read-модель по назначению над event-sourced агрегатом парой
`use Core.Es.Aggregate.ReadRepo` (`repo:` — behaviour write-репозитория, `view:` — `Core.View`) и
`use Core.Es.Aggregate.ReadRepo.Pg` (`behaviour:`, `to_view:` — захват `%Agg{} → %View{}`) и читает по адресу
версии представление: `get_at(%Agg.ID{}, %Version{}, %Context{}, opts \\ [])` → `{:ok, %View{}}`. Состояние на
версии сворачивается внутренней функцией write-репозитория (`@doc false`) поверх пути из 01 с границей `N` и
без записи снапшотов; в код потребителя оно попадает только аргументом `to_view`. Спека
`.scratch/state-at-version/spec.md`, ADR-0094.

**Blocked by:** 01 (Верхняя граница потока в загрузке write-репозитория).

**Status:** ready-for-agent

- [ ] Behaviour объявляет колбэки `get_at/3,4`, результат сужен до `{:ok, %View{}} | {:error, %Error{}}`; реализация резолвит write-репозиторий `<Behaviour>.Pg` по конвенции DI и берёт у него агрегат, кодек и каталог ошибок; функции `defoverridable`.
- [ ] `get_at` на версии 1, промежуточной и голове отдаёт View состояния, свёрнутого до этой версии включительно.
- [ ] Версия за головой потока и пустой поток — `errors.domain(behaviour write-репозитория, :version_mismatch, %{aggregate_id, expected, actual, source: :address})`, `actual` пустого — `nil`; `Es.Transact` этот отказ не повторяет.
- [ ] `:current` вместо `%Version{}` — `FunctionClauseError`.
- [ ] Уничтоженное ПДн-значение после уничтожения ключа субъекта остаётся уничтоженным в состоянии на любой версии.
- [ ] Чтение вне транзакции; `opts` — опции запроса; снапшоты не пишутся.
- [ ] Telemetry `[:es, :aggregate, :load]` и `[:es, :aggregate, :fold]` с `op: :get_at`.
- [ ] Фикстура read-модели по назначению над `Core.EsFixture.Account` (свой View и `to_view`) и контрактный набор `get_at` (по образцу `Core.EsAggregateRepoContract`, `Core.DataCase`) на обычном `Account.Repo.Pg`.
- [ ] `docs/rules/13-repos.md` — раздел «Состояние на версии»: объявление пары, таблица исходов `get_at`, MUST NOT кешировать состояние на версии (с причиной — уничтожение ключа субъекта), MUST NOT звать внутри `Es.Transact.run` / `Transact.run`, наружу — только View, SHOULD имя `<Aggregate>.<Purpose>.ReadRepo` / `.View` в каталоге агрегата, доступ — читающим usecase до чтения, `:not_found` нет; ссылка из `app/13-repos.md` («Read-модель») и значение `op` в `21-observability.md`; `make rules-check` зелёный.
- [ ] CHANGELOG, «Новое»: пара модулей, `get_at`, `source: :address` в detail `:version_mismatch`, как заменить копию агрегата адресом версии (было → стало).
- [ ] `make` зелёный, `make compile-no-optional` зелёный.
