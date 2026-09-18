# Тесты

- **Область.** `test/**` библиотеки; у потребителя — его case-модули, фикстуры и тесты.
- **Читать перед.** Новым тестом или case-модулем; тестом кодека, репозитория, агрегата,
  процесса, Enum или события; правкой тестовой обвязки в `test/support`.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Case-модули

| Case | Когда |
|---|---|
| `ExUnit.Case` | чистые модули: Prim, Enum, Codec, хелперы |
| `MyApp.DataCase` (в самой библиотеке — `Core.DataCase`) | всё, что ходит в Postgres (Ecto Sandbox) |
| `Core.Es.EventCompatCase` | golden-фикстуры событий, один тест-модуль на агрегат (см. «Совместимость событий») |
| `Core.Es.ProjectionCase` | очистка `clear/0` проекции на golden-фикстурах, один тест-модуль на проекцию (см. «Проекции») |
| `Core.Repo.ConstraintErrorsCase` | сверка `constraint_errors` с `changeset/2` и БД, один тест-модуль на приложение (см. «`constraint_errors`») |
| `Core.Enum.DocsCase` | описание каждого значения `Core.Enum` в `@moduledoc`, один тест-модуль на приложение (см. «Enum: описания и внешние коды») |

Тестовая обвязка библиотеки живёт в `test/support`: `Core.DataCase`, `Core.TestRepo` (роль
`MyApp.DAO`), `Core.CodecFixture.*` (роль `MyApp.Codec.*`); фикстуры `Core.*Fixture`, дублёр
`Core.MqFake` и контрактные наборы `Core.*Contract` — по каталогу. Процессы, которые в
приложении поднимает его supervisor, стартуют в `test/test_helper.exs`.

`async: true` по умолчанию. `async: false` — только по одной из трёх причин, и уборка у каждой
своя:

| Причина | Примеры | Уборка |
|---|---|---|
| глобальное состояние | app env, именованный процесс, консолидация протоколов, экспортёр OTel (`Core.OtelFixture.attach/0`) | MUST восстанавливать в `on_exit` |
| общий sandbox | прогон или `await` проекции («Проекции»), процесс, стартующий внутри вызова («Процессы») | `on_exit` не нужен: DataCase при `async: false` ставит shared mode, запись откатывает sandbox |
| гонка двух транзакций | участники коммитят мимо sandbox («Гонки транзакций») | MUST убирать запись в `on_exit` |

Проверяется: `Credo.Check.Refactor.PassAsyncInTestCases` — `async:` задаётся явно.

Фикстуры MUST собирать агрегат доменными конструкторами (`<Aggregate>.new`,
`test/support/prim_fixture.ex`), а не Ecto fixtures и не строками в БД мимо репозитория: иначе
тест проверяет схему, а не домен. Фикстура event-sourced агрегата собирает состояние командами и
пишет события `append`, а не строки в таблицу проекции: иначе тест проверяет проекцию, а не
агрегат.

Репозитории тестируются через behaviour: `@repo Config.repo!(Behaviour)` атрибутом в теле
тест-модуля (`13-repos.md`, «DI»). Это `compile_env` под макросом — внутри `setup` и `test` он
даёт ошибку. Подмена реализации на тестовую — ключом в `config/test.exs`, а не другим call site.
При `shadow_copy?: true` контекст готовится как `Context.new() |> Repo.Sc.init()`.

### Гонки транзакций

Тест гонки двух транзакций (конкурентная запись одной версии, резерв одного ключа) MUST идти
мимо sandbox: под ним все процессы теста делят одно соединение и одну транзакцию, а блокировка,
которую ждёт второй участник, межтранзакционная.

- Каждый участник MUST держать свою транзакцию в `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`.
- Тест MUST быть `async: false`: запись участников коммитится по-настоящему и видна соседям.
- Записанное участниками тест MUST убирать сам в `on_exit`: отката sandbox у этой записи нет.
- Когда коммитить по-настоящему должны и процессы, которых тест не порождает (дерево проекций),
  MAY `Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)` на модуль с возвратом `:manual` в `on_exit`.

