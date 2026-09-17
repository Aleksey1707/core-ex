defmodule Core.Es.Event.Codec do
  @moduledoc """
  Билдер кодека событий агрегата (`<Aggregate>.Event.Codec`) и его behaviour.

      @tag_by_mod %{Event.Registered => "delivery.registered", Event.Updated => "delivery.updated"}

      use Core.Es.Event.Codec,
        event: MyApp.Domain.<BC>.Common.Delivery.Event,
        type: "delivery",
        tags: @tag_by_mod

  Кодек агрегата определяет только специфику нагрузки:

  - `dump_payload(event, codec)` — нагрузка события в wire;
  - `load_payload(mod, wire, codec)` — wire → `%Payload{}` (не событие: конверт
    разбирает и событие собирает билдер);
  - `upcast(old_tag, envelope)` — нагрузка записанного события старого тега → нагрузка
    следующего тега цепочки `upcasts:`; обязателен при непустой карте.

  События без нагрузки (`payload: nil` у `use Es.Event`) клоуз не требуют вовсе —
  билдер знает о них из `__es_payload__/0`.

  ## Черновик события

  Элемент результата `decide/2` агрегата строится конструктором кодека — `draft`, который
  билдер генерирует по `tags:`:

  - `draft(Event.Mod, %Event.Mod.Payload{} = payload)` → `{Event.Mod, payload}` — clause на
    каждое событие с нагрузкой;
  - `draft(Event.Mod)` → `Event.Mod` — clause на каждое событие без нагрузки.

  Пара «событие — модуль нагрузки» стоит в голове clause литералами, поэтому событие не из
  `tags:`, нагрузку другого события и событие с нагрузкой без неё ловит вывод типов при сборке
  вызывающего. Модуль нагрузки, общий у нескольких событий кодека, ошибкой не является: событие
  задаёт первый аргумент. Возвращается прежний элемент `Core.Es.Aggregate.result()`, так что
  `Core.Es.Aggregate.Test.given/3` и тесты, сравнивающие результат `decide/2` с кортежами, не
  меняются.

  Конструктор живёт в кодеке, а не в семействе `<Aggregate>.Event`: семейство и кодек ждут
  компиляции друг друга. Вызов `draft` из `decide/2` — ребро runtime, цикла компиляции он не
  добавляет.

  ## Проверки нагрузки

  Сборка кодека проверяет колбэки нагрузки по `tags:`: на каждое событие с нагрузкой макрос
  генерирует функции-проверки (`Core.Es.Check`):

  - `"dump_payload/2 принимает <Event>"` — литеральный вызов
    `dump_payload(%Event.Mod{payload: %Payload{}} = event, codec)`;
  - `"load_payload/3 отдаёт нагрузку <Payload>"` — вызов `load_payload(Event.Mod, wire, codec)` и
    сопоставление результата с `{:ok, %Payload{}}` и `{:error, _}`. У модуля нагрузки, общего у
    нескольких событий, функция одна — с clause на каждое событие.

  Предупреждение компилятора указывает на строку `use`, а имя функции в нём называет нарушенное
  утверждение. Ловятся:

  - событие с нагрузкой без clause `dump_payload/2` или `load_payload/3`;
  - `load_payload/3`, отдающий нагрузку другого события, — литералом или конструктором
    `Payload.new`.

  Clause `{:error, _}` размечена `generated: true`: у `load_payload/3`, который никогда не
  ошибается, она недостижима, но предупреждения не даёт. Кодек без событий с нагрузкой проверок
  нагрузки не получает.

  ## Место в фасаде

  Событие — обычная сущность фасада: `codec.dump(event)` отдаёт **весь** конверт, а
  `codec.load(<Aggregate>.Event, data)` восстанавливает событие по тегу внутри конверта.
  Модуль событий агрегата объявлен семейством (`union:` у `Core.Codec.Plugin`), поэтому
  у фасада не появляется ни реестра тегов, ни функций сверх `dump/1` и `load/2`.

  Отсюда и область уникальности тега: он выбирает модуль **внутри одного кодека**, а не
  во всём приложении. Квалифицировать его именем агрегата (`delivery.registered`) всё
  равно стоит — тег виден в брокере и в event store, где соседствует с чужими.

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

  Ключи верхнего уровня строковые — в этой форме конверт лежит в jsonb-колонке outbox и уходит
  в брокер. Наружу форма отдаётся только парой `to_fields/1` / `from_fields/1`: транспорт,
  которому нужны поля по отдельности (event store раскладывает их по колонкам), получает
  плоскую map с atom-ключами и о строковых ключах конверта не знает.

  ## Opts

  - `event:` — объединяющий модуль событий агрегата (семейство для `codec.load/2`)
  - `type:` — тип агрегата: wire-имя, первая часть адреса потока событий (`__es_type__/0`);
    формат — как у тега, в конверт не попадает, с префиксом тегов не сверяется. Дубль среди
    плагинов фасада — `CompileError`
  - `tags:` — `%{Mod => "wire_tag"}`, SSOT wire-имён событий
  - `upcasts:` — `%{"старый тег" => "новый тег"}` (`__es_upcasts__/0`), необязательная. Событие
    тега-источника при загрузке по семейству до выбора модуля проходит цепочку шагов: нагрузку
    каждого отдаёт `upcast/2`, заголовок конверта не меняется. `CompileError`: источник в
    `tags:`, цель ни в `tags:`, ни источником, цикл

  Prim агрегата и автора не задаются: они выводятся из самих событий
  (`__es_aggregate_id__/0` и `__es_by__/0`), и расхождение между событиями одного
  кодека — `CompileError`. Выведенный Prim агрегата кодек отдаёт тем же `__es_aggregate_id__/0`.

  Макрос занимает в вызывающем модуле имена `@es_event`, `@es_type`, `@es_aggregate_id`, `@es_by`,
  `@es_tag_by_mod`, `@es_mod_by_tag`, `@es_upcasts`, `@es_use_line`, `draft/1`, `draft/2`,
  функций-проверок нагрузки и приватные `es_dump_payload/2`, `es_load_payload/3`.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Helper
  alias Core.Version

  require Error

  @label "Es.Event.Codec"
  @required_keys ~w(event tags type)a
  @optional_keys ~w(upcasts)a
  @ns :es

  @typedoc "Конверт события на wire (строковые ключи)."
  @type wire :: %{optional(String.t()) => term()}

  @typedoc "Поля конверта по отдельности — мост к транспортам, хранящим их врозь."
  @type fields :: %{
          id: term(),
          type: String.t(),
          payload: term(),
          aggregate_id: term(),
          aggregate_version: term(),
          at: term(),
          by: term()
        }

  @typedoc "Общая часть события: идентификаторы, версия, автор и момент."
  @type header :: %{
          id: Es.Event.ID.t(),
          aggregate_id: struct(),
          version: Version.t(),
          at: Es.Event.At.t(),
          by: struct()
        }

  @doc "Нагрузка события → wire."
  @callback dump_payload(event :: struct(), codec :: module()) :: term()

  @doc "Модуль события + wire-нагрузка → `%Payload{}`."
  @callback load_payload(mod :: module(), wire :: term(), codec :: module()) ::
              {:ok, struct()} | {:error, Error.t()}

  @doc """
  Конверт записанного события старого тега → нагрузка следующего тега цепочки `upcasts:`.

  Тег шага берётся из карты, заголовок конверта колбэк только читает; ошибку формы
  возвращённой нагрузки ловит `load_payload/3`.
  """
  @callback upcast(old_tag :: String.t(), envelope :: wire()) :: term()

  @optional_callbacks dump_payload: 2, load_payload: 3, upcast: 2

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
              {:ok, event()} | {:error, Core.Error.t()}

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

      # Клоузы нагрузки существуют, только если её кто-то из событий несёт: у кодека,
      # где все события без нагрузки, вызов `dump_payload/2` был бы обращением к
      # функции, которой неоткуда взяться.
      if Core.Es.Event.Codec.with_payload?(@es_tag_by_mod) do
        defp es_dump_payload(%mod{} = event, codec) do
          if is_nil(mod.__es_payload__()), do: nil, else: dump_payload(event, codec)
        end

        defp es_load_payload(mod, wire, codec) do
          if is_nil(mod.__es_payload__()), do: {:ok, nil}, else: load_payload(mod, wire, codec)
        end
      else
        defp es_dump_payload(_event, _codec), do: nil

        defp es_load_payload(_mod, _wire, _codec), do: {:ok, nil}
      end

      @before_compile Core.Es.Event.Codec
      @es_use_line unquote(__CALLER__.line)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    tags = Module.get_attribute(env.module, :es_tag_by_mod)
    upcasts = Module.get_attribute(env.module, :es_upcasts)

    if with_payload?(tags) do
      Enum.each(
        [dump_payload: 2, load_payload: 3],
        &ensure_defined!(env.module, &1, "у кодека есть события с нагрузкой", env)
      )
    end

    if map_size(upcasts) > 0,
      do: ensure_defined!(env.module, {:upcast, 2}, "у кодека непустые upcasts:", env)

    quote do
      unquote(draft_ast(tags))
      unquote_splicing(payload_checks(env.module, tags))
    end
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

  @doc "Несёт ли нагрузку хоть одно событие кодека."
  @spec with_payload?(%{optional(module()) => String.t()}) :: boolean()

  def with_payload?(tags) when is_map(tags) do
    Enum.any?(Map.keys(tags), &(not is_nil(&1.__es_payload__())))
  end

  @doc """
  Событие → конверт wire.

  `type` и `payload` приходят от кодека агрегата: тег знает только он, нагрузку собирает
  его `dump_payload/2`.
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
        ) :: {:ok, struct()} | {:error, Error.t()}

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
  @spec load_header(wire(), module(), module(), module()) :: {:ok, header()} | {:error, Error.t()}

  def load_header(data, aggregate_id_mod, by_mod, module)
      when is_map(data) and is_atom(aggregate_id_mod) and is_atom(by_mod) and is_atom(module) do
    with {:ok, aggregate_id} <- load_field(data, :aggregate_id, aggregate_id_mod, module),
         {:ok, version} <- load_field(data, :aggregate_version, Version, module),
         {:ok, by} <- load_field(data, :by, by_mod, module),
         {:ok, at} <- load_field(data, :at, Es.Event.At, module),
         {:ok, id} <- load_field(data, :event_id, Es.Event.ID, module) do
      {:ok, %{id: id, aggregate_id: aggregate_id, version: version, at: at, by: by}}
    end
  end

  @doc "Модуль события + нагрузка + header → событие."
  @spec build(module(), struct() | nil, header()) :: struct()

  def build(mod, payload, %{} = header) when is_atom(mod) do
    case mod.__es_payload__() do
      nil ->
        mod.new(header.aggregate_id, header.version, header.by, header.at, header.id)

      _payload_mod ->
        mod.new(payload, header.aggregate_id, header.version, header.by, header.at, header.id)
    end
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
      by: Helper.Map.field(data, :by)
    }
  end

  @doc "Поля по отдельности → конверт: обратная операция к `to_fields/1`."
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

  defp ensure_defined!(mod, {fun, arity}, reason, env) do
    unless Module.defines?(mod, {fun, arity}) do
      raise CompileError,
        description: "#{@label}: #{inspect(mod)} обязан объявить #{fun}/#{arity} — #{reason}",
        file: env.file,
        line: env.line
    end
  end

  defp draft_ast(tags) do
    {with_payload, without_payload} =
      tags
      |> Map.keys()
      |> Enum.sort()
      |> Enum.split_with(&(not is_nil(&1.__es_payload__())))

    quote do
      unquote(draft_payload_ast(with_payload))
      unquote(draft_bare_ast(without_payload))
    end
  end

  defp draft_payload_ast([]), do: nil

  defp draft_payload_ast(mods) do
    clauses =
      for mod <- mods do
        quote do
          def draft(unquote(mod), %unquote(mod.__es_payload__()){} = payload), do: {unquote(mod), payload}
        end
      end

    quote do
      @doc "Черновик события с нагрузкой — элемент результата `decide/2`."
      @spec draft(module(), struct()) :: Core.Es.Aggregate.result()

      unquote_splicing(clauses)
    end
  end

  defp draft_bare_ast([]), do: nil

  defp draft_bare_ast(mods) do
    clauses =
      for mod <- mods do
        quote do
          def draft(unquote(mod)), do: unquote(mod)
        end
      end

    quote do
      @doc "Черновик события без нагрузки — элемент результата `decide/2`."
      @spec draft(module()) :: Core.Es.Aggregate.result()

      unquote_splicing(clauses)
    end
  end

  defp payload_checks(module, tags) do
    line = Module.get_attribute(module, :es_use_line)
    events = Enum.reject(Enum.sort(Map.keys(tags)), &is_nil(&1.__es_payload__()))

    Enum.map(events, &dump_check(&1, line)) ++
      Enum.map(Enum.sort_by(events, & &1.__es_payload__()), &load_check(&1, line))
  end

  defp dump_check(event, line) do
    args = [quote(do: unquote(Es.Check.event_pattern(event)) = event), quote(do: codec)]
    Es.Check.define("dump_payload/2 принимает", event, args, quote(do: dump_payload(event, codec)), line)
  end

  # Имя называет модуль нагрузки, а он бывает общим у нескольких событий: у такой функции-проверки
  # clause на каждое событие, и они идут подряд. Одно тело на все события не годится — после
  # первого предупреждения в теле вывод типов остальные не сообщает.
  defp load_check(event, line) do
    payload = event.__es_payload__()
    [ok] = quote(do: ({:ok, %unquote(payload){}} -> :ok))
    [error] = quote(generated: true, do: ({:error, _} -> :ok))
    body = quote(do: case(load_payload(unquote(event), wire, codec), do: unquote([ok, error])))

    Es.Check.define("load_payload/3 отдаёт нагрузку", payload, [event, quote(do: wire), quote(do: codec)], body, line)
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
