defmodule Core.Es.Event.Codec do
  @moduledoc """
  Билдер кодека событий агрегата (`<Aggregate>.Event.Codec`).

      @tag_by_mod %{Event.Registered => "registered", Event.Updated => "updated"}

      use Core.Es.Event.Codec,
        tags: @tag_by_mod,
        event: MyApp.Domain.<BC>.Common.Delivery.Event,
        aggregate_id: MyApp.Domain.<BC>.Common.Delivery.ID,
        by: MyApp.Domain.Users.Common.User.ID,
        errors: MyApp.Domain.<BC>.Common.Delivery.Errors

  Генерирует `use Core.Codec.Plugin` (dump-only, `loadable: false`), `dump/2`,
  `load_event/8`, `load_event!/8` и приватный `unknown_type/2`; импортирует
  `event/2` и `event/3` из `Core.Es.Event.Codec.Helper`.

  Кодек агрегата определяет только специфику:

  - `dump_payload(event, codec)` — нагрузка события в wire;
  - `load_payload(mod, wire, envelope, codec)` — wire + envelope → событие.

  ## Opts

  - `tags:` — `%{Mod => "wire_tag"}` (SSOT wire-имён событий; см. `Core.Codec.Plugin`)
  - `event:` — объединяющий модуль событий агрегата
  - `aggregate_id:` — Prim идентификатора агрегата
  - `by:` — Prim идентификатора автора события
  - `errors:` — каталог доменных ошибок агрегата (нужен clause `:unknown_event_type`)

  Макрос занимает в вызывающем модуле имя `@es_errors`.
  """

  alias Core.Helper

  @label "Es.Event.Codec"
  @required_keys ~w(tags event aggregate_id by errors)a
  @optional_keys ~w()a

  @doc "Объявить кодек событий агрегата."
  defmacro __using__(opts) do
    tags = Keyword.fetch!(opts, :tags)

    cfg =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      use Core.Codec.Plugin,
        tags: unquote(tags),
        loadable: false

      import Core.Es.Event.Codec.Helper, only: [event: 2, event: 3]

      @es_errors unquote(cfg.errors)

      @typedoc "Событие агрегата."
      @type event :: unquote(cfg.event).t()

      @typedoc "Нагрузка события на wire."
      @type wire_payload :: map() | String.t() | number() | boolean() | list() | nil

      @typep envelope ::
               {unquote(cfg.aggregate_id).t(), Core.Version.t(), unquote(cfg.by).t(),
                Core.Es.Event.At.t(), Core.Es.Event.ID.t()}

      @doc "Событие → {type, payload}."
      @spec dump(event(), module()) :: {String.t(), wire_payload()}

      @impl true
      def dump(%mod{} = event, codec) when is_map_key(@codec_tag_by_mod, mod) do
        {type(mod), dump_payload(event, codec)}
      end

      @doc "type + payload + envelope → событие."
      @spec load_event(
              String.t(),
              wire_payload(),
              unquote(cfg.aggregate_id).t(),
              Core.Version.t(),
              unquote(cfg.by).t(),
              Core.Es.Event.At.t(),
              Core.Es.Event.ID.t(),
              module()
            ) :: {:ok, event()} | {:error, Core.Error.t()}

      def load_event(
            type,
            payload,
            %unquote(cfg.aggregate_id){} = aggregate_id,
            %Core.Version{} = version,
            %unquote(cfg.by){} = by,
            %Core.Es.Event.At{} = at,
            %Core.Es.Event.ID{} = id,
            codec
          )
          when is_binary(type) and is_atom(codec) do
        case mod_by_tag(type) do
          {:ok, mod} -> load_payload(mod, payload, {aggregate_id, version, by, at, id}, codec)
          :error -> {:error, unknown_type(type, payload)}
        end
      end

      @doc "type + payload + envelope → событие; при ошибке — raise."
      @spec load_event!(
              String.t(),
              wire_payload(),
              unquote(cfg.aggregate_id).t(),
              Core.Version.t(),
              unquote(cfg.by).t(),
              Core.Es.Event.At.t(),
              Core.Es.Event.ID.t(),
              module()
            ) :: event()

      def load_event!(
            type,
            payload,
            %unquote(cfg.aggregate_id){} = aggregate_id,
            %Core.Version{} = version,
            %unquote(cfg.by){} = by,
            %Core.Es.Event.At{} = at,
            %Core.Es.Event.ID{} = id,
            codec
          )
          when is_binary(type) and is_atom(codec) do
        Core.Result.unwrap!(load_event(type, payload, aggregate_id, version, by, at, id, codec))
      end

      @spec load_payload(module(), wire_payload(), envelope(), module()) ::
              {:ok, event()} | {:error, Core.Error.t()}

      defp unknown_type(type, payload) do
        @es_errors.domain(__MODULE__, :unknown_event_type, %{type: type, payload: payload})
      end
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec validate_errors_module!(module()) :: :ok

  def validate_errors_module!(errors) do
    errors.domain(__MODULE__, :unknown_event_type, nil)
    :ok
  rescue
    FunctionClauseError ->
      reraise CompileError,
              [
                description:
                  "#{@label}: errors: отсутствует clause для :unknown_event_type в " <>
                    inspect(errors)
              ],
              __STACKTRACE__
  end

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    %{
      event: Helper.Opts.module!(opts, :event, @label),
      aggregate_id: Helper.Opts.module!(opts, :aggregate_id, @label, exports: [new: 1]),
      by: Helper.Opts.module!(opts, :by, @label, exports: [new: 1]),
      errors: errors!(opts)
    }
  end

  defp errors!(opts) do
    errors = Helper.Opts.module!(opts, :errors, @label, exports: [domain: 3])

    validate_errors_module!(errors)
    errors
  end
end