```elixir
# плохо — участники в sandbox теста: соединение и транзакция у них одни, второму нечего ждать
use MyApp.DataCase, async: true

defp participant(test), do: Task.async(fn -> Transact.run(DAO, fn -> serve(test) end) end)

# хорошо — участник на своём соединении мимо sandbox, запись убирается в on_exit
use ExUnit.Case, async: false

setup do
  on_exit(fn -> Sandbox.unboxed_run(DAO, fn -> DAO.query!("TRUNCATE es_events") end) end)
end

defp participant(test) do
  Task.async(fn -> Sandbox.unboxed_run(DAO, fn -> Transact.run(DAO, fn -> serve(test) end) end) end)
end
```

## Codec: round-trip

`Repo.Pg.Schema.to_entity/to_model` пишутся руками, поэтому каждый Codec-плагин MUST иметь
round-trip-проверку `entity |> dump() |> load() == entity`.

- Примерный тест (один-два инстанса) — минимум.
- Property-based (`stream_data`) — для типов с комбинаторикой полей (списки вариантов,
  вложенные структуры, nullable-поля): генератор доменных значений + `check all`.

Round-trip на текущем коде **не** ловит переименования: меняются обе стороны сразу.
От этого защищают golden-фикстуры (см. ниже).

### View: round-trip неприменим

`<Aggregate>.View.Codec` — dump-only (`loadable: false`), обратного преобразования у него нет.
Вместо round-trip MUST:

1. тест `<Aggregate>.ReadRepo.Pg.Schema.to_view/1` на полной строке — все колонки, включая
   nullable (тотальная функция: `nil` обязан пройти, а не упасть);
2. проверка формата `OutCodec.dump(view)` — id, даты и decimal совпадают с дампом
   соответствующего Prim (`OutCodec.dump(Agg.ID.new!(raw))` и т.п.), иначе wire read-пути
   молча разъедется с агрегатным;
3. `OutCodec.load(<Aggregate>.View, _)` поднимает `ArgumentError` — плагин остаётся dump-only.

### jsonb на read-пути: контракт wire

Полиморфная нагрузка (снимки, состояния шагов) переводится в формат внешнего профиля по
спеке `Core.Codec.Redump` (`13-repos.md`). Спека — декларация, и она обязана иметь
исполняемую проверку: `entity |> InCodec.dump() |> json_roundtrip() |> Redump.run(spec, OutCodec)`
MUST равняться `entity |> OutCodec.dump() |> json_roundtrip()`.

- `json_roundtrip` (`Jason.encode!` → `decode!`) обязателен: только он придаёт дампу ту
  форму, в которой jsonb реально возвращается из БД (строковые ключи, `Decimal` числом или
  строкой, `DateTime` строкой). Без него сверка идёт не с тем, что лежит в колонке.
- Проверка перебирает **весь набор** источников формы
  (всё, что перечисляет пишущий кодек), а не один пример: новый вариант нагрузки без
  объявленного формата обязан валить тест.
- Отдельным тестом — полнота декларации: у каждой нагрузки поля с форматируемым Prim
  (`:uuid` / `:datetime` / `:date` / `:decimal`) объявлены в спеке источника. Он даёт понятную
  ошибку раньше, чем расхождение дампов.

## Совместимость событий

Каждый агрегат с кодеком событий MUST иметь тест-модуль `use Core.Es.EventCompatCase` — один на
агрегат. Event-sourced агрегат передаётся `aggregate:` — case берёт его кодек; кодек state-stored
агрегата — `event_codec:`. Остальное case берёт из кодека и фасада `Core.Config.codec/0`. Каталог
фикстур, инварианты и правила эволюции — `14-events-outbox.md`, «Golden-фикстуры».

