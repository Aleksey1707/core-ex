defmodule Core.Es.Event.Codec do
  @moduledoc """
  Билдер кодека событий агрегата (`<Aggregate>.Event.Codec`) и его behaviour.

      @tag_by_mod %{Event.Registered => "delivery.registered", Event.Updated => "delivery.updated"}

      use Core.Es.Event.Codec,
        event: MyApp.Domain.<BC>.Common.Delivery.Event,
        tags: @tag_by_mod

  Кодек агрегата определяет только специфику нагрузки:

  - `dump_payload(event, codec)` — нагрузка события в wire;
  - `load_payload(mod, wire, codec)` — wire → `%Payload{}` (не событие: конверт
    разбирает и событие собирает билдер).

  События без нагрузки (`payload: nil` у `use Es.Event`) клоуз не требуют вовсе —
  билдер знает о них из `__es_payload__/0`.

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
  - `tags:` — `%{Mod => "wire_tag"}`, SSOT wire-имён событий

  Prim агрегата и автора не задаются: они выводятся из самих событий
  (`__es_aggregate_id__/0` и `__es_by__/0`), и расхождение между событиями одного
  кодека — `CompileError`.

  Макрос занимает в вызывающем модуле имена `@es_event`, `@es_aggregate_id`, `@es_by`,
  `@es_tag_by_mod`, `@es_mod_by_tag` и приватные `es_dump_payload/2`, `es_load_payload/3`.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Helper
  alias Core.Version

  require Error

  @label "Es.Event.Codec"
  @required_keys ~w(event tags)a
  @optional_keys ~w()a
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

  @optional_callbacks dump_payload: 2, load_payload: 3

  @doc "Объявить кодек событий агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    event = Helper.Opts.module!(lit, :event, @label)

    # `tags:` уходят в тело модуля как есть: значение атрибута (`@tag_by_mod`) на этапе
    # разворачивания макроса ещё не записано, и прочитать его оттуда нельзя.
    tags = Keyword.fetch!(opts, :tags)

    quote do
      @behaviour Core.Es.Event.Codec

      @es_event unquote(event)
      @es_tag_by_mod Core.Es.Event.Codec.tags!(unquote(tags))
      @es_mod_by_tag Core.Es.Event.Codec.mods!(@es_tag_by_mod)
      @es_aggregate_id Core.Es.Event.Codec.derive!(@es_tag_by_mod, :__es_aggregate_id__)
      @es_by Core.Es.Event.Codec.derive!(@es_tag_by_mod, :__es_by__)

      use Core.Codec.Plugin,
        types: Map.keys(@es_tag_by_mod),
        union: @es_event

      @typedoc "Событие агрегата."
      @type event :: unquote(event).t()

      @typedoc "Нагрузка события на wire."
      @type wire_payload :: map() | String.t() | number() | boolean() | list() | nil

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
        Core.Es.Event.Codec.load_by_tag(data, @es_mod_by_tag, __MODULE__, codec)
      end

      def load(mod, data, codec)
          when is_map_key(@es_tag_by_mod, mod) and is_map(data) and is_atom(codec) do
        with {:ok, header} <-
               Core.Es.Event.Codec.load_header(data, @es_aggregate_id, @es_by, __MODULE__),
             {:ok, payload} <- es_load_payload(mod, field(data, :payload), codec) do
          {:ok, Core.Es.Event.Codec.build(mod, payload, header)}
        end
      end

      # ---

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
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    tags = Module.get_attribute(env.module, :es_tag_by_mod)

    if with_payload?(tags) do
      Enum.each([dump_payload: 2, load_payload: 3], &ensure_defined!(env.module, &1, env))
    end

    nil
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

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

  Разбор safe с обеих сторон: сообщение переживает код, который его писал, поэтому
  чужой формат (`:invalid_envelope`) и снятый с обращения тип (`:unknown_event_type`)
  обязаны стать доменной ошибкой у подписчика, а не падением.
  """
  @spec load_by_tag(term(), %{optional(String.t()) => module()}, module(), module()) ::
          {:ok, struct()} | {:error, Error.t()}

  def load_by_tag(data, mod_by_tag, module, codec) when is_map(data) and is_map(mod_by_tag) do
    with {:ok, tag} <- fetch_tag(data, module),
         {:ok, mod} <- fetch_mod(mod_by_tag, tag, module) do
      module.load(mod, data, codec)
    end
  end

  # Из брокера приходит `Jason.decode!/1` чего угодно: не-map — это сообщение не того
  # формата, а не повод уронить подписчика.
  def load_by_tag(_data, mod_by_tag, module, _codec) when is_map(mod_by_tag) do
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
          description:
            "#{@label}: tags: дубликат тега #{inspect(tag)} у #{inspect(mod)} и #{inspect(other)}"

      :error ->
        Map.put(acc, tag, mod)
    end
  end

  defp ensure_defined!(mod, {fun, arity}, env) do
    unless Module.defines?(mod, {fun, arity}) do
      raise CompileError,
        description:
          "#{@label}: #{inspect(mod)} обязан объявить #{fun}/#{arity} — " <>
            "у кодека есть события с нагрузкой",
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
