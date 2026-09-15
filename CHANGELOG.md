# Changelog

## Не выпущено

### Ломающие изменения контракта

- **Write-путь возвращает входной агрегат, а не строку из БД.** `Repo.Pg.insert/4` и `update/4`
  больше не декодируют записанную строку через `to_entity`: возвращается тот же агрегат, что
  пришёл на вход, и он же уходит эталоном в `Repo.Sc` регистрацией после commit — эталон стал
  делом того, кто пишет, а не call site. Смысл возврата теперь один на оба пути: состояние, от
  которого мутируют дальше. Удалены `Repo.Pg.write_insert/4` и `Repo.Pg.write_update/4` — без
  decode они дублировали `insert/4` и `update/4`; `Repo.Pg.StateStored` зовёт обычные методы, а
  агрегат с очищенными `events` собирает **до** записи строки. Мотивация и отвергнутые варианты —
  `docs/adr/0001-write-path-returns-input-aggregate.md`.

- **Интерфейс фасада Codec сведён к `dump/1`, `load/2` и `load!/2`.** Удалены `prim/0`,
  `dump_raw/2`, `dump_raw_as/2`, `load/1`, `load!/1`, `dump_tagged/1`, `load_tagged/2`,
  `load_tagged!/2`: в фасад проникли частности View (raw-путь) и событий (самотегированный
  wire), и он перестал быть тем, чем задумывался. Осталась одна ось диспетчеризации — модуль.
  Prim-профиль (`use Core.Codec`) симметрично лишился `dump_raw/2` и `dump_raw_as/2`.
- **Полиморфный wire грузится через модуль-семейство.** У плагина появилась опция `union:`;
  фасад заводит на этот модуль клоузу `load/2`, а какой тип лежит в данных — решает сам плагин:
  `InCodec.load(<Aggregate>.Event, data)` вместо `InCodec.load(data)`. Реестра тегов у фасада
  больше нет, и требование глобальной уникальности тега снято — тег уникален внутри своего
  кодека. Квалифицированные имена (`order.created`) остаются конвенцией: тег виден в
  брокере и в event store рядом с чужими.
- **`Core.Codec.Plugin`: `types:` вместо `tags:`, `union:` вместо `tagged:`.** Механизм
  `tagged: true` / `dump_tagged` / `load_tagged` удалён целиком. `types:` стала обязательной;
  `union:` требует `loadable: true`. Генерация `type/1`, `types/0`, `mod_by_tag/1`,
  `__codec_tags__/0`, `__codec_tagged__/0`, `fetch_type/1` из плагина ушла — `type/1`, `types/0`
  и `mod_by_tag/1` теперь генерирует `Core.Es.Event.Codec` (контракт
  `<Aggregate>.Event.name/1` и `names/0` не изменился).
- **`Core.Es.Event.Codec`: колбэки вместо приватных клоуз, опции `event:` + `type:` + `tags:`.**
  `dump_payload/2` и `load_payload/3` стали callback'ами behaviour (`@impl true`, `def`, не
  `defp`), и `load_payload` возвращает `%Payload{}`, а не собранное событие: конверт разбирает
  и событие собирает билдер. Аргумент `envelope` и хелперы `event/2` / `event/3` пропали вместе
  с модулем `Core.Es.Event.Codec.Helper`. События без нагрузки клоуз не требуют вовсе. Опции
  `aggregate_id:` и `by:` сняты — билдер выводит их из самих событий; разные Prim у событий
  одного кодека — `CompileError`. Неизвестный тег теперь `:unknown_event_type` (`ns: :es`,
  модуль — кодек агрегата) вместо `:unknown_tagged_type` фасада. Clause `:unknown_event_type` в
  каталогах `<Aggregate>.Errors` больше не вызывается — ошибку строит кодек.
- **`Core.Es.Outbox.Envelope` удалён** (был добавлен в этом же невыпущенном цикле): обе стороны
  формата конверта живут в `Core.Es.Event.Codec`. Наружу отдаётся только пара `to_fields/1` /
  `from_fields/1` — для транспорта, который хранит поля события врозь. Оттуда же `Es.Outbox`
  берёт ключ, имя и заголовки записи, поэтому у его опции `event:` снято требование `name/1`.
- **`Core.Outbox.Name`** принимает тот же набор символов, что `Topic` (`[a-zA-Z0-9._-]`): имя
  сообщения — это wire-тег события, а он квалифицирован. Расширение множества значений,
  старые имена проходят.
- **`Core.Config.validate!/0`** проверяет у фасада `dump/1`, `load/2` и `load!/2` (было
  `dump/1`, `load/2`, `prim/0`).

  Форма конверта события и колонки outbox не изменились — данные этих правок мигрировать не нужно
  (перенос таблиц событий — пункт «State-stored агрегат пишет события в общую таблицу»). Миграция
  кода потребителя:

  ```elixir
  # кодек событий: было
  use Es.Event.Codec,
    tags: @tag_by_mod, event: User.Event, aggregate_id: User.ID, by: User.ID, errors: User.Errors

  defp dump_payload(%Event.Blocked{}, _codec), do: nil
  defp load_payload(Event.Blocked, nil, envelope, _), do: {:ok, event(Event.Blocked, envelope)}

  defp load_payload(Event.Created, payload, envelope, codec) do
    with {:ok, login} <- load_optional(field(payload, :login), User.Login, codec) do
      {:ok, event(Event.Created, Event.Created.Payload.new(login), envelope)}
    end
  end

  # стало — события без нагрузки не упоминаются вовсе
  use Es.Event.Codec,
    event: User.Event,
    type: "user",
    tags: @tag_by_mod

  @impl true
  def load_payload(Event.Created, payload, codec) do
    with {:ok, login} <- load_optional(field(payload, :login), User.Login, codec) do
      {:ok, Event.Created.Payload.new(login)}
    end
  end

  # чтение события: было → стало
  InCodec.load(data)                    → InCodec.load(User.Event, data)
  InCodec.load!(data)                   → InCodec.load!(User.Event, data)

  # read-модели, написанные руками: было → стало
  codec.dump_raw(:uuid, view.fias_id)   → dump_raw(Object.FiasID, view.fias_id, codec)
  dump_raw_optional(v, :datetime, codec) → dump_raw(Agg.ClosedAt, v, codec)
  ```

  Golden-фикстура грузится целиком через семейство — `InCodec.load(<Aggregate>.Event, fixture)`;
  свой `EventCompatCase` потребителя заменяет `Core.Es.EventCompatCase` (раздел «Новое»).
- **State-stored агрегат пишет события в общую таблицу `es_events`; триплет
  `Core.Es.Event.Repo{,.Pg,.Pg.Schema}` удалён.** Своя таблица событий на агрегат оставляла
  state-stored агрегат без глобальной позиции и отдельно от хранилища event-sourced; общая таблица
  (`docs/adr/0008-shared-event-table-xid8-position.md`) снимает и то и другое, а модули событий на
  агрегат (`<Agg>.Event.Repo{,.Pg,.Pg.Schema}`) становятся не нужны. События пишет
  `Core.Es.Store.append` в прежнем порядке записи (builder — `Core.Repo.Pg.StateStored`, раздел
  «Изменения контракта макросов»). Что правится у потребителя:
  - **Выпуск с остановкой записи state-stored агрегатов.** Ноды старого кода останавливаются до
    миграций: перенос без простоя (триггер на старых таблицах) не годится — транзакция старой ноды
    получает `xid` меньше копии. Миграции 1 и 2 накатываются одним `mix ecto.migrate` до старта
    нового кода, миграция 3 — после проверки перенесённого.
  - **Миграция 1** — таблица `es_events`: делегирование `Core.Es.Migration` (пример — пункт
    «Хранилище событий» в разделе «Новое»).
  - **Миграция 2** — копия истории по каждой старой таблице без преобразования тегов и нагрузки:
    старые формы читает апкаст кодека (`upcasts:`). `ORDER BY aggregate_id, aggregate_version`
    выдаёт номера позиции по возрастанию версий потока. Колонка тега старой таблицы — `type`, а тип
    агрегата — литерал `type:` кодека событий в колонке `aggregate_type`:

    ```elixir
    defmodule MyApp.Repo.Migrations.CopyStateStoredEvents do
      use Ecto.Migration

      def up do
        # 'role' — `type:` у `Role.Event.Codec`; `type` старой таблицы — wire-тег события
        execute("""
        INSERT INTO es_events
          (aggregate_type, aggregate_id, aggregate_version, event_id, tag, payload, by_id, at)
        SELECT 'role', aggregate_id, aggregate_version, id, type, payload, by_id, at
        FROM role_events
        ORDER BY aggregate_id, aggregate_version
        """)

        # … так же для каждой таблицы событий state-stored агрегата
      end

      def down do
        execute("DELETE FROM es_events WHERE aggregate_type IN ('role')")
      end
    end
    ```

  - **Миграция 3** — `drop table(:role_events)` по каждой старой таблице, после сверки числа
    событий: `SELECT count(*) FROM role_events` против
    `SELECT count(*) FROM es_events WHERE aggregate_type = 'role'`.
  - **Удалены** `Core.Es.Event.Repo`, `Core.Es.Event.Repo.Pg`, `Core.Es.Event.Repo.Pg.Schema`, а с
    ними у потребителя — `<Agg>.Event.Repo{,.Pg,.Pg.Schema}` и их тесты. Ключ подмены
    `config :my_app, <Agg>.Event.Repo, <Impl>` из app-env удалить: хранилище событий — модуль
    библиотеки, подменять можно только `<Agg>.Repo`.
  - **Чтение потока.** `@event_repo.page_by_aggregate(id, limit, offset, context)` →
    `Core.Es.Store.page_stream(Agg.Event.Codec, id, limit, offset, context)`,
    `count_by_aggregate` → `count` той же страницы. `page_stream` доступ не проверяет и
    `:not_found` не отдаёт, поэтому usecase обязан проверить права и существование агрегата до
    чтения — `ReadRepo.get(id, :current, context)` (`13-repos.md`, «Страница потока»). В тестах
    `{:ok, events} = @event_repo.list_by_aggregate(id, context)` →
    `events = Core.Es.Store.Test.events!(Agg.Event.Codec, id)`.
  - **`:version_mismatch` записи событий.** Код — тот же, из `errors:`; модуль ошибки —
    `behaviour:` write-репозитория вместо `<Agg>.Event.Repo`; detail `%{aggregate_id, versions}` →
    `%{aggregate_id, expected, actual}` (`expected` — первая версия потока в пачке, `actual` —
    наибольшая версия потока). Новый источник — страж `xid`: отказ бывает и без занятой версии,
    если транзакция получила `xid` раньше commit конкурента по тому же потоку. Реакция та же —
    повтор usecase; хелпера повтора нет.
  - **Запись событий.** Опции запроса (`:prefix`, `:timeout`) к записи событий больше не
    применяются: `Core.Es.Store.append` пишет в транзакции `DAO` вызывающего. Событие, которое
    фасад знает, но которого нет в `tags:` кодека (событие чужого агрегата), — `FunctionClauseError`
    на записи, а не строка в чужой таблице событий.
  - **Больше не нужны** Ecto-тип jsonb для `payload_type:` и Ecto-схема пользователей для
    `by_schema:`; FK `by_id` на таблицу пользователей в `es_events` нет.