```elixir
# плохо — свой case: его проверки расходятся с кодеком библиотеки молча
use MyApp.EventCompatCase,
  codec: MyApp.Codec.Internal,
  event: Delivery.Event,
  aggregate_id: Delivery.ID

# хорошо — test/my_app/domain/<bc>/common/delivery/event_compat_test.exs
defmodule MyApp.Domain.<BC>.Common.Delivery.EventCompatTest do
  use Core.Es.EventCompatCase,
    event_codec: MyApp.Domain.<BC>.Common.Delivery.Event.Codec,
    async: true
end

# хорошо — test/my_app/domain/<bc>/common/account/event_compat_test.exs
defmodule MyApp.Domain.<BC>.Common.Account.EventCompatTest do
  use Core.Es.EventCompatCase,
    aggregate: MyApp.Domain.<BC>.Common.Account,
    async: true
end
```

## Wire-теги событий

Квалификацию тега типом агрегата и уникальность тега на всё приложение
(`app/14-events-outbox.md`, «Wire-тег события») приложение MUST проверять тест-модулем
`use Core.Es.Event.TagsCase` — один на все свои кодеки: `type:` не в snake_case, тег без префикса
`type:`, тег или `type:` двух кодеков валят сборку. Кодеки отбираются по `__es_type__/0`, а не
перечнем; теги кодека — значения `tags:` плюс ключи `upcasts:`; опции и семантика пропуска —
moduledoc `Core.Es.Event.TagsCase`; место теста в приложении —
`deps/core/docs/rules/app/19-testing.md`, «Ратчеты».

Сборка кодека тег с `type:` не сверяет и сверять не может: она видит один кодек, а тег
соседствует с чужими в брокере, в хранилище событий и в странице потока. Почему проверка живёт
в тесте — ADR-0020 (`docs/adr/0020-event-tag-ratchet.md`).

Записанный тег переименовать нельзя (ADR-0010), поэтому исключения адресные —
`except_tags: %{Кодек => ["тег"]}` и `except_types: [Кодек]`; уникальность ими не снимается.
Список MUST быть заморожен и пополняться только вместе со строкой `DEBT.md`
(`deps/core/docs/rules/app/19-testing.md`, «Ратчеты»).

```elixir
# плохо — своя копия сверки: свой отбор модулей и своё представление о префиксе
test "теги событий уникальны" do
  for mod <- codec_modules(), do: assert_prefixed(mod)
end

# хорошо — test/my_app/es/event_tags_test.exs
defmodule MyApp.Es.EventTagsTest do
  use Core.Es.Event.TagsCase,
    otp_app: :my_app,
    async: true
end
```

## Event-sourced агрегат

Решения агрегата тестируются без БД, в `ExUnit.Case, async: true`:

- given — `Core.Es.Aggregate.Test.given(state, results, by:, at:)` от `%Agg{id: id}`: результаты
  `decide/2`, версии и `id` событий ставит библиотека; разные авторы — цепочкой вызовов;
- when — `Agg.decide(cmd, state)`;
- then SHOULD — короткая форма результата: `{:ok, [{Mod, payload}]}`, `{:ok, []}`,
  `{:error, %Error{kind: :domain, code: …}}` без `message` / `detail`.

Given из команд через `execute/2` SHOULD NOT: команда не воспроизводит событие удалённого типа,
а тест одной команды начинает зависеть от `decide` другой. Then по `%Es.Event{}` или по
состоянию после команды SHOULD NOT — `id` и `at` событий пришлось бы сверять в каждом тесте.

Применение событий — отдельные тесты `evolve` через `Agg.fold/2`; полноту `evolve` проверяет
сборка репозитория агрегата (`11-domain.md`, «Event-sourced»).

