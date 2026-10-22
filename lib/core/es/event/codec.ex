defmodule Core.Es.Event.Codec do
  @moduledoc """
  Билдер кодека событий агрегата (`<Aggregate>.Event.Codec`) и его behaviour.

      @tag_by_mod %{Event.Registered => "delivery.registered", Event.Updated => "delivery.updated"}

      use Core.Es.Event.Codec,
        event: MyApp.Domain.<BC>.Delivery.Event,
        type: "delivery",
        tags: @tag_by_mod

  Нагрузку события кодек выводит сам, ручных клауз нет. Кодек агрегата определяет только
  `upcast(old_tag, envelope)` — нагрузку записанного события старого тега → нагрузку следующего
  тега цепочки `upcasts:`; обязателен при непустой карте.

  ## Выводимая нагрузка

  - по полям (`use Core.Es.Event.Payload`) — по её спеке, тем же генератором, что у плагина по
    полям (`Core.Codec.Plugin.Fields`);
  - `use Core.Es.ValueChanged` — спека `old_value` / `new_value` из её `type:` и `nilable:`
    (`Core.Es.ValueChanged.fields/2`);
  - Prim — `codec.dump(payload)` / `codec.load(Prim, wire)`: в конверте голое значение;
  - любая другая struct — так же, целиком через фасад: её wire-форму задаёт плагин её типа (по
    полям или ручной). Что такой плагин есть, проверяет сборка фасада
    (`Core.Codec.Facade.validate_es_payloads!/1`).

  События без нагрузки (`payload: nil` у `use Es.Event`) в конверте несут `nil`.

  ## ПДн-поля нагрузки

  У поля нагрузки по полям с `subject:` (ADR-0073, ADR-0074):

  - `dump` кладёт на место значения `%Core.Es.Personal.Marker{}` — дамп субъекта и wire-значение
    поля; `nil` необязательного поля остаётся `nil`, `%Core.Es.Personal.Destroyed{}` — маркер
    уничтоженного значения. Непустое значение при `nil` в поле-субъекте голова не пропускает;
  - `load` превращает `{"$pd": null}` в `%Core.Es.Personal.Destroyed{}` и редактирует `detail`
    ошибки поля. `{"$pd": null}` в поле без `subject:` — `:invalid_value`, `{"$pd": "<строка>"}`
    в любом поле — `:sealed_personal_value` (`ns: :codec`).

  Поля с `subject:` по событиям — `__es_subjects__/0`.

  `dump_payload/2` или `load_payload/3` в модуле кодека — `CompileError`: нестандартная
  wire-форма нагрузки живёт в плагине её типа, а не в кодеке событий (ADR-0060).

  ## Место в фасаде

  Событие — обычная сущность фасада: `codec.dump(event)` отдаёт **весь** конверт, а
  `codec.load(<Aggregate>.Event, data)` восстанавливает событие по тегу внутри конверта.
  Модуль событий агрегата объявлен семейством (`union:` у `Core.Codec.Plugin`), поэтому
  у фасада не появляется ни реестра тегов, ни функций сверх `dump/1` и `load/2`.

  Отсюда и область уникальности тега: он выбирает модуль **внутри одного кодека**, а не
  во всём приложении. Квалифицировать его именем агрегата (`delivery.registered`) всё
  равно стоит — тег виден в брокере и в event store, где соседствует с чужими; норму на
  всё приложение держит `Core.Es.Event.TagsCase`.

  ## Конверт события

  | Ключ | Значение |
  |---|---|
  | `event_id` | идентификатор события (`Es.Event.ID`) |
  | `type` | wire-тег события |
  | `payload` | нагрузка; `nil` у событий без неё |
  | `aggregate_id` | идентификатор агрегата |
  | `aggregate_version` | версия агрегата целым числом |
  | `at` | момент события |
  | `by` | автор события |
  | `operation_id` | операция (`Es.Event.OperationID`); ключа нет, если операции нет |
  | `session_id` | сеанс инициатора (`Es.Event.SessionID`); ключа нет, если сеанса нет |
  | `basis_id` | основание — операция (`Es.Event.OperationID`); ключа нет, если основания нет |

  Ключи операции, сеанса и основания пишутся только непустыми: у события без них конверт тот же,
  что до их появления (ADR-0081). Отсутствующий ключ читается как `nil`.

  Ключи верхнего уровня строковые — в этой форме конверт лежит в jsonb-колонке outbox и уходит
  в брокер. Наружу форма отдаётся только парой `to_fields/1` / `from_fields/1`: транспорт,
  которому нужны поля по отдельности (event store раскладывает их по колонкам), получает
  плоскую map с atom-ключами и о строковых ключах конверта не знает.

  ## Opts

  - `event:` — объединяющий модуль событий агрегата (семейство для `codec.load/2`)
  - `type:` — тип агрегата: wire-имя, первая часть адреса потока событий (`__es_type__/0`);
    формат — как у тега, в конверт не попадает. Дубль среди плагинов фасада — `CompileError`;
    префикс тегов и уникальность на приложение — `Core.Es.Event.TagsCase`
  - `tags:` — `%{Mod => "wire_tag"}`, SSOT wire-имён событий
  - `upcasts:` — `%{"старый тег" => "новый тег"}` (`__es_upcasts__/0`), необязательная. Событие
    тега-источника при загрузке по семейству до выбора модуля проходит цепочку шагов: нагрузку
    каждого отдаёт `upcast/2`, заголовок конверта не меняется. `CompileError`: источник в
    `tags:`, цель ни в `tags:`, ни источником, цикл

  Prim агрегата и автора не задаются: они выводятся из самих событий
  (`__es_aggregate_id__/0` и `__es_by__/0`), и расхождение между событиями одного
  кодека — `CompileError`. Выведенный Prim агрегата кодек отдаёт тем же `__es_aggregate_id__/0`.

  Макрос занимает в вызывающем модуле имена `@es_event`, `@es_type`, `@es_aggregate_id`, `@es_by`,
  `@es_tag_by_mod`, `@es_mod_by_tag`, `@es_upcasts`, `@es_derived`, `@es_payloadless`, `@es_subjects` и приватные
  `es_dump_payload/2`, `es_load_payload/3`.
  """

  alias Core.Codec.Field
  alias Core.Codec.Plugin.Fields
  alias Core.Error
  alias Core.Es
  alias Core.Helper
  alias Core.Prim
  alias Core.Result
  alias Core.Version

  require Error

  @label "Es.Event.Codec"
  @required_keys ~w(event tags type)a
  @optional_keys ~w(upcasts)a
  @ns :es
  @operation_keys ~w(operation_id session_id basis_id)a

  @typedoc "Конверт события на wire (строковые ключи)."
  @type wire :: %{optional(String.t()) => term()}

  @typedoc "Поля конверта по отдельности — мост к транспортам, хранящим их врозь."
  @type fields :: %{
          required(:id) => term(),
          required(:type) => String.t(),
          required(:payload) => term(),
          required(:aggregate_id) => term(),
          required(:aggregate_version) => term(),
          required(:at) => term(),
          required(:by) => term(),
          optional(:operation_id) => term(),
          optional(:session_id) => term(),
          optional(:basis_id) => term()
        }

  @typedoc """
  Как кодек выводит клаузы нагрузки: по спеке полей или передачей фасаду целиком — Prim фасад
  кодирует встроенно, сущность — плагином её типа.
  """
  @type derivation :: {:fields, [Field.t()]} | :prim | :plugin

  @typedoc "Общая часть события: идентификаторы, версия, автор, момент, операция, сеанс и основание."
  @type header :: %{
          id: Es.Event.ID.t(),
          aggregate_id: struct(),
          version: Version.t(),
          at: Es.Event.At.t(),
          by: struct(),
          operation_id: Es.Event.OperationID.t() | nil,
          session_id: Es.Event.SessionID.t() | nil,
          basis_id: Es.Event.OperationID.t() | nil
        }

  @doc """
  Конверт записанного события старого тега → нагрузка следующего тега цепочки `upcasts:`.

  Тег шага берётся из карты, заголовок конверта колбэк только читает; ошибку формы
  возвращённой нагрузки ловит загрузка нагрузки.
  """
  @callback upcast(old_tag :: String.t(), envelope :: wire()) :: term()

  @optional_callbacks upcast: 2

  @doc "Объявить кодек событий агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    event = Helper.Opts.module!(lit, :event, @label)

    # `tags:` и `upcasts:` уходят в тело модуля как есть: значение атрибута (`@tag_by_mod`) на
    # этапе разворачивания макроса ещё не записано, и прочитать его оттуда нельзя.
    tags = Keyword.fetch!(opts, :tags)
    type = Keyword.fetch!(opts, :type)
    upcasts = Keyword.get(opts, :upcasts, quote(do: %{}))

    quote do
      @behaviour Core.Es.Event.Codec

      @es_event unquote(event)
      @es_type Core.Es.Event.Codec.type!(unquote(type))
      @es_tag_by_mod Core.Es.Event.Codec.tags!(unquote(tags))
      @es_mod_by_tag Core.Es.Event.Codec.mods!(@es_tag_by_mod)
      @es_upcasts Core.Es.Event.Codec.upcasts!(unquote(upcasts), @es_mod_by_tag)
      @es_aggregate_id Core.Es.Event.Codec.derive!(@es_tag_by_mod, :__es_aggregate_id__)
      @es_by Core.Es.Event.Codec.derive!(@es_tag_by_mod, :__es_by__)

      use Core.Codec.Plugin,
        types: Map.keys(@es_tag_by_mod),
        union: @es_event

      @typedoc "Событие агрегата."
      @type event :: unquote(event).t()

      @typedoc "Нагрузка события на wire."
      @type wire_payload :: map() | String.t() | number() | boolean() | list() | nil

      @doc false
      @spec __es_type__() :: String.t()

      def __es_type__, do: @es_type

      @doc false
      @spec __es_aggregate_id__() :: module()

      def __es_aggregate_id__, do: @es_aggregate_id

      @doc false
      @spec __es_mods__() :: [module()]

      def __es_mods__, do: Map.keys(@es_tag_by_mod)

      @doc false
      @spec __es_upcasts__() :: %{optional(String.t()) => String.t()}

      def __es_upcasts__, do: @es_upcasts

      @doc "Wire-тег события по struct или модулю."
      @spec type(event() | module()) :: String.t()

      def type(%mod{}), do: type(mod)

      def type(mod) when is_atom(mod) and is_map_key(@es_tag_by_mod, mod) do
        Map.fetch!(@es_tag_by_mod, mod)
      end

      @doc "Множество wire-тегов событий агрегата."
      @spec types() :: MapSet.t(String.t())

      def types, do: MapSet.new(Map.values(@es_tag_by_mod))

      @doc "Wire-тег → модуль события."
      @spec mod_by_tag(String.t()) :: {:ok, module()} | :error

      def mod_by_tag(tag) when is_binary(tag), do: Map.fetch(@es_mod_by_tag, tag)

      @doc "Событие → конверт wire."
      @spec dump(event(), module()) :: Core.Es.Event.Codec.wire()

      @impl true
      def dump(%mod{} = event, codec) when is_map_key(@es_tag_by_mod, mod) do
        Core.Es.Event.Codec.dump_envelope(event, type(mod), es_dump_payload(event, codec), codec)
      end

      @doc """
      Конверт → событие: по модулю события либо по семейству `#{inspect(unquote(event))}`.

      В варианте с семейством модуль выбирается по тегу внутри данных.
      """
      @spec load(module(), Core.Es.Event.Codec.wire(), module()) ::
              Core.Result.t(event())

      @impl true
      def load(@es_event, data, codec) when is_atom(codec) do
        Core.Es.Event.Codec.load_by_tag(data, @es_mod_by_tag, @es_upcasts, __MODULE__, codec)
      end

      def load(mod, data, codec)
          when is_map_key(@es_tag_by_mod, mod) and is_map(data) and is_atom(codec) do
        with {:ok, header} <-
               Core.Es.Event.Codec.load_header(data, @es_aggregate_id, @es_by, __MODULE__),
             {:ok, payload} <- es_load_payload(mod, field(data, :payload), codec) do
          {:ok, Core.Es.Event.Codec.build(mod, payload, header)}
        end
      end

      @es_derived Core.Es.Event.Codec.derived(@es_tag_by_mod)
      @es_payloadless Core.Es.Event.Codec.payloadless(@es_tag_by_mod)
      @es_subjects Core.Es.Event.Codec.subjects(@es_derived)

      @doc """
      Поля нагрузки с `subject:` по модулю события: `[{поле, субъект}]`, субъект — `:aggregate_id`
      или поле той же нагрузки. События без таких полей в карте нет.
      """
      @spec __es_subjects__() :: %{optional(module()) => [{atom(), atom()}, ...]}

      def __es_subjects__, do: @es_subjects

      unquote(derived_clauses())

      @before_compile Core.Es.Event.Codec
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    upcasts = Module.get_attribute(env.module, :es_upcasts)

    refute_manual_payload!(env)

    if map_size(upcasts) > 0,
      do: ensure_defined!(env.module, {:upcast, 2}, "у кодека непустые upcasts:", env)
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec type!(term()) :: String.t()

  def type!(type) when is_binary(type) and type != "", do: type

  def type!(other) do
    raise CompileError,
      description:
        "#{@label}: type: ожидается непустая строка, как у тега события, получено " <>
          inspect(other)
  end

  @doc false
  @spec tags!(term()) :: %{optional(module()) => String.t()}

  def tags!(tags) when is_map(tags) and map_size(tags) > 0 do
    Enum.each(tags, &validate_tag!/1)
    tags
  end

  def tags!(other) do
    raise CompileError,
      description:
        "#{@label}: tags: ожидается непустая map %{Модуль => \"тег\"}, получено " <>
          inspect(other)
  end

  @doc false
  @spec mods!(%{optional(module()) => String.t()}) :: %{optional(String.t()) => module()}

  def mods!(tags) when is_map(tags), do: Enum.reduce(tags, %{}, &put_unique_tag!/2)

  @doc false
  @spec upcasts!(term(), %{optional(String.t()) => module()}) ::
          %{optional(String.t()) => String.t()}

  def upcasts!(upcasts, mod_by_tag) when is_map(upcasts) and is_map(mod_by_tag) do
    Enum.each(upcasts, &validate_upcast!(&1, upcasts, mod_by_tag))
    Enum.each(Map.keys(upcasts), &ensure_acyclic!(&1, upcasts, []))
    upcasts
  end

  def upcasts!(other, _mod_by_tag) do
    raise CompileError,
      description:
        ~s(#{@label}: upcasts: ожидается map %{"старый тег" => "новый тег"}, получено ) <>
          inspect(other)
  end

  @doc """
  Вывести Prim агрегата или автора из самих событий кодека.

  Дублировать их опцией `use` значило бы завести второй источник истины, который никто
  не сверяет: у событий одного агрегата они и так одинаковы, а расхождение — ошибка.
  """
  @spec derive!(%{optional(module()) => String.t()}, atom()) :: module()

  def derive!(tags, fun) when is_map(tags) and is_atom(fun) do
    tags
    |> Map.keys()
    |> Enum.map(&{&1, apply(&1, fun, [])})
    |> Enum.uniq_by(&elem(&1, 1))
    |> case do
      [{_mod, value}] ->
        value

      pairs ->
        raise CompileError,
          description: "#{@label}: события кодека объявлены с разными #{fun}: #{inspect(pairs)}"
    end
  end

  # Клаузы нагрузки кодек выводит для каждого события с нагрузкой: нагрузка по полям и
  # `Es.ValueChanged` несут свою спеку, Prim и сущность кодирует фасад целиком (сущность — плагином
  # её типа). Ручной код здесь был бы вторым источником wire.
  @doc false
  @spec derived(%{optional(module()) => String.t()}) :: [{module(), module(), derivation()}]

  def derived(tags) when is_map(tags) do
    for event <- Enum.sort(Map.keys(tags)),
        payload = event.__es_payload__(),
        not is_nil(payload),
        do: {event, payload, derivation(payload)}
  end

  @doc false
  @spec subjects([{module(), module(), derivation()}]) :: %{optional(module()) => [{atom(), atom()}, ...]}

  def subjects(derived) when is_list(derived) do
    for {event, _payload, {:fields, fields}} <- derived,
        pairs = Field.subjects(fields),
        pairs != [],
        into: %{},
        do: {event, pairs}
  end

  @doc false
  @spec payloadless(%{optional(module()) => String.t()}) :: [module()]

  def payloadless(tags) when is_map(tags),
    do: Enum.filter(Enum.sort(Map.keys(tags)), &is_nil(&1.__es_payload__()))

  @doc """
  События с нагрузкой-сущностью и её тип: такую нагрузку кодирует плагин фасада.

  Нагрузка по полям, `Es.ValueChanged` и Prim сюда не входят: первые две кодек выводит по их
  спеке, Prim фасад кодирует встроенно.
  """
  @spec plugin_payloads([module()]) :: [{module(), module()}]

  def plugin_payloads(events) when is_list(events) do
    for event <- events,
        payload = event.__es_payload__(),
        not is_nil(payload),
        derivation(payload) == :plugin,
        do: {event, payload}
  end

  @doc false
  @spec dump_payload_clause(module(), module(), derivation()) :: {[Macro.t()], Macro.t(), Macro.t()}

  def dump_payload_clause(event, payload, {:fields, fields}),
    do:
      {Fields.payload_dump_args(event, payload, fields), Fields.payload_dump_guard(fields),
       Fields.payload_dump_body(fields)}

  def dump_payload_clause(event, payload, kind) when kind in [:prim, :plugin] do
    {value, codec} = {var(:payload), var(:codec)}

    {[quote(generated: true, do: %unquote(event){payload: %unquote(payload){} = unquote(value)}), codec],
     quote(generated: true, do: is_atom(unquote(codec))),
     quote(generated: true, do: unquote(codec).dump(unquote(value)))}
  end

  @doc false
  @spec load_payload_clause(module(), module(), derivation()) :: {[Macro.t()], Macro.t(), Macro.t()}

  def load_payload_clause(event, payload, {:fields, fields}),
    do: {Fields.load_args(event), Fields.load_guard(), Fields.payload_load_body(payload, fields)}

  def load_payload_clause(event, payload, kind) when kind in [:prim, :plugin] do
    {value, wire, codec} = {var(:payload), var(:wire), var(:codec)}

    body =
      quote generated: true do
        case unquote(codec).load(unquote(payload), unquote(wire)) do
          {:ok, %unquote(payload){} = unquote(value)} -> {:ok, unquote(value)}
          {:error, reason} -> {:error, reason}
        end
      end

    {[event, wire, codec], quote(generated: true, do: is_atom(unquote(codec))), body}
  end

  @doc """
  Событие → конверт wire.

  `type` и `payload` приходят от кодека агрегата: тег знает только он, нагрузку он выводит
  сам.
  """
  @spec dump_envelope(struct(), String.t(), term(), module()) :: wire()

  def dump_envelope(event, type, payload, codec) when is_binary(type) and is_atom(codec) do
    %{
      "event_id" => codec.dump(event.id),
      "type" => type,
      "payload" => payload,
      "aggregate_id" => codec.dump(event.aggregate_id),
      "aggregate_version" => Version.value(event.aggregate_version),
      "at" => codec.dump(event.at),
      "by" => codec.dump(event.by)
    }
    |> put_present(@operation_keys, &dump_present(Map.fetch!(event, &1), codec))
  end

  @doc """
  Конверт → событие по тегу внутри данных (`type`).

  Тег-источник `upcasts` сначала проходит цепочку апкастов: на каждом шаге `upcast/2`
  кодека агрегата отдаёт нагрузку следующего тега, заголовок конверта остаётся как есть.
  Модуль выбирается по тегу конца цепочки.

  Разбор safe с обеих сторон: сообщение переживает код, который его писал, поэтому
  чужой формат (`:invalid_envelope`) и снятый с обращения тип (`:unknown_event_type`)
  обязаны стать доменной ошибкой у подписчика, а не падением.
  """
  @spec load_by_tag(
          term(),
          %{optional(String.t()) => module()},
          %{optional(String.t()) => String.t()},
          module(),
          module()
        ) :: Result.t(struct())

  def load_by_tag(data, mod_by_tag, upcasts, module, codec)
      when is_map(data) and is_map(mod_by_tag) and is_map(upcasts) do
    with {:ok, tag} <- fetch_tag(data, module),
         {tag, data} = upcast_chain(tag, data, upcasts, module),
         {:ok, mod} <- fetch_mod(mod_by_tag, tag, module) do
      module.load(mod, data, codec)
    end
  end

  # Из брокера приходит `Jason.decode!/1` чего угодно: не-map — это сообщение не того
  # формата, а не повод уронить подписчика.
  def load_by_tag(_data, mod_by_tag, upcasts, module, _codec)
      when is_map(mod_by_tag) and is_map(upcasts) do
    {:error, missing(module, :type)}
  end

  @doc """
  Общие поля конверта → header события.

  Ключи читаются и в atom-, и в string-форме (`Core.Helper.Map.field/2`): из брокера конверт
  приходит после `Jason.decode/1`, то есть со строковыми ключами. `module` — кодек агрегата:
  ошибка обязана указывать на него, а не на билдер.
  """
  @spec load_header(wire(), module(), module(), module()) :: Result.t(header())

  def load_header(data, aggregate_id_mod, by_mod, module)
      when is_map(data) and is_atom(aggregate_id_mod) and is_atom(by_mod) and is_atom(module) do
    with {:ok, aggregate_id} <- load_field(data, :aggregate_id, aggregate_id_mod, module),
         {:ok, version} <- load_field(data, :aggregate_version, Version, module),
         {:ok, by} <- load_field(data, :by, by_mod, module),
         {:ok, at} <- load_field(data, :at, Es.Event.At, module),
         {:ok, id} <- load_field(data, :event_id, Es.Event.ID, module),
         {:ok, operation_id} <- load_optional(data, :operation_id, Es.Event.OperationID),
         {:ok, session_id} <- load_optional(data, :session_id, Es.Event.SessionID),
         {:ok, basis_id} <- load_optional(data, :basis_id, Es.Event.OperationID) do
      {:ok,
       %{
         id: id,
         aggregate_id: aggregate_id,
         version: version,
         at: at,
         by: by,
         operation_id: operation_id,
         session_id: session_id,
         basis_id: basis_id
       }}
    end
  end

  @doc "Модуль события + нагрузка + header → событие."
  @spec build(module(), struct() | nil, header()) :: struct()

  def build(mod, payload, %{} = header) when is_atom(mod) do
    event =
      case mod.__es_payload__() do
        nil ->
          mod.new(header.aggregate_id, header.version, header.by, header.at, header.id)

        _payload_mod ->
          mod.new(payload, header.aggregate_id, header.version, header.by, header.at, header.id)
      end

    %{event | operation_id: header.operation_id, session_id: header.session_id, basis_id: header.basis_id}
  end

  @doc """
  Конверт → поля по отдельности (atom-ключи).

  Мост для транспорта, который хранит поля события врозь: строковые ключи конверта не
  покидают кодека, а знание о колонках (`by_id` и прочее) в него не попадает.
  """
  @spec to_fields(wire()) :: fields()

  def to_fields(data) when is_map(data) do
    %{
      id: Helper.Map.field(data, :event_id),
      type: Helper.Map.field(data, :type),
      payload: Helper.Map.field(data, :payload),
      aggregate_id: Helper.Map.field(data, :aggregate_id),
      aggregate_version: Helper.Map.field(data, :aggregate_version),
      at: Helper.Map.field(data, :at),
      by: Helper.Map.field(data, :by),
      operation_id: Helper.Map.field(data, :operation_id),
      session_id: Helper.Map.field(data, :session_id),
      basis_id: Helper.Map.field(data, :basis_id)
    }
  end

  @doc """
  Поля по отдельности → конверт: обратная операция к `to_fields/1`.

  Операция, сеанс и основание пишутся только непустыми — как в `dump_envelope/4`; поля без них —
  конверт без этих ключей.
  """
  @spec from_fields(fields()) :: wire()

  def from_fields(fields) when is_map(fields) do
    %{
      "event_id" => fields.id,
      "type" => fields.type,
      "payload" => fields.payload,
      "aggregate_id" => fields.aggregate_id,
      "aggregate_version" => fields.aggregate_version,
      "at" => fields.at,
      "by" => fields.by
    }
    |> put_present(@operation_keys, &Map.get(fields, &1))
  end

  # ---

  defp validate_tag!({mod, tag}) when is_atom(mod) and is_binary(tag) and tag != "" do
    Code.ensure_compiled!(mod)

    unless function_exported?(mod, :__es_payload__, 0) do
      raise CompileError,
        description: "#{@label}: tags: #{inspect(mod)} не объявлен через `use Core.Es.Event`"
    end

    :ok
  end

  defp validate_tag!(other) do
    raise CompileError,
      description:
        "#{@label}: tags: ожидается {модуль события, непустая строка}, получено " <>
          Macro.to_string(other)
  end

  defp put_unique_tag!({mod, tag}, acc) do
    case Map.fetch(acc, tag) do
      {:ok, other} ->
        raise CompileError,
          description: "#{@label}: tags: дубликат тега #{inspect(tag)} у #{inspect(mod)} и #{inspect(other)}"

      :error ->
        Map.put(acc, tag, mod)
    end
  end

  defp validate_upcast!({from, to} = pair, _upcasts, _mod_by_tag)
       when not is_binary(from) or from == "" or not is_binary(to) or to == "" do
    raise CompileError,
      description:
        ~s(#{@label}: upcasts: ожидается пара непустых строк {"старый тег", "новый тег"}, ) <>
          "получено #{inspect(pair)}"
  end

  defp validate_upcast!({from, _to}, _upcasts, mod_by_tag) when is_map_key(mod_by_tag, from) do
    raise CompileError,
      description:
        "#{@label}: upcasts: источник #{inspect(from)} объявлен в tags: — " <>
          "записанный тег читает либо модуль, либо апкаст"
  end

  defp validate_upcast!({from, to}, upcasts, mod_by_tag)
       when not is_map_key(mod_by_tag, to) and not is_map_key(upcasts, to) do
    raise CompileError,
      description:
        "#{@label}: upcasts: цель #{inspect(to)} не объявлена ни в tags:, " <>
          "ни источником upcasts: (апкаст из #{inspect(from)})"
  end

  defp validate_upcast!(_pair, _upcasts, _mod_by_tag), do: :ok

  defp ensure_acyclic!(tag, upcasts, path) do
    cond do
      tag in path ->
        cycle = Enum.map_join(Enum.reverse([tag | path]), " → ", &inspect/1)
        raise CompileError, description: "#{@label}: upcasts: цикл #{cycle}"

      is_map_key(upcasts, tag) ->
        ensure_acyclic!(Map.fetch!(upcasts, tag), upcasts, [tag | path])

      true ->
        :ok
    end
  end

  defp derivation(payload) do
    Code.ensure_compiled!(payload)

    cond do
      function_exported?(payload, :__es_payload_fields__, 0) -> {:fields, payload.__es_payload_fields__()}
      function_exported?(payload, :__es_value_changed__, 0) -> {:fields, value_changed_fields(payload)}
      Prim.prim?(payload) -> :prim
      true -> :plugin
    end
  end

  defp value_changed_fields(payload) do
    [type: type, nilable: nilable?] = payload.__es_value_changed__()
    Es.ValueChanged.fields(type, nilable?)
  end

  defp var(name), do: Macro.var(name, __MODULE__)

  # Клаузы `unquote` вставляют фрагментами: события известны только в теле модуля (`@es_derived`).
  defp derived_clauses do
    quote unquote: false do
      for {event, payload, derivation} <- @es_derived do
        {args, guard, body} = Core.Es.Event.Codec.dump_payload_clause(event, payload, derivation)

        defp es_dump_payload(unquote_splicing(args)) when unquote(guard), do: unquote(body)
      end

      for event <- @es_payloadless do
        defp es_dump_payload(%unquote(event){}, _codec), do: nil
      end

      for {event, payload, derivation} <- @es_derived do
        {args, guard, body} = Core.Es.Event.Codec.load_payload_clause(event, payload, derivation)

        defp es_load_payload(unquote_splicing(args)) when unquote(guard), do: unquote(body)
      end

      for event <- @es_payloadless do
        defp es_load_payload(unquote(event), _wire, _codec), do: {:ok, nil}
      end
    end
  end

  # Нагрузку события кодек выводит всегда, а нестандартная wire-форма — дело плагина её типа: ручная
  # клауза в кодеке событий была бы вторым источником wire.
  defp refute_manual_payload!(env) do
    case manual_payload_funs(env.module) do
      [] ->
        :ok

      [{_fun, line} | _rest] = funs ->
        listed = Enum.map_join(funs, ", ", fn {fun, line} -> "#{fun} (строка #{line})" end)

        raise CompileError,
          description:
            "#{@label}: #{inspect(env.module)} объявляет #{listed} — нагрузку события кодирует " <>
              "плагин её типа: перенесите форму в Codec-плагин нагрузки (или объявите нагрузку " <>
              "`use Core.Es.Event.Payload`) и удалите клаузы",
          file: env.file,
          line: line || env.line
    end
  end

  defp manual_payload_funs(module) do
    for {fun, arity} <- [dump_payload: 2, load_payload: 3],
        {:v1, _kind, _meta, [{meta, _args, _guards, _body} | _rest]} <- [Module.get_definition(module, {fun, arity})],
        do: {"#{fun}/#{arity}", meta[:line]}
  end

  defp ensure_defined!(mod, {fun, arity}, reason, env) do
    unless Module.defines?(mod, {fun, arity}) do
      raise CompileError,
        description: "#{@label}: #{inspect(mod)} обязан объявить #{fun}/#{arity} — #{reason}",
        file: env.file,
        line: env.line
    end
  end

  defp fetch_tag(data, module) do
    case Helper.Map.field(data, :type) do
      tag when is_binary(tag) -> {:ok, tag}
      _other -> {:error, missing(module, :type)}
    end
  end

  defp upcast_chain(tag, data, upcasts, module) do
    case Map.fetch(upcasts, tag) do
      {:ok, next} ->
        payload = module.upcast(tag, data)

        data =
          data
          |> put_field(:type, next)
          |> put_field(:payload, payload)

        upcast_chain(next, data, upcasts, module)

      :error ->
        {tag, data}
    end
  end

  defp put_field(data, key, value) do
    case Helper.Map.key(data, key) do
      {:ok, found} -> Map.put(data, found, value)
      :error -> Map.put(data, Atom.to_string(key), value)
    end
  end

  defp fetch_mod(mod_by_tag, tag, module) do
    case Map.fetch(mod_by_tag, tag) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, unknown_type(module, tag)}
    end
  end

  defp load_field(data, key, mod, module) do
    case Helper.Map.fetch(data, key) do
      {:ok, raw} -> mod.new(raw)
      :error -> {:error, missing(module, key)}
    end
  end

  # Пустое значение ключа не пишется: у события без операции конверт прежний байт в байт.
  defp put_present(data, keys, value_of) do
    Enum.reduce(keys, data, fn key, acc ->
      case value_of.(key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  defp dump_present(nil, _codec), do: nil
  defp dump_present(value, codec), do: codec.dump(value)

  # Ключ операции, сеанса или основания необязателен: конверт, записанный до их появления
  # (ADR-0081), их не несёт.
  defp load_optional(data, key, mod) do
    case Helper.Map.field(data, key) do
      nil -> {:ok, nil}
      raw -> mod.new(raw)
    end
  end

  # Отсутствующий ключ конверта — не «невалидное значение», а сообщение не того формата:
  # payload у событий без нагрузки законно отсутствует, всё остальное обязано быть.
  defp missing(module, key) do
    Error.domain(module,
      code: :invalid_envelope,
      ns: @ns,
      message: "Конверт события не содержит обязательного поля",
      detail: %{field: key}
    )
  end

  defp unknown_type(module, tag) do
    Error.domain(module,
      code: :unknown_event_type,
      ns: @ns,
      message: "Неизвестный тип события",
      detail: tag
    )
  end
end