- **Тип версии переехал в `Core.Version`.** `Core.Repo.version()` удалён — вместо него
  `Core.Version.expected()` (`%Version{} | :current`). Тип версии принадлежит `Version`,
  а не модулю репозитория; в `@spec` потребителя замена механическая.
- **`Core.Context.fetch/2` и `Context.Accessor.fetch/1` удалены.** Словарь чтения контекста —
  `exists?` / `find` / `get` / `get!` (`20-agreements.md`). Сохранённый `nil` по-прежнему
  отличим от отсутствующего ключа: `exists?/2` плюс `get/2` (тот отдаёт `{:ok, nil}`).
- **`Core.Repo.Sc.fetch/3` → `Core.Repo.Sc.find/3`.** Контракт `struct() | nil` — это `find`;
  под именем `fetch` в библиотеке оставалось два разных контракта.
- **`insert` / `update` / `save` больше не возвращают `{:error, Ecto.Changeset.t()}`.**
  Незамапленный DB-constraint и любой другой провал `changeset/2` — дыра в декларации
  `constraint_errors:` или в `to_model`, то есть ошибка программиста: теперь наружу уходит
  `%Error{kind: :app, ns: :repo, code: :write_failed}` с `detail: %{schema:, errors:}`
  (`Core.Repo.Pg.changeset_errors/1`). Контракт `errors:` потребителя не меняется — ошибку
  строит сам `Repo.Pg`. В `FallbackController` потребителя clause `{:error, %Ecto.Changeset{}}`
  надо удалить: ситуация приходит веткой `%Error{kind: :app}` (500 + лог), а не 400.
- **`Core.Error`: контракт конструирования и `has?/2` ужесточён.** Нарушение контракта перестало
  маскироваться под нормальный результат:
  - `%Error{}` требует `message` при прямом конструировании структурой (`@enforce_keys`); для
    `:app` допустим `nil`, но ключ обязан быть указан. Фабрики `Error.domain/1|2` и
    `Error.app/1|2` не затронуты.
  - `parent:` не `%Error{}` и не `nil` → `FunctionClauseError` вместо `ArgumentError` — как у
    `wrap/2`; `rescue ArgumentError` вокруг конструирования надо снять.
  - `Error.has?(err, [])` → `FunctionClauseError` вместо `true`: пустой критерий совпадал с
    любой ошибкой. Элемент критерия не keyword-парой → `ArgumentError`.
  - Дублирующийся ключ в литеральных attrs → `CompileError`; лишний ключ в динамическом attrs
    (переменная) → `ArgumentError` вместо молчаливого игнора.
  - `message: ""` больше не печатается пустотой: `String.Chars` и `format_chain/1` отдают
    fallback `"ns/code"`, как при `message: nil`.
- **`Core.Web.ErrorMapper` берёт текст через `String.Chars`, а не `error.message`.** Ошибка без
  текста (у `:app` `message` опционален) отдавала клиенту `null` в поле сообщения при 412 и 403,
  нарушая собственный `@type result` (`String.t()`); теперь в ответ уходит fallback `"ns/code"`.
  Затронуты клозы `:version_mismatch`, `:access_denied` и `kind: :domain`. `Core.Prim.wrap_parent`
  перестал дублировать то же правило своим `parent.message || "ns/code"`.
- **`Core.Context`: ключ — атом.** `@type key` сужен с `term()` до `atom()`, guard стоит на каждой
  функции: словарь ключей закрыт кодом (`Context.Accessor`, `Repo.Sc`), а не приходит извне.
  `Context.new/1` принимает только plain map — struct контекстом больше не притворится.
- **`inspect(%Context{})` печатает только ключи** — `#Context<keys: [...]>`. Контекст лежит в state
  OTP-процессов (`Outbox.Poller`, `Outbox.Cleaner`) и целиком уходит в crash-репорты, а его
  значения — текущий пользователь и прочие чувствительные данные (`12-errors.md`).
- **Функции `Context.Accessor` требуют `%Context{}`.** Сгенерированные `exists?/1`, `find/1`,
  `get/1`, `get!/1`, `put/2`, `delete/1` матчат struct в заголовке: чужой аргумент даёт
  `FunctionClauseError` на месте вызова, а не ошибку ключа внутри `Context`.
- **`Core.Repo.Sc.clear/1` и `delete/1` возвращают `%Context{}`, а не `:ok`.** Обе снимают ключ
  таблицы с контекста, и дальше работать нужно с возвращённым: жизненный цикл
  `init/1` → `clear/1` → `delete/1` стал однородным. Обращение по уже удалённой таблице (старая
  копия контекста) — no-op: `put/2` и `find/3` молчат, `clear/1` отдаёт контекст без мёртвого
  ключа, вместо `ArgumentError` из ETS.
- **`Core.Guard.is_error/1` удалён** — обёртка над `is_struct(value, Core.Error)`, а тривиальные
  Kernel-guards свод оборачивать запрещает (`20-agreements.md`). Замена — `is(err, Error)` из того
  же `Core.Guard` либо прямой `is_struct/2`.
- **`Core.Guard.in_enum/3`: дубль в subset — `CompileError`** (принимался молча). Compile-time
  хелперы `expand_mod!/2`, `enum_values!/2`, `literal_atom_list!/2` и `validate_subset!/4` стали
  приватными: это внутренности макросов, а не API.
- **`Core.Prim.String` обязан иметь верхнюю границу.** Без `max_len:` и без `sec_max_len:` —
  `CompileError`: примитив без границы принимает ввод любого размера, а по `min_len:` / `re:`
  вывести её не из чего. Сама отсечка переехала из `mutate` в `cast` (до `String.valid?/1`),
  поэтому её код ошибки теперь `:invalid_string`, а не `:invalid_value`.
- **`Prim.Integer` и `Prim.Decimal` ограничивают строковый ввод по байтам.** `Integer.parse/1` и
  `Decimal.new/1` обходят ввод целиком (у `Prim.Integer` ~2 млн цифр дают `SystemLimitError` мимо
  контракта `new/1`), а `min:` / `max:` проверяются уже после разбора и от его цены не защищают.
  Граница — новая опция `sec_max_len:`; default выводится из `max:` (плюс `scale:` у Decimal),
  без `max:` — 40 байт у Integer и 64 у Decimal. Ввод длиннее — доменная ошибка
  `:invalid_integer` / `:invalid_decimal`. Явная `sec_max_len:`, в которую не влезает собственный
  `max:`, — `CompileError`. Уже разобранный ввод (`integer()`, `%Decimal{}`) границей не ограничен.
- **`__domain_type_opts__/0` строкового Prim больше не содержит `trim:` и `sec_max_len:`.** Опции
  обработки переехали в новый `pipeline_opts:` (их получают cast/mutate-шаги), а `type_opts:`
  остался контрактом типа — `min_len:` / `max_len:` / `re:`; его читает `Codec.coerce/2`
  на read-пути.
- **`Prim.Compose`: `sensitive: false` поверх чувствительной базы — `CompileError`.** Наследование
  осталось, запрещено только понижение: без флага композит отдал бы raw базы в свой `Error.detail`
  целым — база успевает защитить лишь собственный `detail` внутри `parent`.
- **Read-путь дампит plain-kind Prim профилем кодека, а не «как есть».** `Core.Codec.coerce/2`
  оборачивает значение `:string` / `:integer`-Prim в его struct (приводить там нечего) и отдаёт
  в обычный `codec.dump/1`, поэтому переопределение `dump/1` / `dump_kind/2` в профиле действует
  и на read-пути: `Core.View` с полем `prim:`, `Codec.Redump` и `Codec.Helper.dump_raw/3` раньше
  проносили такое значение мимо профиля, и wire-формы путей расходились. Цена — требование к
  профилю: переопределение plain-kind MUST быть идемпотентным, потому что на read-пути оно ложится
  на значение, уже прошедшее dump профиля записи, а нормализовать его нечем (у форматируемых kind
  эту роль играет `cast` в `coerce/2`).
- **`Core.Codec.Redump.validate!/1` отвергает спеку, которую нечем исполнить.** `{:prim, Mod}` с
  kind вне `Core.Codec.coercible_kinds/0` (кастомный) и с `sensitive: true`-Prim — `ArgumentError`
  на месте объявления: неприводимое поле переводить нечем, а чувствительному значению не место
  на read-пути.