```elixir
# плохо — given командами: тест закрытия зависит от decide открытия и заморозки
{:ok, {_events, state}} = Account.execute(%Account{id: id}, %Cmd.Open{name: name, by: by, at: at})
{:ok, {_events, state}} = Account.execute(state, %Cmd.Freeze{by: by, at: at})

# хорошо
import Core.Es.Aggregate.Test, only: [given: 3]

state = given(%Account{id: id}, [Event.Opened.draft(payload), Event.Frozen.draft()], by: by, at: at)

assert {:ok, [Event.Closed]} = Account.decide(%Cmd.Close{by: by, at: at}, state)
```

Записанные события — `Core.Es.Store.Test.events!(<Aggregate>.Event.Codec, id)`: все события
потока по возрастанию версии, прочитанные из `es_events` мимо репозитория агрегата и загруженные
фасадом с апкастом; нечитаемая строка — `Core.Exc`. Им проверяется **запись** — usecase, процесс
агрегата, фикстура с `append` — на DataCase; решения агрегата проверяются `decide/2` без БД.

```elixir
assert [%Event.Opened{}, %Event.Frozen{}] = Core.Es.Store.Test.events!(Account.Event.Codec, id)
```

### Резерв ключа

Полноту `reservation/1` проверяет сборка репозитория, резерв — библиотека (`13-repos.md`, «Резервы
ключей»). Каждый модуль ключа MUST иметь свой тест — на DataCase, записью через репозиторий
агрегата: сборка видит наличие clause `reservation/1`, но не её исход, а каноническую форму
`to_key/1` (`deps/core/docs/rules/app/13-repos.md`, «Уникальность без индекса состояния») не
видит вовсе. Usecase-тест её не ловит: обе стороны сравнения идут через тот же `to_key/1`.
Минимум теста:

- ключ, занятый другим агрегатом, — отказ с `code:` модуля ключа;
- значение, отличающееся от занятого только тем, что снимает `to_key/1` (регистр, пробелы), — тот
  же отказ; `to_key/1` без нормализации — свой ключ. Тест пиннит выбранную форму;
- событие с `:release` освобождает ключ, и он занимается заново;
- `find/2` по занятому значению — `%Agg.ID{}` того агрегата, по свободному — `nil`.

Значение ключа в тесте с `async: true` MUST быть уникальным (`System.unique_integer/1`) — в том
числе в общей обвязке (`MyAppWeb.ConnCase`, фикстуры пользователей): литерал делит одну строку
резерва на все async-модули, и соседний тест стоит на ней до конца чужой sandbox-транзакции, то
есть до конца чужого теста. Цена — сериализация async-модулей, а при разном порядке захвата двух
ключей встречное ожидание — deadlock.

```elixir
# плохо — литерал ключа: соседний async-тест с тем же логином ждёт конца этого теста
write!(id, [open("admin")])

# хорошо
login = "user#{System.unique_integer([:positive])}"
write!(id, [open(login)])
assert User.LoginKey.find(User.Login.new!(login), Context.new()) == id
```

```elixir
# плохо — своего теста у модуля ключа нет: usecase сверяет to_key/1 сам с собой
assert {:error, %Error{code: :name_taken}} = Usecases.Role.create(%{name: name}, context)

# хорошо — test/my_app/domain/<bc>/common/role/name_key_test.exs
:ok = @repo.append(created(taken, name), context)

assert {:error, %Error{code: :name_taken}} =
         @repo.append(created(Role.ID.new(), String.upcase(name)), context)

assert Role.NameKey.find(Role.Name.new!(name), context) == taken
```

## Проекции

Каждая проекция MUST иметь тест-модуль `use Core.Es.ProjectionCase` — один на проекцию: он
проверяет на golden-фикстурах событий (`14-events-outbox.md`) норму `clear/0` из
`22-projections.md`, «Объявление», и сам находит таблицы, которые пишет проекция. Проверка, опции
и `async: false` — moduledoc `Core.Es.ProjectionCase`; полноту `project/1` проверяет сборка
проекции (`22-projections.md`, «Объявление»).

