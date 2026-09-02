defmodule Core.Es.Event.Repo do
  @moduledoc """
  Билдер behaviour репозитория событий агрегата (event store).

      use Core.Es.Event.Repo,
        event: MyApp.Domain.<BC>.Common.Role.Event,
        aggregate_id: MyApp.Domain.<BC>.Common.Role.ID

  Генерирует `@callback append/2`, `list_by_aggregate/2`, `page_by_aggregate/4`.
  Реализация — `Core.Es.Event.Repo.Pg`.

  Чтение возвращает `Result`, а не голый список: событие, тип которого больше не известен
  кодеку (переименованный тег, повреждённая строка), — доменная ошибка
  `:unknown_event_type`, а не 500 на HTTP GET истории. Bang-реконструкция (`to_entity!`)
  остаётся на write-path.

  ## Opts

  - `event:` — объединяющий модуль событий агрегата
  - `aggregate_id:` — Prim идентификатора агрегата
  """

  alias Core.Helper

  @label "Es.Event.Repo"
  @required_keys ~w(event aggregate_id)a
  @optional_keys ~w()a

  @doc "Объявить behaviour репозитория событий агрегата."
  defmacro __using__(opts) do
    {event, aggregate_id} =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      @doc "Добавить события агрегата в store."
      @callback append(
                  events :: [unquote(event).t()],
                  context :: Core.Context.t()
                ) :: :ok | {:error, Core.Error.t()}

      @doc "То же, с опциями запроса (`:prefix`, `:timeout`)."
      @callback append(
                  events :: [unquote(event).t()],
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: :ok | {:error, Core.Error.t()}

      @doc "Список событий агрегата по aggregate id (по возрастанию версии)."
      @callback list_by_aggregate(
                  id :: unquote(aggregate_id).t(),
                  context :: Core.Context.t()
                ) :: {:ok, [unquote(event).t()]} | {:error, Core.Error.t()}

      @doc """
      Список событий агрегата с опциями диапазона версий.

      `:from_version` / `:to_version` (`Version.t()`, включительно) — чтение
      от снапшота вместо всей истории.
      """
      @callback list_by_aggregate(
                  id :: unquote(aggregate_id).t(),
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: {:ok, [unquote(event).t()]} | {:error, Core.Error.t()}

      @doc "Число событий агрегата."
      @callback count_by_aggregate(
                  id :: unquote(aggregate_id).t(),
                  context :: Core.Context.t()
                ) :: {:ok, non_neg_integer()} | {:error, Core.Error.t()}

      @doc "Страница событий агрегата по aggregate id."
      @callback page_by_aggregate(
                  id :: unquote(aggregate_id).t(),
                  limit :: Core.Pagination.Limit.t(),
                  offset :: Core.Pagination.Offset.t(),
                  context :: Core.Context.t()
                ) ::
                  {:ok, Core.Pagination.Result.t(unquote(event).t())}
                  | {:error, Core.Error.t()}
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    {
      Helper.Opts.module!(opts, :event, @label),
      Helper.Opts.module!(opts, :aggregate_id, @label, exports: [new: 1])
    }
  end
end