- **`Core.Codec.Helper.load_optional/3` принимает Prim-модуль первым аргументом** —
  `load_optional(Mod, value, codec)` вместо `load_optional(value, Mod, codec)`. Порядок стал общим
  у `load_optional/3`, `load_many/3`, `dump_raw/3` и `codec.load/2`. Арность не изменилась, поэтому
  перестановку компилятор не поймает: `nil`-значение уйдёт в `codec.load(nil, Mod)`, остальное —
  `FunctionClauseError`. Правка в плагинах кодеков механическая.
- **Плагину кодека требуется `dump/2`.** Отсутствие — `CompileError` на самом плагине: фасад уже
  завёл клозу на каждый его тип, и раньше она падала `UndefinedFunctionError` на первом дампе.
- **`Core.Codec.Facade.build_type_map!/1` → `validate_mods!/1`** (`:ok` вместо реестра). Фасад
  диспетчеризуется клозами на модуль, реестр никто не читал — от функции оставалась одна проверка
  уникальности модуля между плагинами. Заодно модуль-не-плагин отличается от несобранного
  (`Code.ensure_compiled!`), а `prim:` проверяется на экспорт `dump/1`, `load/2` и `load!/2`.
- **`Mq.Stream.Credentials` больше не зависает в `inspect/1`.** `defimpl Inspect` подставлял
  `"***"` в ту же структуру и снова звал `Inspect.Algebra.to_doc/2` — рекурсия без выхода: любой
  `inspect` (crash-дамп супервизора с аргументами ребёнка, `Logger` со state, `IO.inspect`) вешал
  процесс намертво. Стало `@derive {Inspect, except: [:password]}`:
  `#Core.Mq.Stream.Credentials<host: "…", port: 5552, vhost: "/", username: "…", ...>`. Код
  потребителя не правится.
- **`Mq.Stream.Reader` дропает запись, чей `topic` в конверте не совпадает с подпиской.** Топик
  в конверте пишет продюсер, а позицию записи в потоке задаёт подписка: чужая запись уходила в
  handler как своя. Стало — `warning` и `decode_drop`, как у нечитаемой записи: адаптер не отдаёт
  наверх то, чью принадлежность не может подтвердить. `warning` пишется один раз на подписку:
  чужой топик — состояние мисконфигурации, и запись о каждой записи залила бы лог со скоростью
  чтения.
- **`decode_drop` чанка с sub-entry batching считается в entries, а не в records**, и такой чанк
  теперь эмитит `deliver`. Числитель и знаменатель drop-rate (`mq.decode_drop.total` /
  `mq.deliver.entries.total`) были в разных единицах, а дропнутый чанк вообще не попадал в
  знаменатель. Число потерянных записей осталось в тексте `error`-лога; дашборд с делением этих
  метрик становится верным сам.
- **`Mq.Stream.Codec` не кладёт разбираемую запись в `Error.detail`.** Было тело чужого сообщения
  целиком — объём не ограничен, содержимое библиотеке неизвестно, а `detail` уходит в лог
  потребителя. Стало: `{:redacted, byte_size}` для binary, `:redacted` для остального,
  `%{position, token}` для `Jason.DecodeError`. Коды ошибок не изменились; код потребителя,
  разбиравший `detail` этих ошибок, читать в нём больше нечего.
- **`Mq.Stream.Writer`: `:confirm_timeout_ms` — дедлайн на пачку, а не на топик; producer
  неподтверждённого топика снимается.** Таймаут отсчитывался заново для каждого топика, поэтому
  пачка из N топиков ждала до N × timeout и переживала `:shutdown` и writer'а, и вызывающего
  поллера — супервизор добивал обоих посреди подтверждения. Кеш producer'а после неподтверждения
  оставался с локальным `sequence` впереди брокерского, и сверка не сходилась, пока в топик не
  пойдёт новый трафик; теперь producer снимается и в кеше, и в брокере, а следующая пачка
  объявляет его заново и перечитывает sequence. Снимается он **только** по таймауту: оборванное
  соединение чистит кеш веткой `:DOWN`, и снимать producer ещё и там значило бы пересоздавать
  его на каждой пачке, пока брокер недоступен. Сам кеш ограничен опцией `max_producers`
  (default 256) — при переполнении вытесняется топик, в который дольше всех не публиковали.
  Вытеснение идёт на границе пачки: внутри неё кеш только растёт, иначе при тесном лимите
  оно сняло бы producer топика, публикацию в который эта же пачка ещё подтверждает.
- **`Mq.Kafka.Writer.put_many/2` предупреждает о вызове внутри транзакции** — как
  `Mq.Stream.Writer`. Publish внутри `Transact.run` запрещён (`20-agreements.md`), но на
  Kafka-пути нарушение было молчаливым.

- **`Core.Mq.PromEx`: опция `readers:` — MFA-провайдер, а не список.** Было
  `readers: MyApp.PromEx.Mq.readers()`, стало `readers: {MyApp.PromEx.Mq, :readers, []}` — как
  `watch:` у `Core.Workers.PromEx` и `sizes:` у `Core.Cache.PromEx` (`10-architecture.md`).
  Список процессов принадлежит рантайму потребителя, а не моменту сборки метрик: reader, поднятый
  позже, в статический список не попадал. Без опции polling-группа reader'ов не строится вовсе
  (раньше строилась пустой).
- **`Mq.Stream.Reader` и `Mq.Stream.Writer` проверяют свои опции в `init/1`.** Мусор в них теперь
  `ArgumentError` с именем опции и ожидаемым значением. Раньше `initial_offset: :stored_offset`
  ронял reader `FunctionClauseError` уже в `handle_continue/2` — супервизор уходил в цикл
  рестартов и валил поддерево, а `credit: "2"` давал вечную переподписку с backoff, в которой
  опечатка неотличима от недоступного брокера.
- **Отброшенная запись двигает offset** (`Mq.Stream.Reader`, reliable-режим). Повтор дал бы тот же
  дроп, а без сохранения курсор оставался позади, и хвост из одних нечитаемых записей
  перечитывался и отбрасывался после каждого рестарта. Пишется offset не на каждую запись, а
  одним `store_offset` на серию — когда за дропами не осталось читаемых записей; `commit/1`
  подписчика серию перекрывает. Иначе чанк из полусотни нечитаемых entries давал бы полсотни
  cast'ов в соединение, а на оборванном — столько же `warning`. Накопленное сохраняется и в
  `terminate/2`, рядом со снятием подписки: иначе штатная остановка отдавала бы хвост назад
  брокеру, и он перебирался бы заново на следующем старте.
- **Чанк, пришедший без подписки, игнорируется целиком** (`Mq.Stream.Reader`). Раньше он попадал в
  буфер и в метрику `deliver`, хотя `get` при потерянной подписке отдаёт `:empty`, а переподписка
  буфер сбрасывает: доставленным считалось то, что никто не прочитает.
- **`exit` адаптера описан в контракте и больше не роняет подписчика.** `{:error, _}` в
  `Mq.Writer` / `Mq.ReaderReliable` покрывает отказ брокера, а `GenServer.call` к мёртвому или
  зависшему адаптеру приходит `exit` — теперь это сказано в обоих behaviour вместе с тем, кто его
  ловит: единица работы целиком (`Outbox.Poller` — цикл, `MqSubscriberReliable` — чтение и commit).
  `PubSub.MqSubscriberReliable` раньше падал на `get`/`commit` недоступного reader'а, теперь отдаёт
  цикл `:error` с `:reader_unavailable` и уходит в backoff. Ниже по стеку `exit` в `{:error, _}`
  не превращается: выдав недоступность процесса за отказ брокера, `Delivery.Mq` засчитывал бы
  записи попытку публикации — вплоть до `:failed` из-за инфраструктурного сбоя.
- **`Mq.Kafka.Writer` ловит любое исключение клиента**, а не только `RuntimeError`: klife падает
  исключением там, где контракт ждёт `{:error, _}`, и непойманное уносило `Outbox.Poller`.
  `detail` ошибки `:kafka_publish_failed` сведён к трём формам — атом распознанной причины
  (`:unknown_metadata_for_topic`), `{:error_code, code}` брокера либо текст; было четыре, включая
  сырой кортеж клиента и голое число кода (`detail: 1` → `detail: {:error_code, 1}`).

- **`Mq.Stream.Reader.info/1` отдаёт `dropped_offset`**, а `Core.Mq.PromEx` — gauge
  `mq.reader.chunk_remaining`. Первое объясняет состояние «курсор отстал, а очередь пуста»
  (накопленный, но ещё не сохранённый дроп), второе показывает недопотреблённый чанк: поле
  `chunk_remaining` в `info/1` было, а метрики по нему не было.

### Новое

- **`Core.Bind`** — макрос `bind/1`, аналог `use` из Gleam: строки `pattern <- call` разворачиваются
  в цепочку колбэков вместо лестницы отступов у bracket-функций (`File.open`, `Transact.run`,
  `:timer.tc`). Слева `x` / `{:ok, x}` — одноарный колбэк, `[]` — нуль-арный, `[a, b]` — двухарный;
  колбэк дописывается последним аргументом либо встаёт на место маркера `_`
  (`Transact.run(DAO, _, opts)`). Подключается `import Core.Bind`. Цепочки
  `{:ok, _} | {:error, _}` он не заменяет — там `with` с `else`.
- **`Core.Helper.StartOpts`** — проверка опций OTP-процесса в `init/1` (`module!/3`, `atom!/3`,
  `prim!/4`, `binary!/3`, `pos_integer!/4`, `boolean!/4`, `one_of!/5`, `raise_invalid!/4`): `ArgumentError` называет опцию,
  ожидаемое значение и полученное. `Core.Helper.Opts` остаётся про опции `use`-макросов и
  compile-time.