```elixir
# плохо — clear/0 проверен вручную: таблица, добавленная в проекцию позже, в перечень не попадёт
test "clear/0 очищает read-модель" do
  :ok = Projection.project(opened)
  :ok = Projection.clear()
  assert DAO.aggregate(Account.ReadRepo.Pg.Schema, :count) == 0
end

# хорошо — test/my_app/domain/<bc>/common/projection_case_test.exs
defmodule MyApp.Domain.<BC>.Common.ProjectionCaseTest do
  use Core.Es.ProjectionCase,
    projection: MyApp.Domain.<BC>.Common.Projection,
    async: false
end
```

Проекцию SHOULD проверять записью через репозиторий агрегата → прогоном
`Core.Es.Projection.Test.run_until_idle/2` → чтением ReadRepo: так тест видит порядок событий
разных агрегатов, пропуск необъявленных тегов и апкаст. Прогон MUST идти в
`MyApp.DataCase, async: false`: блокировка пачки и строка чекпоинта держатся до конца
sandbox-транзакции, и пачка соседнего теста получила бы `{:error, :locked}`.

Прямой вызов `project/1` проекции MAY — в `async: true` на событиях из `Agg.execute/2` или
`events` state-stored агрегата; хелпера сборки событий нет.

```elixir
# плохо — чтение ReadRepo без прогона проекции: таблица пуста
{:ok, {id, _version}} = Usecases.Account.open(params, context)
{:ok, view} = Account.ReadRepo.get(id, :current, context)

# плохо — прогон в async: true: пачку проекции держит sandbox-транзакция соседнего теста
use MyApp.DataCase, async: true

assert :ok = Core.Es.Projection.Test.run_until_idle(MyApp.Domain.<BC>.Common.Projection)

# хорошо — test/my_app/domain/<bc>/<actor>/usecases/account_test.exs
use MyApp.DataCase, async: false

{:ok, {id, _version}} = Usecases.Account.open(params, context)
assert :ok = Core.Es.Projection.Test.run_until_idle(MyApp.Domain.<BC>.Common.Projection)
assert {:ok, %Account.View{status: :open}} = Account.ReadRepo.get(id, :current, context)
```

Usecase с `Projection.await/3` тест MUST гонять на тестовом дереве `enabled: false`,
`await: :inline` из `config/test.exs`: без него читателей нет, чекпоинт стоит и `await` не
дождётся ничего, а с ним `await` прогоняет проекцию до `:idle` в процессе теста, как
`run_until_idle`, и падает `RuntimeError` на `:locked`, `:outdated` и ошибке пачки. Такой тест —
тоже `MyApp.DataCase, async: false`. Ждать на живом дереве — подняв его своим `start_link`,
правкой отметки или env приложения — потребитель MUST NOT: к ветке неготовой read-модели ведёт
только хелпер библиотеки (ниже). Живое дерево (`await: :poll`) MAY только у тестов самого
ожидания в библиотеке: они проверяют опрос и сигнал чекпоинта, которых у `:inline` нет.

```elixir
# плохо — тестовое дерево без await: :inline: читателей нет, чекпоинт стоит, await не дождётся
config :my_app, MyApp.Projections, enabled: false

# хорошо — config/test.exs
config :my_app, MyApp.Projections, enabled: false, await: :inline
```

Запрет — на ожидание, а не на значение опции. Тест, который дерева не поднимает и `await/3` не
зовёт, MAY собрать опции с `enabled: true` — а значит и с `await: :poll`, потому что `:inline`
при `enabled: true` даёт `ArgumentError`. Так проверяется ратчет состава `watch_list/0` под
тумблерами (`deps/core/docs/rules/app/19-testing.md`, «Ратчеты»): читателей проекций
`Core.Es.Projection.Supervisor.watch_list/1` отдаёт только при `enabled: true`. Env MUST
возвращаться в `on_exit`.

