defmodule Core.Es.Event.Family do
  @moduledoc """
  Семейство событий агрегата (`use`): union всех событий одного владельца потока (ADR-0084).

  ```elixir
  defmodule MyApp.Domain.Sales.Account.Event do
    alias MyApp.Domain.Sales.Account
    alias MyApp.Domain.Sales.Values.UserID

    use Core.Es.Event.Family,
      aggregate: Account,
      aggregate_id: Account.ID,
      by: UserID,
      codec: Account.Event.Codec

    @type t :: Account.Event.Opened.t() | Account.Event.Closed.t()
  end
  ```

  Семейство владеет идентификатором агрегата и автором событий: событие ссылается на него одной
  опцией `family:` (`use Core.Es.Event`) и запекает оба Prim в головы `new/5,6`, `@type t` и
  `@spec`.

  ## Опции

  Все обязательны; недостающая или неизвестная — `CompileError`.

  - `aggregate_id:` — Prim идентификатора агрегата, `by:` — Prim автора события. Семейство ждёт
    оба модуля при раскрытии `use`.
  - `aggregate:` — владелец потока: event-sourced агрегат, state-stored сущность или
    `Core.Es.Personal`. `codec:` — кодек событий семейства (`use Core.Es.Event.Codec`). Обе —
    атомы без загрузки: алиас раскрывается как в теле функции, ребро xref — runtime, и цикла
    семейство ↔ кодек / агрегат нет.

  `@type t` — union событий семейства — пишет автор; без него — `CompileError` в конце сборки
  модуля.

  ## Интроспекция

  `__es_aggregate__/0`, `__es_aggregate_id__/0`, `__es_by__/0`, `__es_codec__/0` — значения опций.

  ## Сверки ссылок

  Ссылки `aggregate:` и `codec:` сверяет `@after_verify` после сборки всех модулей — без ожидания
  и без compile-ребра. Нарушение — предупреждение сборки с файлом семейства, а не `CompileError`:
  `mix compile` проходит, `--warnings-as-errors` падает.

  - `aggregate:` — существующий модуль: `Es.Event.Family: <Family>: aggregate: <X> не найден`;
  - `codec:` — кодек этого семейства (`__codec_union__/0`):
    `Es.Event.Family: <Family>: codec: <C> не кодек этого семейства`;
  - у event-sourced владельца (`__es_event_codec__/0`) кодек — `codec:`:
    `Es.Event.Family: <Family>: aggregate: <X> объявляет event_codec: <C2>, а не <C>`.
    У state-stored сущности и `Core.Es.Personal` — только существование.

  ## Одно семейство — один владелец потока

  Потоки событий семейства пишет один владелец. Семейство, которое делят два агрегата с
  репозиториями, разделяется: у каждого владельца — своё семейство и свой кодек.
  """

  alias Core.Es
  alias Core.Helper

  @label "Es.Event.Family"
  @required_keys ~w(aggregate aggregate_id by codec)a
  @optional_keys ~w()a
  @refs ~w(aggregate codec)a

  # ===== объявление =====

  @doc "Объявить семейство событий агрегата (`aggregate:` / `aggregate_id:` / `by:` / `codec:`)."
  defmacro __using__(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    lit =
      Macro.expand_literals(Keyword.drop(opts, @refs), __CALLER__) ++
        Macro.expand_literals(Keyword.take(opts, @refs), %{__CALLER__ | function: {:__es_codec__, 0}})

    aggregate = Helper.Opts.atom!(lit, :aggregate, @label)
    aggregate_id = Helper.Opts.module!(lit, :aggregate_id, @label)
    by = Helper.Opts.module!(lit, :by, @label)
    codec = Helper.Opts.atom!(lit, :codec, @label)

    quote do
      @before_compile Core.Es.Event.Family
      @after_verify Core.Es.Event.Family

      @doc false
      @spec __es_aggregate__() :: module()

      def __es_aggregate__, do: unquote(aggregate)

      @doc false
      @spec __es_aggregate_id__() :: module()

      def __es_aggregate_id__, do: unquote(aggregate_id)

      @doc false
      @spec __es_by__() :: module()

      def __es_by__, do: unquote(by)

      @doc false
      @spec __es_codec__() :: module()

      def __es_codec__, do: unquote(codec)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines_type?(env.module, {:t, 0}) do
      raise CompileError,
        description: "#{@label}: #{inspect(env.module)} не объявляет @type t — union событий семейства",
        file: env.file,
        line: env.line
    end

    :ok
  end

  # ===== сверки ссылок =====

  # `raise` здесь уронил бы процесс проверки, а под `mix run` не напечатал бы кириллицу.
  @doc false
  @spec __after_verify__(module()) :: :ok

  def __after_verify__(family) when is_atom(family) do
    family
    |> problems(family.__es_aggregate__(), family.__es_codec__())
    |> Enum.each(&warn(family, &1))
  end

  # ---

  defp problems(family, aggregate, codec) do
    Enum.reject(
      [
        aggregate_problem(aggregate),
        codec_problem(family, codec),
        owner_codec_problem(aggregate, codec)
      ],
      &is_nil/1
    )
  end

  defp aggregate_problem(aggregate) do
    unless Code.ensure_loaded?(aggregate), do: "aggregate: #{inspect(aggregate)} не найден"
  end

  defp codec_problem(family, codec) do
    unless Es.Event.Codec.codec?(codec) and codec.__codec_union__() == family,
      do: "codec: #{inspect(codec)} не кодек этого семейства"
  end

  defp owner_codec_problem(aggregate, codec) do
    if Helper.Module.exports?(aggregate, :__es_event_codec__, 0) and aggregate.__es_event_codec__() != codec do
      "aggregate: #{inspect(aggregate)} объявляет event_codec: #{inspect(aggregate.__es_event_codec__())}, " <>
        "а не #{inspect(codec)}"
    end
  end

  defp warn(family, message) do
    IO.warn("#{@label}: #{inspect(family)}: #{message}", file: List.to_string(family.__info__(:compile)[:source]))
  end
end
