defmodule Core.Es.Event.Repo.Pg do
  @moduledoc """
  Билдер PostgreSQL-реализации репозитория событий агрегата.

      use Core.Es.Event.Repo.Pg,
        behaviour: MyApp.Domain.<BC>.Common.Role.Event.Repo,
        schema: __MODULE__.Schema,
        aggregate_id: MyApp.Domain.<BC>.Common.Role.ID,
        errors: MyApp.Domain.<BC>.Common.Role.Errors

  Генерирует `append/2`, `list_by_aggregate/2`, `page_by_aggregate/4`.

  `append/2` пишет пачку одним `insert_all` с `on_conflict: :nothing` по
  `(aggregate_id, aggregate_version)`: конфликт означает, что версию агрегата уже занял
  конкурентный писатель, и возвращается доменная ошибка `:version_mismatch`, а не
  `Postgrex.Error`. Транзакция при этом не переводится в aborted-состояние — откат делает
  вызывающий по `{:error, _}`.

  ## Opts

  - `behaviour:` — модуль behaviour (`Core.Es.Event.Repo`)
  - `schema:` — Ecto-схема таблицы событий (`Core.Es.Event.Repo.Pg.Schema`)
  - `aggregate_id:` — Prim идентификатора агрегата
  - `errors:` — каталог доменных ошибок агрегата (нужен clause `:version_mismatch`)
  - `repo:` — Ecto.Repo; по умолчанию `Core.Config.dao()`
  - `codec:` — entity-фасад Codec; по умолчанию `Core.Config.codec()`

  Макрос занимает имена `@es_behaviour`, `@es_schema`, `@es_dao`, `@es_errors`, `@es_codec`.
  """

  alias Core.Config
  alias Core.Helper

  @label "Es.Event.Repo.Pg"

  @append_chunk_size 500
  @required_keys ~w(behaviour schema aggregate_id errors)a
  @optional_keys ~w(repo codec)a

  @doc "Реализовать репозиторий событий агрегата через PostgreSQL."
  defmacro __using__(opts) do
    opts =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      require Ecto.Query

      @behaviour unquote(opts.behaviour)

      @es_behaviour unquote(opts.behaviour)
      @es_schema unquote(opts.schema)
      @es_dao unquote(opts.dao)
      @es_errors unquote(opts.errors)
      @es_codec unquote(opts.codec)

      @doc "Добавить события агрегата в store."
      @impl true
      def append(events, context, opts \\ [])

      def append([], %Core.Context{}, opts) when is_list(opts), do: :ok

      def append(events, %Core.Context{}, opts)
          when is_list(events) and is_list(opts) do
        events
        |> Enum.chunk_every(unquote(__MODULE__).append_chunk_size())
        |> Core.Result.traverse(&append_chunk(&1, opts))
        |> case do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end

      @doc "Число событий агрегата."
      @impl true
      def count_by_aggregate(%unquote(opts.aggregate_id){} = id, %Core.Context{}) do
        {:ok, @es_dao.aggregate(base_query(id), :count)}
      end

      @doc """
      Список событий агрегата по aggregate id.

      `opts`: `:from_version` / `:to_version` (включительно) — чтение диапазона
      для реконструкции от снапшота. Без них читается вся история: для выдачи
      наружу использовать `page_by_aggregate/4`.
      """
      @impl true
      def list_by_aggregate(id, context, opts \\ [])

      def list_by_aggregate(
            %unquote(opts.aggregate_id){} = id,
            %Core.Context{},
            opts
          )
          when is_list(opts) do
        id
        |> base_query()
        |> version_range(opts)
        |> @es_dao.all()
        |> Core.Result.traverse(&@es_schema.to_entity/1)
      end

      @doc "Страница событий агрегата по aggregate id."
      @impl true
      def page_by_aggregate(
            %unquote(opts.aggregate_id){} = id,
            %Core.Pagination.Limit{} = limit,
            %Core.Pagination.Offset{} = offset,
            %Core.Context{}
          ) do
        scope = base_query(id)

        rows =
          Ecto.Query.from(e in scope,
            limit: ^Core.Pagination.Limit.value(limit),
            offset: ^Core.Pagination.Offset.value(offset)
          )
          |> @es_dao.all()

        with {:ok, items} <- Core.Result.traverse(rows, &@es_schema.to_entity/1) do
          {:ok, Core.Pagination.Result.new(items, @es_dao.aggregate(scope, :count))}
        end
      end

      defp append_chunk(chunk, opts) do
        rows = Enum.map(chunk, &@es_schema.to_model!/1)
        expected = length(rows)

        insert_opts =
          Keyword.merge(opts,
            on_conflict: :nothing,
            conflict_target: [:aggregate_id, :aggregate_version]
          )

        case @es_dao.insert_all(@es_schema, rows, insert_opts) do
          {^expected, _} -> {:ok, expected}
          {_inserted, _} -> {:error, version_conflict(chunk)}
        end
      end

      defp version_range(query, opts) do
        query
        |> version_from(Keyword.get(opts, :from_version))
        |> version_to(Keyword.get(opts, :to_version))
      end

      defp version_from(query, nil), do: query

      defp version_from(query, %Core.Version{} = version) do
        value = Core.Version.value(version)
        Ecto.Query.from(e in query, where: e.aggregate_version >= ^value)
      end

      defp version_to(query, nil), do: query

      defp version_to(query, %Core.Version{} = version) do
        value = Core.Version.value(version)
        Ecto.Query.from(e in query, where: e.aggregate_version <= ^value)
      end

      defp base_query(id) do
        db_id = @es_codec.dump(id)

        Ecto.Query.from(e in @es_schema,
          where: e.aggregate_id == ^db_id,
          order_by: [asc: e.aggregate_version]
        )
      end

      defp version_conflict([event | _] = events) do
        @es_errors.domain(@es_behaviour, :version_mismatch, %{
          aggregate_id: @es_codec.dump(event.aggregate_id),
          versions: Enum.map(events, &Core.Version.value(&1.aggregate_version))
        })
      end
    end
  end

  @doc """
  Размер чанка `insert_all` для `append/2`.

  На событие приходится 7 bind-параметров, потолок PostgreSQL — 65535: без
  чанкования flush больше ~9000 событий падал бы на уровне протокола.
  """
  @spec append_chunk_size() :: pos_integer()

  def append_chunk_size, do: @append_chunk_size

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec validate_errors_module!(module()) :: :ok

  def validate_errors_module!(errors) do
    errors.domain(__MODULE__, :version_mismatch, nil)
    :ok
  rescue
    FunctionClauseError ->
      reraise CompileError,
              [
                description:
                  "#{@label}: errors: отсутствует clause для :version_mismatch в #{inspect(errors)}"
              ],
              __STACKTRACE__
  end

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    %{
      behaviour: Helper.Opts.module!(opts, :behaviour, @label),
      schema: Helper.Opts.module!(opts, :schema, @label),
      aggregate_id: Helper.Opts.module!(opts, :aggregate_id, @label, exports: [new: 1]),
      errors: errors!(opts),
      dao: Keyword.get(opts, :repo) || Config.dao(),
      codec: Keyword.get(opts, :codec) || Config.codec()
    }
  end

  defp errors!(opts) do
    errors = Helper.Opts.module!(opts, :errors, @label, exports: [domain: 3])

    validate_errors_module!(errors)
    errors
  end
end