```elixir
# хорошо — ратчет watch_list/0: дерево не поднято, await/3 не зван, опции идут чистой функции
saved = Application.get_env(:my_app, MyApp.Projections)
on_exit(fn -> Application.put_env(:my_app, MyApp.Projections, saved) end)
Application.put_env(:my_app, MyApp.Projections, enabled: true, await: :poll)

assert %{name: MyApp.Domain.<BC>.Common.Projection} in MyApp.PromEx.Workers.watch_list()
```

### Ветка неготовой read-модели

Ответ на `:projection_rebuilding` / `:projection_timeout` (у HTTP-API — 202,
`deps/core/docs/rules/app/15-web-api.md`) тест MUST проверять через
`Core.Es.Projection.Test.with_rebuilding/2`. На время блока хелпер переводит отметку дерева
на `await: :poll` и снимает строку чекпоинта, поэтому `await/3` внутри
отдаёт `:projection_rebuilding` сразу, не читая таймаут вызывающего; в `after` он возвращает и
отметку, и строку — со своей позицией, так что следующий `run_until_idle/2` досчитывает события,
а не зовёт `clear/0` и не проигрывает историю заново.

- Тест MUST быть `async: false` и идти в sandbox-транзакции: отметка глобальна для ноды, а
  снятие строки откатывает sandbox. Case-модуль задаёт ярус потребителя.
- Дерево MUST быть тестовым (`enabled: false`): у живого читатели приняли бы снятую строку за
  начало истории и стёрли read-модель через `clear/0`. Живое дерево — `ArgumentError`.
- Отметка общая для ноды: на `await: :poll` внутри блока переходят **все** проекции дерева.
  Ждёт блок несколько проекций — MUST называть все, иначе неназванная уйдёт в опрос до своего
  таймаута.
- Доводить тест до `:projection_timeout` MUST NOT: ветка ответа та же, а цена — полный таймаут
  вызывающего и таймаут приложения, настраиваемый только ради теста. Сам таймаут проверяют
  тесты ожидания в библиотеке.
- Ветка одна на приложение, и тест её MUST держать один —
  `deps/core/docs/rules/app/19-testing.md`, «Event sourcing».

```elixir
# плохо — свой `:poll` и короткий таймаут из env: тест платит реальным временем
Application.put_env(:my_app, MyAppWeb.Helper.Projection, await_timeout_ms: 50)
opts = Keyword.put(MyApp.Projections.opts(), :await, :poll)
:ignore = Core.Es.Projection.Supervisor.start_link(opts)

# хорошо — состояние подставлено на время блока, исход мгновенный
conn =
  Core.Es.Projection.Test.with_rebuilding(MyApp.Domain.<BC>.Common.Projection, fn ->
    patch(authed(ctx), "#{@path}/#{id}", body)
  end)

assert %{"data" => %{"version" => 2}} = json_response(conn, 202)
```

## Enum: описания и внешние коды

Описание значений в `@moduledoc` (`11-domain.md`, «Описание значений в `@moduledoc`») приложение
MUST проверять тест-модулем `use Core.Enum.DocsCase` — один на все свои enum: enum без таблицы
значений, не описанное значение и описанное несуществующее валят сборку. Enum отбирает
`Core.Enum.enum?/1`, а не перечень; разбор таблицы и опции — moduledoc `Core.Enum.DocsCase`; место
теста в приложении — `deps/core/docs/rules/app/19-testing.md`, «Ратчеты».

```elixir
# плохо — своя копия сверки: у каждого приложения своя регулярка и свой отбор модулей
test "у каждого enum описаны все значения" do
  for mod <- enum_modules(), do: assert_documented(mod)
end

# хорошо — test/my_app/enum_docs_test.exs
defmodule MyApp.EnumDocsTest do
  use Core.Enum.DocsCase,
    otp_app: :my_app,
    async: true
end
```

