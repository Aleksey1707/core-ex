defmodule Core.EsAggregateRepoContract do
  @moduledoc """
  Общий набор тестов контракта `Core.Es.Aggregate.Repo` — прогоняется на каждой реализации
  write-репозитория счёта `Core.EsFixture.Account`.

  Восстановление состояния, сверка версии и атомарность записи — то, на чём стоит usecase
  команды: реализация с другим путём чтения, разойдясь с этими исходами, молча отдаст команде
  чужое состояние (`19-testing.md`, «Контрактные тесты behaviour»).

  Хост-модуль — `use Core.DataCase` и `use Core.EsAggregateRepoContract, impl: <реализация>`.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Cmd
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.Helper.Transact
  alias Core.Outbox
  alias Core.Version

  @query_event [:core, :test_repo, :query]
  @query_kinds ~w(all select insert)a

  @doc "Подключить набор: `use Core.EsAggregateRepoContract, impl: Account.Repo.Pg`."
  defmacro __using__(impl: impl) do
    quote do
      import Core.EsAggregateRepoContract

      @repo_impl unquote(impl)

      unquote(get_tests())
      unquote(get_many_tests())
      unquote(append_tests())
      unquote(refresh_tests())
    end
  end

  # ---

  defp get_tests do
    quote do
      describe "контракт Es.Aggregate.Repo: get" do
        test "пустой поток при :current — состояние без версии" do
          id = Account.ID.new()

          assert {:ok, %Account{id: ^id, version: nil, status: nil}} =
                   @repo_impl.get(id, :current, Context.new())
        end

        test "пустой поток при %Version{} — :version_mismatch с actual: nil" do
          id = Account.ID.new()

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.get(id, Version.new!(1), Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: nil}
        end

        test "состояние свёрнуто из потока и сверено с головой" do
          id = Account.ID.new()
          name = Account.Name.new!("Отгрузка")
          version = Version.new!(2)
          write!(@repo_impl, id, [open(), rename("Отгрузка")])

          assert {:ok, %Account{id: ^id, version: ^version, name: ^name, status: :open}} =
                   @repo_impl.get(id, version, Context.new())
        end

        test "устаревшая версия — :version_mismatch с головой потока" do
          id = Account.ID.new()
          write!(@repo_impl, id, [open(), rename("Отгрузка")])

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.get(id, Version.new!(1), Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: 2}
        end

        test "неизвестный тег в потоке — исключение загрузки" do
          id = Account.ID.new()
          {opened, _state} = execute!(%Account{id: id}, open())
          insert_rows!(opened, "account.unknown")

          assert_raise Core.Exc, fn -> @repo_impl.get(id, :current, Context.new()) end
        end

        test "разрыв версий в потоке — ArgumentError" do
          id = Account.ID.new()
          {opened, state} = execute!(%Account{id: id}, open())
          {[frozen], _state} = execute!(state, freeze())
          insert_rows!(opened ++ [%{frozen | aggregate_version: Version.new!(3)}])

          assert_raise ArgumentError, ~r/разрыв версий/, fn ->
            @repo_impl.get(id, :current, Context.new())
          end
        end
      end
    end
  end

  defp get_many_tests do
    quote do
      describe "контракт Es.Aggregate.Repo: get_many" do
        test "состояния в порядке пар; пустой поток — без версии" do
          [first, second, empty] = [Account.ID.new(), Account.ID.new(), Account.ID.new()]
          write!(@repo_impl, first, [open("Первый")])
          write!(@repo_impl, second, [open("Второй"), freeze()])
          pairs = [{second, :current}, {empty, :current}, {first, Version.new!(1)}]

          assert {:ok,
                  [
                    %Account{id: ^second, status: :frozen},
                    %Account{id: ^empty, version: nil},
                    %Account{id: ^first, status: :open}
                  ]} = @repo_impl.get_many(pairs, Context.new())
        end

        test "все потоки — одним читающим запросом" do
          ids = for _ <- 1..3, do: Account.ID.new()
          Enum.each(ids, &write!(@repo_impl, &1, [open(), freeze()]))

          assert {{:ok, [_, _, _]}, 1} =
                   count_queries(
                     fn -> @repo_impl.get_many(Enum.map(ids, &{&1, :current}), Context.new()) end,
                     :select
                   )
        end

        test "все расхождения — одна :version_mismatch в порядке пар" do
          [first, second, third] = [Account.ID.new(), Account.ID.new(), Account.ID.new()]
          Enum.each([first, second, third], &write!(@repo_impl, &1, [open()]))
          pairs = [{first, Version.new!(2)}, {second, :current}, {third, Version.new!(3)}]

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.get_many(pairs, Context.new())

          assert error.detail == [
                   %{aggregate_id: dump(first), expected: 2, actual: 1},
                   %{aggregate_id: dump(third), expected: 3, actual: 1}
                 ]
        end

        test "повтор id — ArgumentError" do
          id = Account.ID.new()

          assert_raise ArgumentError, ~r/повтор id/, fn ->
            @repo_impl.get_many([{id, :current}, {id, :current}], Context.new())
          end
        end

        test "пустой список пар — пустой результат без запросов" do
          assert {{:ok, []}, 0} =
                   count_queries(fn -> @repo_impl.get_many([], Context.new()) end)
        end
      end
    end
  end

  defp append_tests do
    quote do
      describe "контракт Es.Aggregate.Repo: append" do
        test "команда создания: события в потоке и записи outbox" do
          id = Account.ID.new()

          assert {:ok, state} = @repo_impl.get(id, :current, Context.new())
          {events, opened} = execute!(state, open())

          assert :ok = @repo_impl.append(events, Context.new())
          assert {:ok, ^opened} = @repo_impl.get(id, :current, Context.new())
          assert stream_tags(id) == ~w(account.opened)
          assert outbox_names(id) == ~w(account.opened)
        end

        test "события и outbox пишутся в транзакции вызывающего" do
          id = Account.ID.new()
          {opened, _state} = execute!(%Account{id: id}, open())

          assert {:error, :rollback} =
                   Transact.run(Config.dao(), fn ->
                     :ok = @repo_impl.append(opened, Context.new())
                     {:error, :rollback}
                   end)

          assert stream_tags(id) == []
          assert outbox_names(id) == []
        end

        test "цепочка команд от состояния execute/2 без повторного get" do
          id = Account.ID.new()

          assert {:ok, state} = @repo_impl.get(id, :current, Context.new())
          {opened, state} = execute!(state, open())
          assert :ok = @repo_impl.append(opened, Context.new())
          {closed, state} = execute!(state, close())
          assert :ok = @repo_impl.append(closed, Context.new())

          assert {:ok, ^state} = @repo_impl.get(id, :current, Context.new())
          assert stream_tags(id) == ~w(account.opened account.frozen account.closed)
        end

        test "команда без изменений — :ok без запросов" do
          assert {:ok, 0} = count_queries(fn -> @repo_impl.append([], Context.new()) end)
        end

        test "конкурентная запись — :version_mismatch; события и outbox не записаны" do
          id = Account.ID.new()
          write!(@repo_impl, id, [open()])
          assert {:ok, state} = @repo_impl.get(id, :current, Context.new())
          {renamed, _state} = execute!(state, rename("Отгрузка"))
          {frozen, _state} = execute!(state, freeze())

          assert :ok = @repo_impl.append(renamed, Context.new())

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.append(frozen, Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 2, actual: 2}
          assert stream_tags(id) == ~w(account.opened account.renamed)
          assert outbox_names(id) == ~w(account.opened account.renamed)
        end

        test "первая версия пачки не вслед за головой потока — :version_mismatch" do
          id = Account.ID.new()
          opened = write!(@repo_impl, id, [open()])
          {frozen, _state} = execute!(%{opened | version: Version.new!(3)}, freeze())

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.append(frozen, Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 4, actual: 1}
          assert stream_tags(id) == ~w(account.opened)
        end

        test "пачка нескольких потоков: конфликт в одном откатывает всю" do
          [first, second] = [Account.ID.new(), Account.ID.new()]
          write!(@repo_impl, first, [open("Первый")])
          write!(@repo_impl, second, [open("Второй")])
          pairs = [{first, :current}, {second, :current}]
          assert {:ok, [first_state, second_state]} = @repo_impl.get_many(pairs, Context.new())
          {first_renamed, _state} = execute!(first_state, rename("Первый счёт"))
          {second_renamed, _state} = execute!(second_state, rename("Второй счёт"))
          {second_frozen, _state} = execute!(second_state, freeze())
          assert :ok = @repo_impl.append(second_frozen, Context.new())

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.append(first_renamed ++ second_renamed, Context.new())

          assert error.detail == %{aggregate_id: dump(second), expected: 2, actual: 2}
          assert stream_tags(first) == ~w(account.opened)
          assert outbox_names(first) == ~w(account.opened)
        end

        test "событие чужого агрегата — FunctionClauseError" do
          assert_raise FunctionClauseError, fn ->
            @repo_impl.append([EventFixture.created()], Context.new())
          end
        end
      end
    end
  end

  defp refresh_tests do
    quote do
      describe "контракт Es.Aggregate.Repo: refresh" do
        test "дочитывает хвост потока, записанный в обход состояния" do
          id = Account.ID.new()
          assert {:ok, state} = @repo_impl.get(id, :current, Context.new())
          {opened, state} = execute!(state, open())
          assert :ok = @repo_impl.append(opened, Context.new())
          renamed = write!(@repo_impl, id, [rename("Отгрузка")])

          assert {:ok, ^renamed} = @repo_impl.refresh(state, :current, Context.new())
          assert {:ok, ^renamed} = @repo_impl.refresh(state, Version.new!(2), Context.new())
        end

        test "версия мимо головы после дочитывания — :version_mismatch" do
          id = Account.ID.new()
          opened = write!(@repo_impl, id, [open()])
          write!(@repo_impl, id, [rename("Отгрузка")])

          assert {:error, %Error{module: Account.Repo, code: :version_mismatch} = error} =
                   @repo_impl.refresh(opened, Version.new!(1), Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: 2}
        end

        test "состояние без версии — весь поток" do
          id = Account.ID.new()
          state = write!(@repo_impl, id, [open(), freeze()])

          assert {:ok, ^state} = @repo_impl.refresh(%Account{id: id}, :current, Context.new())
        end
      end
    end
  end

  @doc "Команда «открыть счёт»."
  @spec open(String.t()) :: Cmd.Open.t()

  def open(name \\ "Приёмка"), do: %Cmd.Open{name: Account.Name.new!(name), by: by(), at: at()}

  @doc "Команда «переименовать счёт»."
  @spec rename(String.t()) :: Cmd.Rename.t()

  def rename(name), do: %Cmd.Rename{name: Account.Name.new!(name), by: by(), at: at()}

  @doc "Команда «заморозить счёт»."
  @spec freeze() :: Cmd.Freeze.t()

  def freeze, do: %Cmd.Freeze{by: by(), at: at()}

  @doc "Команда «закрыть счёт»: открытый — два события одной команды."
  @spec close() :: Cmd.Close.t()

  def close, do: %Cmd.Close{by: by(), at: at()}

  # ---

  defp by, do: UserID.new()

  defp at, do: Es.Event.At.new!(~U[2026-09-01 10:00:00Z])

  @doc "Исполнить команду от состояния: события и состояние после них."
  @spec execute!(Account.t(), Cmd.t()) :: {[Es.Event.t()], Account.t()}

  def execute!(state, command) do
    {:ok, {events, state}} = Account.execute(state, command)
    {events, state}
  end

  @doc "Исполнить команды над счётом `id` через `impl`: `get` → `execute/2` → `append` на каждую."
  @spec write!(module(), Account.ID.t(), [Cmd.t()]) :: Account.t()

  def write!(impl, id, commands) do
    Enum.reduce(commands, nil, fn command, _state ->
      {:ok, state} = impl.get(id, :current, Context.new())
      {events, state} = execute!(state, command)
      :ok = impl.append(events, Context.new())
      state
    end)
  end

  @doc "Теги записанных событий потока счёта по возрастанию версии."
  @spec stream_tags(Account.ID.t()) :: [String.t()]

  def stream_tags(id) do
    Account.Event.Codec
    |> Es.Store.Test.events!(id)
    |> Enum.map(&Account.Event.Codec.type/1)
  end

  @doc "Имена записей outbox счёта в порядке записи."
  @spec outbox_names(Account.ID.t()) :: [String.t()]

  def outbox_names(id) do
    key = dump(id)

    from(r in Outbox.Repo.Pg.Schema,
      where: r.key == ^key,
      order_by: [asc: r.created_at, asc: r.id],
      select: r.name
    )
    |> Config.dao().all()
  end

  @doc "Строки `es_events` из событий в обход записи репозитория; `tag` подменяет тег всех строк."
  @spec insert_rows!([Es.Event.t()], String.t() | nil) :: :ok

  def insert_rows!(events, tag \\ nil) do
    rows =
      Enum.map(events, fn event ->
        fields = Es.Event.Codec.to_fields(dump(event))

        %{
          aggregate_type: Account.Event.Codec.__es_type__(),
          aggregate_id: fields.aggregate_id,
          aggregate_version: fields.aggregate_version,
          event_id: fields.id,
          tag: tag || fields.type,
          payload: fields.payload,
          by_id: fields.by,
          at: fields.at
        }
      end)

    {_count, nil} = Config.dao().insert_all(Es.Store.Schema, rows)
    :ok
  end

  @doc """
  Результат `fun` и число SQL-запросов, которые процесс теста сделал за время `fun`.

  `kind` — какие запросы считать: `:all`, `:select` или `:insert`.
  """
  @spec count_queries((-> result), :all | :select | :insert) :: {result, non_neg_integer()}
        when result: var

  def count_queries(fun, kind \\ :all) when is_function(fun, 0) and kind in @query_kinds do
    handler = {__MODULE__, make_ref()}
    config = {self(), handler, kind}
    :ok = :telemetry.attach(handler, @query_event, &__MODULE__.count_query/4, config)

    try do
      {fun.(), drain_queries(handler, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  @spec count_query([atom()], map(), map(), {pid(), term(), atom()}) :: :ok

  def count_query(_event, _measurements, %{query: query}, {test, handler, kind}) do
    if self() == test and counted?(kind, query), do: send(test, {handler, :query})
    :ok
  end

  # ---

  defp counted?(:all, _query), do: true
  defp counted?(:select, query), do: String.starts_with?(query, "SELECT")
  defp counted?(:insert, query), do: String.starts_with?(query, "INSERT")

  defp drain_queries(handler, count) do
    receive do
      {^handler, :query} -> drain_queries(handler, count + 1)
    after
      0 -> count
    end
  end

  @doc "Внутренний wire значения — фасадом `Core.Config.codec/0`."
  @spec dump(term()) :: term()

  def dump(value), do: Config.codec().dump(value)
end