- **`Core.Mq.Stream.Buffer`** — буфер записей подписки и учёт кредитов, вынесенные из
  `Mq.Stream.Reader`: `new/0`, `put_chunk/2`, `take/1`, `len/1`, `remaining/1`. Кредит — число
  in-flight чанков, и его счёт держится на трёх счётчиках сразу; отдельной структурой он
  проверяется без соединения, подписки и GenServer, а reader только выдаёт брокеру то, что
  структура насчитала.
- **`Core.Mq.Client.ensure_available!/1`** — общая проверка «optional-клиент есть и адаптер собран
  с ним»; `Core.Mq.Stream.ensure_available!/0` и `Core.Mq.Kafka.ensure_available!/0` делегируют ей,
  а новый адаптер получает её строкой опций вместо копии `cond`.
- **Трассировка OpenTelemetry на транспорте библиотеки** (`Core.Otel`,
  `Core.Otel.Messaging`, `Core.Otel.LogFilter`). Зависимость — только
  `opentelemetry_api`: без SDK у потребителя все вызовы no-op. Готовые интеграции
  (Phoenix / Ecto / Oban) рвутся на outbox — событие пишется в одном процессе,
  публикуется поллером в другом, читается подписчиком в третьем, — поэтому контекст
  переносится заголовками: `<Aggregate>.Outbox.from_event/1` кладёт `traceparent`
  команды в `Record.headers`, `Delivery.Mq` открывает `"create <topic>"` на каждое
  сообщение и `"send <topic>"` на пачку со ссылками на них, `MqSubscriberReliable` —
  `"process <topic>"` с родителем из заголовков. Имена и структура — по semantic
  conventions messaging; `Core.Otel` при этом предметно нейтрален, словарь semconv
  живёт в `Core.Otel.Messaging`. `Core.Otel.LogFilter.filter/2` — primary-фильтр
  `:logger`, кладущий `trace_id` / `span_id` в metadata (OTLP-экспорт логов для BEAM
  не выпущен). Метрики остаются в PromEx. Подключение — раздел «Трассировка» в README,
  правила — `docs/rules/21-observability.md`.
- **`Delivery.Mq` добавляет к сообщению `traceparent`** — единственный заголовок, который
  доставка ставит от себя. Прикладные заголовки по-прежнему целиком задаёт продюсер записи,
  а `to_message/1` остаётся чистым преобразованием и заголовков не трогает.
- **Конверт доменного события** (`Core.Es.Event.Codec`): `dump_envelope/4` собирает его при
  постановке события в очередь и при записи в event store, разбор идёт через фасад
  (`codec.load(<Aggregate>.Event, data)` → `load/3` плагина). Разбор **safe**: неизвестный тег
  даёт `:unknown_event_type`, отсутствующее обязательное поле — `:invalid_envelope`
  (обе — `ns: :es`), а не падение подписчика. `to_fields/1` / `from_fields/1` — мост к
  транспортам, хранящим поля события врозь.
- **`Core.Prim.UUID` перестал разбирать строку дважды.** `cast/1` больше не зовёт `UUID.info/1`
  перед конверсией: разбор делает сам `string_to_binary!/1`, а невалидное значение по-прежнему
  становится `{:error, {:invalid_uuid, _}}`. `format/2` переводит **каноническую** форму срезкой
  (`:full` — тождественно), к библиотеке обращаясь только для hex, urn и верхнего регистра.
  Поведение не изменилось: любая форма ввода по-прежнему нормализуется, — изменилась цена.
  На поле `uuid` уходит 142 слова вместо 1383 и 0.3 мкс вместо 3.5 мкс; дамп страницы из
  1000 строк с четырьмя форматируемыми полями оставляет 5 МБ мусора вместо 14.5 МБ и вызывает
  1 minor GC вместо 130.
- **`Core.Codec.coerce/2`** — значение без Prim-обёртки → Prim (`cast` + `mutate` leaf-примитива,
  цепочка `Prim.Compose` целиком), и **`Core.Codec.Helper.dump_raw/3`** поверх него: read-путь
  дампит значение обычным `codec.dump/1`, поэтому разойтись с агрегатным путём ему больше нечем.
- **`union:` у `Core.Codec.Plugin`** — модуль-семейство типов для `codec.load/2`; `Core.Es.Event`
  генерирует интроспекцию `__es_payload__/0`, `__es_aggregate_id__/0`, `__es_by__/0`.
- **`Core.Helper.Opts.module_or_config!/4`** — опция-модуль с дефолтом из `Core.Config`,
  подставляемым как **вызов** в рантайме.
- **`Core.Repo.Pg.dao/1`** — Ecto-репозиторий из конфига `@pg`: явный `repo:` либо
  `Core.Config.dao()`.
- **`Core.Web.*` — общая часть границы HTTP** (без новых зависимостей: `plug` и `prom_ex`
  уже были в `deps`, Phoenix и OpenApiSpex не добавляются):
  `Core.Web.Params` (`find` / `get` / `get!` по atom-или-string ключу, `page/2`, `version/2`
  для `If-Match`), `Core.Web.Response` + `Core.Web.Response.Code` (конверт
  `%{code, messages[, data]}`), `Core.Web.ErrorMapper` (`%Error{}` → `{статус, код, текст,
  уровень лога}`, включая правило константного текста на 401), `Core.Web.MetricsPlug`.
  Потребитель расширяется тремя независимыми шагами: свои клозы `map/1` перед
  делегированием в `ErrorMapper.map/2`; свой словарь кодов (`Core.Enum` поверх
  `Core.Web.Response.Code.codes()`); `use Core.Web.Response, codes: MyCode` — конверт
  на этом словаре. Билдер проверяет на компиляции, что словарь целочисленный и покрывает
  базовые значения, которые возвращает `ErrorMapper`.
- **`Core.Helper.Keys`** — camelCase ↔ snake_case ключей map: зеркальная пара
  `camelize/1` / `snakify/1` (рекурсивно по map и спискам, atom- и string-ключи,
  struct проходит значением) и `camelize_key/1` / `snakify_key/1` для одного ключа.
- **`Core.Helper.Map.stringify_keys/1`** — atom-ключи в строки без смены регистра
  (смена регистра — задача `Core.Helper.Keys`).
- **`Core.Repo.Pg.changeset_errors/1`** — ошибки changeset как `%{поле => [текст]}`.
- **`Core.Mutator`** — behaviour (`mutate/2`) и диспетчер мутаторов, зеркало `Core.Validator`.
  Формы шага у `mutate:` / `custom_mutate:` и `validate:` / `custom_validate:` стали одни и те же:
  `{Module, opts}`, `fun/1`, `fun/2` или список любой из них (mutate добрал модульную форму,
  `Core.Validator` — `fun/1`).
- **`pipeline_opts:` у `use Core.Prim`** — опции для шагов `cast` / `mutate` (default — `type_opts`):
  обработке (`trim`, `sec_max_len`) в контракте типа места нет, а шагам она нужна.
- **`Core.Prim.Opts` и `Core.Prim.Wrapper`** — один пролог `use` на все обёртки (набор ключей →
  `kind:` → значения опций) и compile-time проверка **значений**: границы и их порядок, `%Regex{}`,
  `%Date{}` / `%DateTime{}`, IANA-зона `tz:`, версия UUID, boolean-опции. Ошибка в опции обязана
  падать `CompileError` на `use`: в рантайме она приходит доменной ошибкой первого `new/1`, где
  неотличима от невалидного ввода пользователя.
- **`Core.Codec.coercible_kinds/0` и `Core.Codec.coercible?/1`** — kinds, значение которых read-путь
  приводит к Prim (форматируемые профилем плюс `:string` / `:integer`). Единственный источник
  списка: по нему `Core.View` типизирует поля `prim:`, а `Codec.Redump` проверяет спеку формы.
- **`type:` у `Core.Context.Accessor`** — модуль значения: спеки сужаются с `term()` до `<Mod>.t()`,
  а `put/2` принимает только `%<Mod>{}` — чужое значение отсекается на компиляции, а не всплывает
  в репозитории. Сгенерированные функции стали `defoverridable`.
- **`except:` у `Core.Helper.Keys.camelize/2` и `snakify/2`** — список ключей (atom или строка),
  которые не преобразуются: регистр ключа сохраняется, значение под ним не обходится вовсе.
  Нужно для free-form нагрузки на границе HTTP (`metadata`, `payload`), где ключи задаёт не
  контракт API и camelCase их ломает. Арность прежних вызовов не изменилась (`opts \\ []`).
- **`Core.Helper.Opts.atom!/3`** — чтение опции-атома (не `nil`) с `CompileError` вместо тихого
  прохода значения другого типа.
- **Апкаст событий в кодеке агрегата: `upcasts:` + `upcast/2` у `Core.Es.Event.Codec`.** Версия
  схемы события — его тег: несовместимое изменение нагрузки или переименование тега — новый тег,
  а записанные события старого приводятся к текущей схеме при загрузке по семейству
  (`InCodec.load(<Aggregate>.Event, data)`) до выбора модуля. Строки хранилища не переписываются.
  Колбэк `upcast(old_tag, envelope)` отдаёт нагрузку следующего тега; цепочка идёт по шагам
  (v1 → v2 → v3), заголовок конверта не меняется, одно записанное событие — одно прочитанное.
  `CompileError`: источник в `tags:`, цель ни в `tags:`, ни источником, цикл, непустая карта без
  `upcast/2`. Интроспекция — `__es_mods__/0` и `__es_upcasts__/0`; `types/0` и `mod_by_tag/1`
  источников не видят. Правило свода «upcast по `aggregate_version`» снято: версия агрегата не
  разделяет потоки, начатые до и после выкладки (`docs/adr/0010-event-evolution-tag-upcast.md`).

  ```elixir
  @tag_by_mod %{Event.Created => "user.created.v2"}
  @upcasts %{"user.created" => "user.created.v2"}

  use Es.Event.Codec,
    event: User.Event,
    type: "user",
    tags: @tag_by_mod,
    upcasts: @upcasts

  @impl true
  def upcast("user.created", envelope), do: %{"login" => field(field(envelope, :payload), :name)}
  ```