Enum с `codes:` MUST иметь round-trip по **всем** `values/0`
(`from_code(to_code(value)) == {:ok, value}`) и проверку нескольких известных кодов
против выгрузки источника. Round-trip сам по себе не ловит сдвиг нумерации: он проходит
и на выдуманных кодах, если они согласованы между собой.

У строковых кодов дополнительно проверяется, что совпадение точное (`"weight"` не проходит
за `"WEIGHT"`): молчаливая нормализация регистра свела бы два кода источника в один.

```elixir
test "коды справочника round-trip" do
  for value <- Type.values() do
    assert {:ok, ^value} = Type.from_code(Type.to_code(value))
  end
end

test "известные коды соответствуют справочнику" do
  assert {:ok, :railcar} = Type.from_code(2)
end
```

## Контрактные тесты behaviour

Если у behaviour больше одной реализации (`.Pg` и `.Cached`), общий набор тестов MUST лежать
в `test/support` и прогоняться на **каждой** реализации — иначе фасады расходятся молча.
Специфика реализации (hit/miss кеша, реальная загрузка) остаётся в тестах самой реализации и в
общий набор не переносится.

```elixir
defmodule MyApp.ReadRepoContract do
  defmacro __using__(impl: impl), do: quote(do: @impl_mod unquote(impl))
  # ... общие тесты, работающие через @impl_mod
end
```

## `constraint_errors`

Маппинг DB-ограничения в доменный код — декларация, которая при расхождении с `changeset/2`
не падает: наружу уходит прикладной `%Error{kind: :app, code: :write_failed}` (500 и лог)
вместо доменного кода с текстом для клиента. Поэтому приложение MUST иметь тест-модуль
`use Core.Repo.ConstraintErrorsCase` — один на все свои репозитории. Он сверяет:

1. каждый ключ `constraint_errors` объявлен в `changeset/2` (сверка по `error_type`, не по типу
   ограничения — `foreign_key_constraint/3` пишет `:foreign`);
2. каждое ограничение `changeset/2` покрыто маппингом;
3. имена ограничений (`unique_constraint(name:)`, ключи `children:`) существуют в БД —
   `pg_constraint` плюс имена индексов, `unique_index` строки в `pg_constraint` не создаёт;
4. каждый FK дочерней таблицы, кроме колонки `fk:` на сам агрегат, покрыт маппингом;
5. read-репозиторий (без `insert` / `update` / `save`) `constraint_errors` не объявляет: маппинг
   срабатывает только на записи, а у схемы read-репозитория нет `changeset/2` (`13-repos.md`).

Источник списка репозиториев — модули `otp_app:` со сгенерированными `__constraint_errors__/0`
(есть у каждого `use Core.Repo.Pg`) и `__children_constraint_errors__/0`
(`use Core.Repo.Pg.StateStored`), а не ручной перечень: новый репозиторий попадает под проверку
сам. Опции и границы проверки — moduledoc `Core.Repo.ConstraintErrorsCase`; место теста в
приложении — `deps/core/docs/rules/app/19-testing.md`, «Ратчеты».

```elixir
# плохо — своя копия сверки: у каждого приложения расходится с тем, что генерирует библиотека
test "каждый маппинг constraint_errors объявлен в changeset/2" do
  for repo <- write_repos(), do: assert_declared(repo)
end

# хорошо — test/my_app/repo/constraint_errors_test.exs
defmodule MyApp.Repo.ConstraintErrorsTest do
  use Core.Repo.ConstraintErrorsCase,
    otp_app: :my_app,
    async: true
end
```

## ACL

Каждый actor-репозиторий с `default_filters` под роль MUST иметь **negative**-тест: сущность
чужого владельца недоступна (`{:error, %Error{kind: :domain, code: :not_found}}`), а не «просто
не появилась в списке». Позитивный тест доступа сам по себе не доказывает, что фильтр работает.

