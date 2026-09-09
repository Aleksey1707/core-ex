# Changelog

## Не выпущено

### Ломающие изменения контракта

- **Write-путь возвращает входной агрегат, а не строку из БД.** `Repo.Pg.insert/4` и `update/4`
  больше не декодируют записанную строку через `to_entity`: возвращается тот же агрегат, что
  пришёл на вход, и он же уходит эталоном в `Repo.Sc` регистрацией после commit — эталон стал
  делом того, кто пишет, а не call site. Смысл возврата теперь один на оба пути: состояние, от
  которого мутируют дальше. Удалены `Repo.Pg.write_insert/4` и `Repo.Pg.write_update/4` — без
  decode они дублировали `insert/4` и `update/4`; `Repo.Pg.Es` зовёт обычные методы, а агрегат с
  очищенными `events` собирает **до** записи строки. Мотивация и отвергнутые варианты —
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
- **`Core.Es.Event.Codec`: колбэки вместо приватных клоуз, опции `event:` + `tags:`.**
  `dump_payload/2` и `load_payload/3` стали callback'ами behaviour (`@impl true`, `def`, не
  `defp`), и `load_payload` возвращает `%Payload{}`, а не собранное событие: конверт разбирает
  и событие собирает билдер. Аргумент `envelope` и хелперы `event/2` / `event/3` пропали вместе
  с модулем `Core.Es.Event.Codec.Helper`. События без нагрузки клоуз не требуют вовсе. Опции
  `aggregate_id:` и `by:` сняты — билдер выводит их из самих событий; разные Prim у событий
  одного кодека — `CompileError`. Неизвестный тег теперь `:unknown_event_type` (`ns: :es`,
  модуль — кодек агрегата) вместо `:unknown_tagged_type` фасада.
- **`Core.Es.Outbox.Envelope` удалён** (был добавлен в этом же невыпущенном цикле): обе стороны
  формата конверта живут в `Core.Es.Event.Codec`. Наружу отдаётся только пара `to_fields/1` /
  `from_fields/1` — для транспорта, который хранит поля события врозь. Оттуда же `Es.Outbox`
  берёт ключ, имя и заголовки записи, поэтому у его опции `event:` снято требование `name/1`.
- **Опции макросов:** у `Core.Es.Event.Repo.Pg.Schema` сняты `event_codec:`, `aggregate_id:`
  и `by:` (схема больше не знает ни кодека агрегата, ни его Prim). Clause `:unknown_event_type`
  в каталогах `<Aggregate>.Errors` больше не вызывается — ошибку строит кодек.
- **`Core.Outbox.Name`** принимает тот же набор символов, что `Topic` (`[a-zA-Z0-9._-]`): имя
  сообщения — это wire-тег события, а он квалифицирован. Расширение множества значений,
  старые имена проходят.
- **`Core.Config.validate!/0`** проверяет у фасада `dump/1`, `load/2` и `load!/2` (было
  `dump/1`, `load/2`, `prim/0`).

  Форма конверта события, колонки таблиц событий и outbox не изменились — данные мигрировать
  не нужно. Миграция кода потребителя:

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

  `EventCompatCase` грузит фикстуру целиком через семейство:
  `InCodec.load(<Aggregate>.Event, fixture)`.
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
- **`Core.Helper.Opts.atom!/3`** — чтение опции-атома (не `nil`) с `CompileError` вместо тихого
  прохода значения другого типа.

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
- **`Repo.Pg.Es` больше не читает конфигурацию на компиляции.** `event_repo:` резолвится
  через `Core.Config.repo!/1`, реализация outbox — вызовом `Core.Config.outbox_repo/0`
  в момент flush; атрибут `@es_outbox_repo` снят. Доступ к app-env потребителя целиком
  сжат в `Core.Config`, и главный инвариант из `10-architecture.md` проверяется линтером
  `make boundary-check` (`scripts/boundary_lint.exs`), а не грепом на ревью. Тот же скрипт
  проверяет и сторону потребителя — `boundary_lint.exs --consumer lib test` ловит прямой
  `compile_env` на модуль-behaviour; потребитель зовёт его из `deps/core/scripts/`.
- **`codec:` и `repo:` без явной опции резолвятся в рантайме.** `Es.Outbox`, `Repo.Pg`,
  `Repo.Pg.Es`, `Es.Event.Repo.Pg` и `Es.Event.Repo.Pg.Schema` больше не читают
  `Core.Config` в момент разворачивания макроса — как это уже делал `Repo.Pg.Schema`.
  Потребитель, задающий `dao:` / `codec:` в `runtime.exs`, компилируется без обходных
  путей; поведение при явно заданной опции не изменилось.
- **Снятые атрибуты макросов.** `Es.Outbox` больше не занимает `@es_codec`,
  `Es.Event.Repo.Pg` — `@es_dao` и `@es_codec`, `Es.Event.Repo.Pg.Schema` — `@es_codec`:
  вместо них генерируются приватные `es_codec/0` и `es_dao/0`. Правка нужна только тому,
  кто ссылался на эти атрибуты из собственного кода модуля.
- **`Core.Guard.is_enum/2` / `in_enum/3` регистрируют исходник enum-модуля как
  `@external_resource` каллера.** Значения инлайнятся в guard литералом, а компилятор этой связи
  не видит: `Code.ensure_compiled/1` даёт максимум export-ребро, и правка `values:` не пересобрала
  бы модуль с guard — тот остался бы на старом множестве. Следствие для потребителя: enum,
  используемый в guard, MUST компилироваться на той же машине, что и каллер (сборка
  с `+deterministic` теряет `:source`, и инкрементальная пересборка каллера не гарантирована).

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