- **Хранилище событий: `es_events`, `Core.Es.Store.append/5` и `page_stream/5`.** Одна таблица
  событий на приложение, общая для event-sourced и state-stored агрегатов; DDL —
  `Core.Es.Migration` (`up/0` / `down/0`), миграция потребителя делегирует ему, как
  `Core.Outbox.Migration`; она же создаёт `es_snapshots` — снапшоты event-sourced агрегатов — и
  `es_checkpoints` — чекпоинты проекций (база, где миграция из этого цикла уже накатана,
  откатывает и накатывает её заново). Поток —
  тип агрегата (`type:` кодека событий) и `aggregate_id`;
  глобальная позиция — пара `(xid, number)`, при которой запись не ждёт commit чужих транзакций
  (`docs/adr/0008-shared-event-table-xid8-position.md`). `append` пишет пачку потоков одного
  типа в транзакции `DAO` вызывающего и отвергает занятую версию, событие в потоке с более
  поздним `xid` и, с `continuous?: true`, первую версию потока не вслед за головой. Отказ —
  ошибка, которую строит колбэк вызывающего из `%{aggregate_id, expected, actual}`; транзакция
  в aborted не переходит. Записанное тест читает `Core.Es.Store.Test.events!/2`.
  `page_stream(Agg.Event.Codec, id, limit, offset, context)` отдаёт страницу потока —
  `Pagination.Result` из `Es.Event` по возрастанию версии с `count` всего потока: апкаст
  действует, нечитаемое событие — `{:error, _}` на всю страницу. Доступ она не проверяет, а
  пустой поток — страница с `count: 0`, поэтому права и существование агрегата usecase
  проверяет до чтения — `ReadRepo.get(id, :current, context)`. У потребителя — миграция:

  ```elixir
  defmodule MyApp.Repo.Migrations.CreateEsEvents do
    use Ecto.Migration

    defdelegate up, to: Core.Es.Migration
    defdelegate down, to: Core.Es.Migration
  end
  ```
- **`Core.Es.EventCompatCase` — golden-фикстуры событий проверяет библиотека.** Тест-модуль
  `use Core.Es.EventCompatCase, event_codec: Agg.Event.Codec, async: true` генерирует четыре
  теста: у каждого тега `types/0` есть фикстура; каждая фикстура, кроме источников `upcasts:`,
  несёт в `type` тег из имени файла и грузится фасадом `Core.Config.codec/0` через семейство; у
  каждого источника `upcasts:` есть фикстура; она несёт его тег и грузится апкастом.
  Event-sourced агрегат передаётся `aggregate:` (кодек — его `__es_event_codec__/0`) и получает
  пятый тест — полноту `evolve`: `evolve(%Agg{id: aggregate_id}, событие)` на фикстуре каждого
  тега, провал — только `FunctionClauseError` самой `Agg.evolve/2`. Семейство
  событий, тип агрегата и карта апкастов берутся из кодека, фикстуры —
  `test/support/fixtures/events/<тип агрегата>/<тег>.json`, другой каталог — `fixtures:`.
  `async:` уходит в `ExUnit.Case` (по умолчанию `true`) и пишется явно ради
  `Credo.Check.Refactor.PassAsyncInTestCases`. Инварианты — контракт кодека библиотеки, поэтому
  case живёт в ней, а не копируется в каждое приложение, где копии молча расходятся. Свой case
  потребителя заменяется:

  ```elixir
  # было
  use MyApp.EventCompatCase,
    codec: MyApp.Codec.Internal,
    event: User.Event,
    aggregate_id: User.ID,
    fixtures: "test/support/fixtures/events/user"

  # стало — каталог по умолчанию берётся из type: кодека, иной задаётся fixtures:
  use Core.Es.EventCompatCase,
    event_codec: User.Event.Codec,
    async: true
  ```
- **Event-sourced агрегат: `Core.Es.Aggregate`, `Core.Es.Cmd`, `Core.Es.Aggregate.Test`.**
  Агрегат, чей источник истины — события, рядом со state-stored. Автор пишет под
  `use Core.Es.Aggregate, event_codec:` два колбэка: `decide(команда, состояние)` →
  `{:ok, [{Event.Mod, payload} | Event.Mod]} | {:error, Error.t()}` и `evolve(состояние, событие)` →
  состояние. Библиотека генерирует `fold/2` (свёртка истории от любого состояния; разрыв версий
  или чужой `aggregate_id` — `ArgumentError`), `fold/3` (результат `decide` одной команды —
  несколько событий автор сворачивает через `with`), чистый шаг `execute/2` →
  `{:ok, {[Es.Event], состояние}} | {:error, _}` и `__es_event_codec__/0`. `id` события,
  `aggregate_id`, версии по порядку от `state.version`, `by` и `at` из команды ставит библиотека,
  она же ведёт `id` / `version` состояния — в отличие от state-stored агрегата, домен версию не
  трогает; модуль события не из кодека агрегата — `FunctionClauseError`, без `id` / `version` в
  `defstruct` — `CompileError`. Команда — `<Aggregate>.Cmd.<Name>` с `use Core.Es.Cmd`: `by` и
  `at` обязательны в `@enforce_keys`, иначе `CompileError` — автор и момент события приходят из
  данных команды, а не из `Context`. Решения тестируются без БД:
  `Core.Es.Aggregate.Test.given(state, results, by:, at:)` → состояние, then — короткая форма
  результата `decide/2`.

  ```elixir
  defmodule MyApp.Domain.<BC>.Common.Account do
    use Core.Es.Aggregate,
      event_codec: MyApp.Domain.<BC>.Common.Account.Event.Codec

    defstruct id: nil, version: nil, name: nil, status: nil

    @impl true
    def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen]}

    @impl true
    def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
  end

  # тест решения
  state = given(%Account{id: id}, [{Event.Opened, payload}], by: by, at: at)
  assert {:ok, [Event.Frozen]} = Account.decide(%Cmd.Freeze{by: by, at: at}, state)
  ```
- **Write-репозиторий event-sourced агрегата: `Core.Es.Aggregate.Repo` и
  `Core.Es.Aggregate.Repo.Pg`.** Изменяющий usecase читает состояние, решает и пишет события в
  теле одной функции — `get` → `Agg.execute/2` → `append` под одним `Transact.run`. Строки
  состояния нет: `get(id, version, context)` сворачивает поток агрегата через `fold/2`; пустой
  поток при `:current` — `%Agg{id: id, version: nil}`, а не `:not_found` (существование решает
  `decide`), `%Version{}` мимо головы потока — `:version_mismatch` (у пустого `actual: nil`).
  `get_many(pairs, context)` читает все потоки одним запросом и отдаёт одну `:version_mismatch`
  на все расхождения; `refresh(state, version, context)` дочитывает хвост после `state.version`.
  `append(events, context)` сам открывает транзакцию: `outbox.from_events` →
  `Core.Es.Store.append` с непрерывностью потока → `Outbox.Repo.append`; пачка потоков одного
  типа атомарна, `[]` — `:ok` без запросов. Behaviour — `use Core.Es.Aggregate.Repo, aggregate:,
  id:`, реализация — `use Core.Es.Aggregate.Repo.Pg, behaviour:, aggregate:, id:, errors:,
  outbox:` (+ `repo:`, `codec:`, `snapshot:`), резолв — по конвенции `<Behaviour>.Pg`; кодек
  событий берётся из агрегата. `CompileError`: нет `outbox:`, в `errors:` нет `:version_mismatch`, Prim агрегата
  кодека не равен `id:`, событие `outbox:` не из семейства кодека, `behaviour:` без колбэков
  `Core.Es.Aggregate.Repo`. Telemetry —
  `[:es, :aggregate, :load]` на вызов и `[:es, :aggregate, :fold]` на поток, span'а нет. Один
  репозиторий на агрегат в common-слое, без `default_filters`, `Repo.Sc` и `delete`
  (`13-repos.md`, «Write event-sourced агрегата»).

  ```elixir
  Transact.run(DAO, fn ->
    with {:ok, account} <- @repo.get(id, version, context),
         {:ok, {events, _account}} <- Account.execute(account, command) do
      @repo.append(events, context)
    end
  end)
  ```

  Снапшоты — `snapshot: [every: N, version: V]`: длинный поток больше не сворачивается с начала
  на каждом чтении. `get` / `get_many` / `refresh` читают снапшот из `es_snapshots` и хвост
  потока после него тем же одним запросом; свернули у потока не меньше `every` событий — один
  upsert на вызов после commit, вне транзакции — сразу; `append` снапшоты не пишет. Снапшот —
  кэш, а не источник истины: маркер (md5 модуля агрегата, кодека событий и модулей событий плюс
  `version:`) сбрасывает его при правке этого кода, битый снапшот даёт `warning` и полную
  свёртку, удаление строк корректность не меняет. `every:` обязателен; `version:` — по
  умолчанию 1 и поднимается с правкой кода вне этих модулей, от которого зависит `evolve`; без
  `snapshot:` снапшоты выключены. Telemetry снапшотов — `snapshot_hit` / `snapshot_miss` /
  `snapshot_rejected` в `[:es, :aggregate, :load]`, тег `snapshot` в `[:es, :aggregate, :fold]`
  и `[:es, :snapshot, :write]` (`13-repos.md`, «Снапшоты»).

  ```elixir
  use Core.Es.Aggregate.Repo.Pg,
    behaviour: MyApp.Domain.<BC>.Common.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    snapshot: [every: 100]
  ```