## Время

Домен получает момент времени аргументом (`at`), а не читает часы внутри: `Es.Event.At.from(at)`,
`CreatedAt.from(at)`. `*.now()` вызывается на границе (usecase, воркер, OTP) — там его можно
подменить в тесте, передав явный `at`.

Тест MUST NOT зависеть от реального «сейчас»: сравнения дат — с зафиксированным значением,
переданным в конструктор.

## Процессы

- `Ecto.Adapters.SQL.Sandbox.allow(DAO, self(), pid)` для порождённых процессов, pid которых тест
  знает до их первого запроса.
- Процесс, который стартует внутри вызова (процесс агрегата на id при `{Agg.Process, enabled:
  true}`), тест MUST вести в shared mode sandbox — `async: false` на `MyApp.DataCase`
  (`start_owner!(shared: not async)`), без `allow` и `$callers`: pid появляется посреди вызова,
  который уже ждёт его запроса, и поставить `allow` некому.
- Циклы OTP проверять синхронным `run_once/1` (`Poller` / `Cleaner`), а не `sleep`
  в ожидании таймера.
- Именованный синглтон и глобальный конфиг — `async: false` с уборкой в `on_exit`
  («Case-модули»).
- Usecase с `Agg.Process.execute` тест потребителя SHOULD гонять на `{Agg.Process, enabled: false}`
  из дерева тестового окружения: команда идёт в процессе теста и в его sandbox, как вызов
  репозитория, без `allow`. Отметка старта глобальна — дерево ставит её один раз на прогон, а не
  тест.
- Устройство самих процессов — `17-otp-concurrency.md`.

```elixir
# плохо — процесс агрегата убран из тестового дерева: execute падает RuntimeError «не запущен»
children = [MyApp.DAO | if(test?, do: [], else: [{Account.Process, enabled: true}])]

# хорошо — дерево одно, config/test.exs выключает процесс: команда идёт в процессе теста
children = [MyApp.DAO, {Account.Process, Application.fetch_env!(:my_app, Account.Process)}]
config :my_app, Account.Process, enabled: false
```

```elixir
# плохо — allow на дерево: процесс на id стартует внутри execute под DynamicSupervisor, allow его
# не касается, и запрос процесса падает DBConnection.OwnershipError
{:ok, tree} = start_supervised({Account.Process, enabled: true})
Ecto.Adapters.SQL.Sandbox.allow(DAO, self(), tree)

# хорошо — async: false: MyApp.DataCase ставит shared mode, соединение теста видят все процессы
use MyApp.DataCase, async: false
{:ok, _tree} = start_supervised({Account.Process, enabled: true})
```

## Чувствительные данные

Проверка «секрет не утекает» (`refute inspect(...) =~ plaintext`) требует, чтобы Prim был
объявлен в `lib` или в `test/support`: протоколы консолидируются до старта тестов, и
`@derive Inspect` у модуля, объявленного внутри тест-файла, не действует. Чек-лист —
`12-errors.md`.

## Внешние зависимости

- Тесты, которым нужен живой брокер или хранилище, — под тегом, исключённым по умолчанию
  в `test/test_helper.exs`, и гоняются явно. В библиотеке это `:rabbit_stream`
  (`make test-stream`), инфраструктура поднимается `make infra-up`.
- Конфигурационный контракт (`Core.Config`) проверяется отдельно, `test/core/config_test.exs`:
  такие тесты правят app env целиком, поэтому `async: false` с восстановлением в `on_exit`.

## Связанные правила

- Репозитории и Sandbox — `13-repos.md`
- События и идемпотентность — `14-events-outbox.md`
- Кеш и контрактные тесты фасадов — `deps/core/docs/rules/app/16-caching.md`
- OTP — `17-otp-concurrency.md`
- Обвязка и ратчеты приложения — `deps/core/docs/rules/app/19-testing.md`