- **Проекции: `Core.Es.Projection` и `Core.Es.Projection.Test`.** Read-модель строится из событий
  хранилища агрегатов обоих видов в порядке глобальной позиции, а чекпоинт (`es_checkpoints`)
  меняется в одной транзакции с ней: событие не обрабатывается дважды и не теряется
  (`docs/adr/0009-projections-read-event-store.md`). Объявление —
  `use Core.Es.Projection, name:, events:, version:` (+ `repo:`, `codec:` из `Core.Config`) с
  колбэками `project(event)` и `clear()` → `:ok | {:error, Error.t()}`. `events:` — модули
  событий; их кодек — `<Aggregate>.Event.Codec` по раскладке `11-domain.md`, тип агрегата — его
  `type:`. Тег, известный кодеку, но не объявленный, пачка пропускает без загрузки, неизвестный
  кодеку — ошибка без сдвига чекпоинта. `CompileError`: нет `project/1` или `clear/0`; `name:` не
  непустая строка; `version:` не целое ≥ 1; в `events:` семейство, не событие, событие без кодека
  `<Aggregate>.Event.Codec` с `type:` или вне его `tags:`.

  `Core.Es.Projection.run_once(projection, batch_size: 100)` — одна пачка в транзакции `DAO`:
  `pg_try_advisory_xact_lock` по имени (не взята — `:locked`); строки чекпоинта нет или её версия
  ниже `version:` — `clear/0` и чекпоинт в начале истории; версия строки выше — `:outdated`; иначе
  `project/1` на события после чекпоинта и CAS по прочитанной строке — `:processed`, событий нет —
  `:idle`. Ошибка или исключение колбэка откатывает пачку и
  отдаёт `{:error, Error.t()}`; исключение — прикладная `:projection_raised` с модулем исключения
  в detail, текст — в `warning`. Внутри `Transact.run` — `ArgumentError`. Тест прогоняет проекцию
  `Core.Es.Projection.Test.run_until_idle(projection | [projection])` на `Core.DataCase` с
  `async: false` после записи через репозиторий. Пачка с работой идёт в корневом span'е
  `"project <имя>"` — `Core.Otel.Es.project/3` поверх нового `Core.Otel.root_span/3`. Нормы — новый
  свод `docs/rules/22-projections.md` (skill `projections`); сводам приложений с таблицей «Файл
  библиотеки» в `00-index.md` — строка `22-projections.md`.

  Пересборка на месте — подъёмом `version:` (`docs/adr/0011-projection-rebuild-by-version.md`):
  строка чекпоинта хранит версию и цель пересборки. Пачка новой версии зовёт `clear/0`, ставит
  чекпоинт в начало с целью — последней позицией событий типов проекции, видимой пачке, — и пишет
  `info` `projection= from_version= to_version=`; пачка, дошедшая до цели, пишет `info` «цель
  пересборки достигнута» — у новой проекции это признак «догнала». Код с версией ниже строки
  получает `:outdated` и событий не читает, `run_until_idle` отдаёт `{:error, :outdated}`;
  понижения версии нет. Строку чекпоинта проекции, убранной из кода, удаляет миграция
  потребителя — `Core.Es.Migration.delete_checkpoint/1`; библиотека строк сама не удаляет. Когда
  поднимать `version:`, новая проекция в три выкладки и удаление — `22-projections.md`.

  ```elixir
  defmodule MyApp.Domain.<BC>.<Actor>.AccountList.Projection do
    alias MyApp.Domain.<BC>.Common.Account

    use Core.Es.Projection,
      name: "account_list",
      events: [Account.Event.Opened, Account.Event.Closed]

    @impl true
    def project(%Account.Event.Opened{} = event), do: insert_row(event)

    def project(%Account.Event.Closed{} = event), do: close_row(event)

    @impl true
    def clear do
      {_count, nil} = MyApp.DAO.delete_all(AccountList.Row)
      :ok
    end
  end

  # тест: запись через репозиторий → прогон → ReadRepo
  assert :ok = Core.Es.Projection.Test.run_until_idle(AccountList.Projection)

  # миграция, удаляющая таблицы проекции, убранной из кода
  def up do
    drop table(:account_list)
    Core.Es.Migration.delete_checkpoint("account_list")
  end
  ```
- **Дерево проекций: `Core.Es.Projection.Supervisor`.** Приложение ставит в своё дерево
  `{Core.Es.Projection.Supervisor, projections: [...], enabled: ...}` — и на каждой ноде читатели
  `Core.Es.Projection.Reader`, по одному на проекцию под именем её модуля, сами гоняют пачки
  проекций: их будит `Core.Es.Store.append/5` после commit через `Core.Es.Projection.Registry`
  (`keys: :duplicate`), а между событиями они опрашивают хранилище с backoff.
  Внутри — `rest_for_one`: Registry → `one_for_one` читателей → `one_for_one` слушателей канала
  сигнала чекпоинта `Core.Es.Projection.Listener`, по одному на каждый различный `repo:`
  проекций; падение слушателя читателей не трогает; второй супервизор на ноде не стартует. Опции
  общие на дерево: обязательны `projections:` и `enabled:`; `batch_size` 100, `idle_min_ms` 50,
  `poll_interval_ms` 1 000, `retry_min_ms` 1 000, `retry_max_ms` 30 000, `shutdown` 30 000,
  `await: :poll` — режим `Core.Es.Projection.await/4`, `await_min_ms` 10 и `await_max_ms` 100 —
  его шаг опроса, `notifications: true` — сигнал чекпоинта между нодами (пункт
  «Read-after-write»).
  Config и env библиотека не читает — README рекомендует env `ES_PROJECTIONS_*` в `runtime.exs`.
  Модуль без `use Core.Es.Projection`, дубль `name:` или недопустимая опция —
  `ArgumentError` при любом `enabled:`; `enabled: false` и `projections: []` — `:ignore` с `info`;
  любой старт ставит отметку в `:persistent_term` (список проекций и опции).

  Слушатель держит `Postgrex.Notifications` с `sync_connect: false` и `auto_reconnect: true`:
  подписка на канал — после `init/1`, недоступная база старт дерева не роняет, после разрыва
  соединение и подписка восстанавливаются сами. Соединение — `repo.config()`, поверх — keyword из
  `notifications:`: нода открывает по соединению на каждый различный `repo:` проекций, и их
  учитывают лимиты базы и пулера. `LISTEN` через pgbouncer в transaction mode уведомлений не
  получает — слушателю нужен прямой хост: `notifications: [hostname: "db-direct"]`. Приложению на
  одной ноде хватает сигнала внутри VM: `notifications: false` — ни слушателей, ни `NOTIFY` пачек
  ноды. `notifications:` — не `true`, `false` или keyword — `ArgumentError` при любом `enabled:`;
  нода с `enabled: false` соединений не открывает.

  Цикл читателя: `:processed` — следующая пачка сразу; `:idle` / `:locked` — от `idle_min_ms` с
  удвоением до `poll_interval_ms`, `wake` в ожидании — цикл сразу; отказ пачки, исключение, exit,
  throw или недоступная БД — повтор от `retry_min_ms` с удвоением до `retry_max_ms` без пропуска
  события и без рестарта процесса, `warning` на попытку с `projection= position= event_id=
  attempt=`; `:outdated` — через `poll_interval_ms`, `warning` один раз. На повторе и `:outdated`
  `wake` не ускоряет. Читатель под `trap_exit`: остановка ждёт конца пачки в пределах `shutdown`.
  Telemetry `[:es, :projection, :cycle]` на каждый цикл — `duration`, `events`, `attempt`; метки
  `projection`, `result`, при `:retry` — `error` (`ns/code`, модуль исключения, `exit`, `throw`).
  `watch_list/1` принимает опции дерева и отдаёт элементы `Core.Workers.PromEx` на читателей,
  `component: "es_projection:<name>"`; при `enabled: false` — пусто. У `Core.Helper.StartOpts`
  появились обязательные `list!/3` и `boolean!/3`. Нормы — `22-projections.md` («Дерево») и
  `17-otp-concurrency.md`: `watch_list` без элементов выключенного поддерева вместо `required:`,
  получатели `wake` в `Registry`, следующий тик — чистая функция.

  ```elixir
  defmodule MyApp.Projections do
    def opts do
      [projections: [AccountList.Projection]] ++ Application.fetch_env!(:my_app, __MODULE__)
    end
  end

  # MyApp.Application
  children = [MyApp.DAO, {Core.Es.Projection.Supervisor, MyApp.Projections.opts()}]

  # MyApp.PromEx.Workers
  def watch_list, do: Core.Es.Projection.Supervisor.watch_list(MyApp.Projections.opts())
  ```
- **Read-after-write: `Core.Es.Projection.await/4`.** После `:ok` usecase вызывающий ждёт, пока
  проекция обработает последнее событие потока агрегата, и читает read-модель уже с ним:
  `Core.Es.Projection.await(projection, aggregate, aggregate_id, timeout)` →
  `:ok | {:error, Error.t()}`. `aggregate` — модуль `<Aggregate>` любого вида с кодеком событий
  `<Aggregate>.Event.Codec` (по раскладке `11-domain.md` — сам агрегат): той же раскладкой
  проекция находит кодек модуля события. Цель — позиция последнего события потока на момент
  вызова: пустой поток или чекпоинт не ниже цели — `:ok`; строки чекпоинта нет, её версия ниже
  `version:` или чекпоинт ниже цели пересборки — сразу прикладная `:projection_rebuilding`, а не
  ожидание до таймаута; иначе ожидание до таймаута — прикладная `:projection_timeout`
  (`ns: :es`). Ответ приходит сразу после commit пачки на любой ноде: пачка с исходом
  `:processed`, включая старт пересборки, в своей транзакции шлёт `NOTIFY` в канал
  `core_es_checkpoint` с именем проекции, слушатель каждой ноды переводит уведомление в сигнал
  чекпоинта, а на своей ноде сигнал после commit шлёт и читатель; ожидающий, подписанный на сигнал
  до чтения цели, перечитывает чекпоинт тем же разбором исходов. Кластер Erlang не нужен, `append`
  в канал не шлёт. Имя канала и payload — протокол между нодами разных версий: их смена —
  ломающее изменение. При `notifications: false` пачки ноды `NOTIFY` не шлют — PostgreSQL берёт
  блокировку коммита и без слушателей, — и пачку такой ноды ожидающие других нод находят шагом.
  Уведомление, потерянное на разрыве соединения слушателя или в пулере, ожидание догоняет шагом:
  сломанный быстрый путь виден по `duration` `[:es, :projection, :await]` на уровне шагов, а не
  пачки (ADR-0013). Подписка — alias
  процесса: после ожидания при любом исходе она снимается, доставленные сигналы вычерпываются, и
  mailbox вызывающего — GenServer, LiveView — остаётся чистым. Страховка — опрос `es_checkpoints`
  шагами с удвоением от `await_min_ms` до `await_max_ms` дерева по расписанию от начала ожидания,
  сигналы шагов не сдвигают, а шаг позже таймаута не наступает; шаг — опция: короче шаг — быстрее
  ответ без сигнала, но чаще запросы к базе. Каждый шаг будит читателя проекции на своей ноде:
  пачка при `wake` после записи не видит событие, пока открыта более старая пишущая транзакция
  кластера, и без пробуждения читатель ждал бы до `poll_interval_ms`, а так подхватывает событие
  за шаг после её commit. Проекция в повторе чекпоинт не двигает, и ожидание идёт до таймаута.
  На время ожидания вызывающий связан с Registry дерева: остановка дерева посреди ожидания
  завершает вызывающего без `trap_exit`, а с `trap_exit` приносит `{:EXIT, _, _}`. `append`
  репозитория по-прежнему `:ok` и позицию не возвращает. Ошибки программиста: тип агрегата вне
  `events:` — `FunctionClauseError`; вызов внутри транзакции — `ArgumentError`; дерево проекций
  не запущено — `RuntimeError`; проекция не из `projections:` дерева — `ArgumentError`.

  У `Core.Es.Projection.Supervisor` — опция `await: :poll | :inline`, по умолчанию `:poll`;
  `:inline` при `enabled: true` — `ArgumentError`. В тестовом дереве с `await: :inline` ожидание
  прогоняет проекцию до `:idle` в процессе теста с `batch_size` дерева и сверяет чекпоинт; любой
  другой исход — `RuntimeError` с исходом и именем проекции. Ожидание идёт в span'е
  `"await <имя>"` (`Core.Otel.Es.await/4`) внутри трейса вызывающего, `:projection_timeout` и
  `:projection_rebuilding` — `record_error/1`; telemetry `[:es, :projection, :await]` —
  `duration`; `projection`, `result: :ok | :timeout | :rebuilding`. Нормы — `22-projections.md`
  («Read-after-write»), `20-agreements.md` (`await` MUST NOT внутри `Transact.run`),
  `19-testing.md` (`await: :inline`), `21-observability.md` (span ожидания на call site).

  ```elixir
  # config/test.exs
  config :my_app, MyApp.Projections, enabled: false, await: :inline

  # запись → ожидание проекции → чтение read-модели
  with :ok <- Accounts.Open.call(id, params, context),
       :ok <- Core.Es.Projection.await(AccountList.Projection, Account, id, 5_000) do
    AccountList.ReadRepo.get(id, :current, context)
  end
  ```
- **`Core.Es.ProjectionCase` — полноту `project/1` и `clear/0` проверяет библиотека.** Тест-модуль
  `use Core.Es.ProjectionCase, projection:, async: false` генерирует два теста на golden-фикстурах
  событий — `<тип агрегата>/<текущий тег>.json` от корня `fixtures:` (по умолчанию
  `test/support/fixtures/events`), тип и тег берутся из кодека каждого модуля `events:`. Первый
  требует у `project/1` клаузу каждого модуля: провал — только `FunctionClauseError` самой
  `project/1`, исключение или `{:error, _}` из тела клаузы пропуском не считаются. Второй
  прогоняет `project/1` на всех фикстурах, находит записанные таблицы по статистике
  `pg_stat_xact_user_tables`, зовёт `clear/0` и требует пустоты каждой; ни одной таблицы — провал.
  Перечня таблиц нет ни у case, ни у `use Core.Es.Projection`: новая таблица проекции попадает под
  проверку сама. Нет фикстуры, в ней не текущий тег или она не грузится — провал обоих тестов с
  путями. Проверки идут в транзакции с откатом на своём sandbox checkout, case — `async: false`:
  `async: true` — `CompileError`, явный `async: false` требует
  `Credo.Check.Refactor.PassAsyncInTestCases`. Норма — `19-testing.md`, «Проекции».

  ```elixir
  # test/my_app/domain/<bc>/<actor>/account_list/projection_case_test.exs
  defmodule MyApp.Domain.<BC>.<Actor>.AccountList.ProjectionCaseTest do
    use Core.Es.ProjectionCase,
      projection: MyApp.Domain.<BC>.<Actor>.AccountList.Projection,
      async: false
  end
  ```
- **Процесс агрегата: `Core.Es.Aggregate.Process`.** Команда одного event-sourced агрегата — вызов
  `Agg.Process.execute(id, version, command, context, fun, opts)` → `:ok | {:error, Error.t()}`
  вместо тела usecase `get` → `Agg.execute/2` → `append`: команды одного агрегата встают в очередь, а
  не конфликтуют, и поток не перечитывается целиком на каждую команду. Модуль
  `use Core.Es.Aggregate.Process, repo: Agg.Repo` генерирует `execute/6`, `child_spec/1` и
  `watch_list/1`; реализация `repo:` — `<Behaviour>.Pg`, как у `Core.Config.repo!/1`. Состояние →
  `Agg.execute/2` → `append` → `fun.(events)` идут одной транзакцией `Core.Config.dao/0`: колбэк —
  сопутствующие записи (Oban, `DAO`) под ограничениями `Transact.run`, его `{:error, _}` откатывает
  и события, а возврат вне `:ok | {:error, _}` — `CaseClauseError` до commit.
  `:version_mismatch` из `append` при `:current` — повтор новой транзакцией до `retries:` с `debug`
  на повтор, исчерпание — `warning` `type= aggregate_id= retries=` и ошибка вызывающему;
  `%Version{}` мимо головы потока, в том числе пустого, — `:version_mismatch` без повтора. Опции
  старта: `enabled:` обязательна, `retries:` 3, `idle_timeout:` 60 000 мс.
  - `enabled: true` — `Supervisor` под именем модуля процесса из `Registry` и `DynamicSupervisor`
    (имена `<Agg.Process>.Registry` и `<Agg.Process>.Supervisor`), `info` и отметка в
    `:persistent_term`. Команды агрегата идут по одной в его процесс на id (`restart: :temporary`,
    единственность — на ноду): он стартует в первой команде без запросов, читает состояние `get`,
    дальше дочитывает хвост `refresh` от состояния последнего commit и уходит по `idle_timeout:`
    без записи снапшота. Корректность по-прежнему держат проверки `append`: второй процесс того же
    агрегата и запись в обход процесса штатны.
  - Колбэк исполняется в процессе на id; на время команды туда ставятся OTel-контекст и
    `Logger.metadata()` вызывающего, а `:shadow_copy` в `context` заменяется таблицей `Repo.Sc`
    процесса — приватная таблица вызывающего ему недоступна, поэтому `context`, пойманный колбэком
    из замыкания, с `Repo.Sc` не работает.
  - `timeout:` (5 000 мс) — дедлайн: команда, простоявшая в очереди до него, отбрасывается до
    транзакции, дедлайн, истёкший до commit, откатывает транзакцию. Истечение и падение процесса, в
    том числе `raise` в `decide` / `evolve` / колбэке, — exit вызывающему; `:noproc` — старт и один
    повтор вызова.
  - `enabled: false` — `:ignore`, `info` и отметка, команда исполняется в вызывающем процессе.

  Вызов внутри транзакции — `ArgumentError`, нет отметки старта — `RuntimeError`. Span
  `"execute <тип>"` (`Core.Otel.Es.execute/4`) — в трейсе вызывающего и охватывает ожидание в
  очереди, выход из неё — span event `dequeued` (новая `Core.Otel.add_event/2`); атрибуты
  `core.es.aggregate.type` / `.id`, `core.es.command`, `core.es.execute.mode`, `core.es.retries`,
  прикладная ошибка — `record_error/1`. Telemetry `[:es, :aggregate, :process, :execute]` —
  `duration`, `queue`, `retries`; `type`, `mode: :process | :inline`,
  `result: :ok | :version_mismatch | :error | :exit`; на процесс на id —
  `[:es, :aggregate, :process, :start]` и `:stop` с `reason: :idle | :error`. `watch_list(opts)` —
  верхний супервизор, `component: "es_aggregate_process:<тип>"`; при `enabled: false` — `[]`. Нормы
  — `13-repos.md` («Процесс агрегата»: MAY для команды одного агрегата, несколько агрегатов — MUST
  usecase → repo), `20-agreements.md` (`execute` MUST NOT внутри `Transact.run`, повтор на
  `debug`), `21-observability.md` (span команды у вызывающего), `19-testing.md` (`enabled: false`
  в тестах потребителя, shared mode sandbox у процессов, стартующих внутри вызова).

  ```elixir
  defmodule MyApp.Domain.<BC>.Common.Account.Process do
    use Core.Es.Aggregate.Process,
      repo: MyApp.Domain.<BC>.Common.Account.Repo
  end

  # MyApp.Application; config/test.exs — enabled: false
  children = [MyApp.DAO, {Account.Process, Application.fetch_env!(:my_app, Account.Process)}]

  # MyApp.PromEx.Workers — те же опции, что у элемента дерева
  def watch_list, do: Account.Process.watch_list(Application.fetch_env!(:my_app, Account.Process))

  # было — usecase: Transact.run с get → Account.execute/2 → append
  # стало
  Account.Process.execute(id, :current, command, context, &Notifications.enqueue(&1, context))
  ```
- **Метрики event sourcing: `Core.Es.PromEx`.** Один PromEx-плагин на всю область: восстановление
  агрегата, снапшоты, проекции и процессы агрегата читают общие таблицы одного `Core.Config.dao/0`,
  и дежурный видит их на одном дашборде. Event-метрики строятся всегда — по telemetry
  `[:es, …]`: восстановление агрегата (`es_aggregate_load_total{type,op,result}`, длительность и
  распределение длины свёрнутого хвоста `es_aggregate_fold_events{type,snapshot}` — для выбора
  `every:`), запись снапшота (`es_snapshot_write_*`), цикл проекции
  (`es_projection_cycles_total{projection,result}`, `es_projection_duration_*`,
  `es_projection_events_total`, `es_projection_retry_total{projection,error}`), ожидание проекции
  (`es_projection_await_*`) и процесс агрегата (`es_aggregate_process_execute_*` с очередью и
  повторами, `start` / `stop`). Polling-группы — по MFA и под `Core.PromEx.Safe`:
  - `projections:` — провайдер опций дерева `Core.Es.Projection.Supervisor`, тот же, что у
    элемента дерева: отставание `es_projection_lag_seconds` — возраст первого необработанного
    события типов проекции (`LIMIT 1` на тип; строки чекпоинта нет или её версия ниже
    `version:` — от начала истории), `es_projection_rebuilding`, `es_projection_outdated` (версия
    строки выше `version:` на этой ноде) и `es_checkpoint_orphan{name}` (строка без проекции в
    списке ноды);
  - `processes:` — провайдер списка модулей `use Core.Es.Aggregate.Process`:
    `es_aggregate_processes{type}`.

  Рекомендованные алерты `EsProjectionRetrying`, `EsProjectionLagging`, `EsProjectionRebuildLong` и
  `EsProjectionOutdated` с PromQL — `22-projections.md`, «Эксплуатация»; пороги выбирает приложение.

  ```elixir
  # MyApp.PromEx
  def plugins do
    [
      {Core.Es.PromEx,
       poll_rate: 5_000,
       projections: {MyApp.Projections, :opts, []},
       processes: {MyApp.PromEx.Es, :processes, []}}
    ]
  end

  # MyApp.PromEx.Es
  def processes, do: [MyApp.Domain.<BC>.Common.Account.Process]
  ```

### Изменения контракта макросов

- **Реализация репозитория выводится из имени behaviour.** `Core.Config.repo!/1` резолвит
  `<Behaviour>` → `<Behaviour>.Pg`, если в app-env потребителя не задано другое; тот же
  дефолт у `Core.Config.outbox_repo/0`. Из `config/config.exs` уходит по строке на каждый
  репозиторий, включая обязательную прежде
  `config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg` — старые ключи продолжают работать
  и нужны только при подмене реализации. Call site переводится на
  `@repo Config.repo!(Behaviour)`: прямой `Application.compile_env!/2` на доменный
  behaviour стал нарушением свода (`13-repos.md`, «DI»). Модуль-реализация проверяется на
  компиляции — отсутствие даёт `CompileError`, а не `UndefinedFunctionError` на первом
  вызове, ценой ребра call site → реализация в графе компиляции. `otp_app` теперь читает
  любой call site, поэтому он обязан лежать в `config.exs`, а не в `runtime.exs`.
  Мотивация, отвергнутые варианты и цена — `docs/adr/0006-repo-impl-resolved-by-convention.md`.
- **`Repo.Pg.StateStored` больше не читает конфигурацию на компиляции.** Реализация outbox
  резолвится вызовом `Core.Config.outbox_repo/0` в момент flush; атрибут `@es_outbox_repo` снят.
  Доступ к app-env потребителя целиком
  сжат в `Core.Config`, и главный инвариант из `10-architecture.md` проверяется линтером
  `make boundary-check` (`scripts/boundary_lint.exs`), а не грепом на ревью. Тот же скрипт
  проверяет и сторону потребителя — `boundary_lint.exs --consumer lib test` ловит прямой
  `compile_env` на модуль-behaviour; потребитель зовёт его из `deps/core/scripts/`.
- **`codec:` и `repo:` без явной опции резолвятся в рантайме.** `Es.Outbox`, `Repo.Pg` и
  `Repo.Pg.StateStored` больше не читают
  `Core.Config` в момент разворачивания макроса — как это уже делал `Repo.Pg.Schema`.
  Потребитель, задающий `dao:` / `codec:` в `runtime.exs`, компилируется без обходных
  путей; поведение при явно заданной опции не изменилось.
- **Снятые атрибуты макросов.** `Es.Outbox` больше не занимает `@es_codec`: вместо него
  генерируется приватная `es_codec/0`. Правка нужна только тому, кто ссылался на этот атрибут
  из собственного кода модуля.
- **`Core.Guard.is_enum/2` / `in_enum/3` регистрируют исходник enum-модуля как
  `@external_resource` каллера.** Значения инлайнятся в guard литералом, а компилятор этой связи
  не видит: `Code.ensure_compiled/1` даёт максимум export-ребро, и правка `values:` не пересобрала
  бы модуль с guard — тот остался бы на старом множестве. Следствие для потребителя: enum,
  используемый в guard, MUST компилироваться на той же машине, что и каллер (сборка
  с `+deterministic` теряет `:source`, и инкрементальная пересборка каллера не гарантирована).
- **`Core.Es.Event.Codec`: обязательная опция `type:` — тип агрегата.** Wire-имя агрегата и первая
  часть адреса потока событий — подготовка к общей таблице событий, где тип станет колонкой.
  Формат — как у тега (непустая строка); кодек без `type:` — `CompileError`. Конверт события не
  меняется, с префиксом тегов `type:` не сверяется — записанные теги неизменяемы.
  `use Core.Codec.Facade` отказывает в компиляции, если у двух кодеков событий среди `plugins:`
  один `type:`, и называет оба кодека.

  ```elixir
  # было
  use Es.Event.Codec,
    event: User.Event,
    tags: @tag_by_mod

  # стало
  use Es.Event.Codec,
    event: User.Event,
    type: "user",
    tags: @tag_by_mod
  ```
- **`Core.Repo.Pg.Es` → `Core.Repo.Pg.StateStored`; `event_repo:` → обязательная `event_codec:`.**
  Имя `Repo.Pg.Es` читалось как репозиторий event-sourced агрегата, а builder пишет строку
  state-stored агрегата и его события в общую таблицу (пункт про `es_events` в «Ломающих
  изменениях контракта»). `event_codec:` — кодек событий агрегата: его `type:` задаёт поток; DI
  репозитория событий через `Core.Config.repo!/1` ушёл вместе с `event_repo:`. `id:` стала
  обязательной. Сверки на компиляции — `CompileError`: `event_codec:` не кодек событий с `type:`;
  Prim агрегата кодека (новая интроспекция `__es_aggregate_id__/0`) не равен `id:`; событие
  `outbox:` (новая интроспекция `Core.Es.Outbox.__es_event__/0`) не равно семейству кодека; в
  `errors:` нет clause `:version_mismatch`. Макрос занимает `@es_event_codec` вместо
  `@es_event_repo`.

  ```elixir
  # было
  use Repo.Pg.Es,
    # ...
    id: Role.ID,
    event_repo: Role.Event.Repo,
    outbox: Role.Outbox

  # стало
  use Repo.Pg.StateStored,
    # ...
    id: Role.ID,
    event_codec: Role.Event.Codec,
    outbox: Role.Outbox
  ```

## 0.1.0

Первый выпуск: библиотека выделена из приложения, внутри которого жила как
namespace `<App>.Core.*`.

### Изменения контракта относительно встроенной версии

- **Namespace.** `<App>.Core.*` → `Core.*`.
- **Конфигурация переехала под `:core`.** Было `config :my_app, MyApp.Core, dao:, codec:, tz:`
  — стало `config :core, dao:, codec:, tz:`. То же для `Core.Outbox`, `Core.Outbox.Repo`,
  `Core.Security.Secret`.
- **`otp_app` больше не выводится из `Mix.Project`,** а задаётся явно:
  `config :core, otp_app: :my_app`. Он нужен только для резолва DI-ключей доменных
  репозиториев в `use Core.Repo.Pg.Es` — это единственное обращение библиотеки
  к конфигурации не под `:core`.
- **Префикс telemetry-событий вынесен в `telemetry_prefix`** (дефолт `[otp_app()]`)
  и резолвится в рантайме, а не на этапе компиляции. Чтобы сохранить имена метрик
  при переезде, задайте его явно.
- **`codec:` у `Core.Repo.Pg.Schema` резолвится лениво.** Без явной опции фасад берётся
  из `Core.Config.codec()` в рантайме: библиотека компилируется раньше конфигурации
  приложения, поэтому требовать конфиг на этапе компиляции нельзя.
- **`Core.Config.validate!/0`** — новая проверка конфигурации для вызова из `start/2`.
- **Клиенты брокеров стали опциональными зависимостями.** `rabbitmq_stream` и `klife`
  объявлены `optional: true`; `Core.Mq.Stream.{Connection,Reader}` и `Core.Mq.Kafka.Writer`
  компилируются только у тех потребителей, кто объявил соответствующий клиент. Приложению
  с одним брокером больше не нужно тянуть второй (в случае `klife` — вместе с NIF-пакетами
  `crc32cer` / `snappyer`). `Core.Mq.Stream.ensure_available!/0` и
  `Core.Mq.Kafka.ensure_available!/0` — проверки на старте для тех, кто адаптер использует:
  отличают «клиента нет в deps» от «клиент есть, но `core` собран без него»
  (`mix deps.compile core --force`).
- **Boundary-декларация удалена.** Инвариант «Core не знает про домен, приложение
  и web» теперь обеспечен границей OTP-приложений, а не аннотацией.

Инструкция по переводу приложения — в `README.md`.
