defmodule Core.EsAggregateReadRepoContract do
  @moduledoc """
  Общий набор тестов контракта `Core.Es.Aggregate.ReadRepo` — прогоняется на каждой реализации
  чтения состояния event-sourced агрегата на версии.

  Шов — публичные `get_at/3,4`: исходы, форма результата и telemetry. Внутренняя свёртка до
  версии, запросы и порядок чтения не проверяются.

  Хост-модуль — `use Core.DataCase` и
  `use Core.EsAggregateReadRepoContract, impl: <реализация>, repo: <write-реализация>`.

  `error_module:` — модуль поведения write-репозитория, которым строится `:version_mismatch`
  (по умолчанию `Core.EsFixture.Account.Repo`): у варианта со снапшотами он свой.
  `snapshot:` — исход свёртки в telemetry `[:es, :aggregate, :fold]` (по умолчанию `:off`;
  у репозитория со снапшотами без строки — `:miss`).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Telemetry

  # ===== набор =====

  @doc "Подключить набор: `use Core.EsAggregateReadRepoContract, impl: …, repo: …`."
  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)
    repo = Keyword.fetch!(opts, :repo)
    error_module = Keyword.get(opts, :error_module, Account.Repo)
    snapshot = Keyword.get(opts, :snapshot, :off)

    quote do
      alias Core.Context
      alias Core.Error
      alias Core.Es.Personal
      alias Core.EsFixture.Account
      alias Core.EsFixture.Account.AtVersion.View
      alias Core.Version

      import Core.EsAggregateReadRepoContract

      import Core.EsAggregateRepoContract,
        only: [count_queries: 1, count_queries: 2, dump: 1, freeze: 0, open: 0, open: 1, rename: 1, write!: 3]

      @read_repo_impl unquote(impl)
      @write_repo_impl unquote(repo)
      @error_module unquote(error_module)
      @snapshot unquote(snapshot)

      unquote(get_at_tests())
      unquote(get_many_at_tests())
    end
  end

  # ---

  defp get_at_tests do
    quote do
      describe "контракт Es.Aggregate.ReadRepo: get_at" do
        test "версия 1 — состояние после первого события" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первое"), rename("Второе"), freeze()])

          assert {:ok, %View{id: view_id, version: 1, name: "Первое", status: "open", holder: nil}} =
                   @read_repo_impl.get_at(id, Version.new!(1), Context.new())

          assert view_id == Core.Prim.unwrap(id)
        end

        test "промежуточная версия — состояние после событий до неё включительно" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первое"), rename("Второе"), freeze()])

          assert {:ok, %View{version: 2, name: "Второе", status: "open"}} =
                   @read_repo_impl.get_at(id, Version.new!(2), Context.new())
        end

        test "голова потока — состояние головы" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первое"), rename("Второе"), freeze()])

          assert {:ok, %View{version: 3, name: "Второе", status: "frozen"}} =
                   @read_repo_impl.get_at(id, Version.new!(3), Context.new())
        end

        test "версия за головой потока — :version_mismatch с source: :address" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первое"), rename("Второе"), freeze()])

          assert {:error, %Error{module: @error_module, code: :version_mismatch} = error} =
                   @read_repo_impl.get_at(id, Version.new!(4), Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 4, actual: 3, source: :address}
        end

        test "пустой поток — :version_mismatch с actual: nil и source: :address" do
          id = Account.ID.new()

          assert {:error, %Error{module: @error_module, code: :version_mismatch} = error} =
                   @read_repo_impl.get_at(id, Version.new!(1), Context.new())

          assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: nil, source: :address}
        end

        test ":current вместо версии — FunctionClauseError" do
          id = Account.ID.new()

          assert_raise FunctionClauseError, fn ->
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            apply(@read_repo_impl, :get_at, [id, :current, Context.new()])
          end
        end

        test "telemetry: load с op: :get_at и свёртка потока" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первое"), rename("Второе"), freeze()])
          attach_read_telemetry()

          assert {:ok, %View{version: 2}} = @read_repo_impl.get_at(id, Version.new!(2), Context.new())

          assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2},
                           %{type: "account", snapshot: @snapshot}}

          assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 2},
                           %{type: "account", op: :get_at, result: :ok}}
        end

        test "telemetry отказа адреса — result: :version_mismatch" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первое")])
          attach_read_telemetry()

          assert {:error, %Error{code: :version_mismatch}} =
                   @read_repo_impl.get_at(id, Version.new!(2), Context.new())

          assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 1, events: 1},
                           %{op: :get_at, result: :version_mismatch}}
        end

        test "уничтоженное ПДн-значение остаётся уничтоженным на любой версии" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первый"), set_holder("Иван Петров"), freeze()])

          assert {:ok, %View{version: 2, holder: %{destroyed: false, value: "Иван Петров"}}} =
                   @read_repo_impl.get_at(id, Version.new!(2), Context.new())

          assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())

          assert {:ok, %View{version: 1, holder: nil}} =
                   @read_repo_impl.get_at(id, Version.new!(1), Context.new())

          assert {:ok, %View{version: 2, holder: %{destroyed: true}}} =
                   @read_repo_impl.get_at(id, Version.new!(2), Context.new())

          assert {:ok, %View{version: 3, holder: %{destroyed: true}}} =
                   @read_repo_impl.get_at(id, Version.new!(3), Context.new())
        end
      end
    end
  end

  defp get_many_at_tests do
    quote do
      describe "контракт Es.Aggregate.ReadRepo: get_many_at" do
        test "представления в порядке пар; разные версии одного id и повтор пары" do
          [first, second] = [Account.ID.new(), Account.ID.new()]
          write!(@write_repo_impl, first, [open("Первый"), rename("Первый-2"), freeze()])
          write!(@write_repo_impl, second, [open("Второй")])

          pairs = [
            {second, Version.new!(1)},
            {first, Version.new!(2)},
            {first, Version.new!(1)},
            {second, Version.new!(1)}
          ]

          assert {:ok, [second_one, first_two, first_one, second_repeat]} =
                   @read_repo_impl.get_many_at(pairs, Context.new())

          assert %View{id: second_id, version: 1, name: "Второй", status: "open"} = second_one
          assert %View{id: first_id, version: 2, name: "Первый-2", status: "open"} = first_two
          assert %View{id: ^first_id, version: 1, name: "Первый", status: "open"} = first_one
          assert %View{id: ^second_id, version: 1} = second_repeat
          assert second_repeat == second_one
          assert first_id == Core.Prim.unwrap(first)
          assert second_id == Core.Prim.unwrap(second)
        end

        test "все расхождения — одна :version_mismatch со списком detail в порядке пар" do
          [first, second, empty] = [Account.ID.new(), Account.ID.new(), Account.ID.new()]
          write!(@write_repo_impl, first, [open("Первый")])
          write!(@write_repo_impl, second, [open("Второй"), freeze()])

          pairs = [
            {first, Version.new!(2)},
            {second, Version.new!(1)},
            {empty, Version.new!(1)},
            {first, Version.new!(2)}
          ]

          assert {:error, %Error{module: @error_module, code: :version_mismatch} = error} =
                   @read_repo_impl.get_many_at(pairs, Context.new())

          assert error.detail == [
                   %{aggregate_id: dump(first), expected: 2, actual: 1, source: :address},
                   %{aggregate_id: dump(empty), expected: 1, actual: nil, source: :address},
                   %{aggregate_id: dump(first), expected: 2, actual: 1, source: :address}
                 ]
        end

        test "пустой пакет — пустой результат без запросов" do
          assert {{:ok, []}, 0} =
                   count_queries(fn -> @read_repo_impl.get_many_at([], Context.new()) end)
        end

        test ":current в элементе — FunctionClauseError" do
          id = Account.ID.new()

          assert_raise FunctionClauseError, fn ->
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            apply(@read_repo_impl, :get_many_at, [[{id, :current}], Context.new()])
          end
        end

        test "поток каждого id — одним запросом на пакет" do
          ids = for _ <- 1..3, do: Account.ID.new()
          Enum.each(ids, &write!(@write_repo_impl, &1, [open()]))
          pairs = Enum.map(ids, &{&1, Version.new!(1)})

          assert {{:ok, [_, _, _]}, 1} =
                   count_queries(fn -> @read_repo_impl.get_many_at(pairs, Context.new()) end, :select)
        end

        test "telemetry: один load на пакет с op: :get_many_at и свёртка каждого потока" do
          [first, second] = [Account.ID.new(), Account.ID.new()]
          write!(@write_repo_impl, first, [open("Первый"), rename("Первый-2"), freeze()])
          write!(@write_repo_impl, second, [open("Второй")])
          attach_read_telemetry()

          pairs = [{first, Version.new!(2)}, {second, Version.new!(1)}]

          assert {:ok, [%View{version: 2}, %View{version: 1}]} =
                   @read_repo_impl.get_many_at(pairs, Context.new())

          assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 2},
                           %{type: "account", snapshot: @snapshot}}

          assert_received {:telemetry, [:core, :es, :aggregate, :fold], %{events: 1},
                           %{type: "account", snapshot: @snapshot}}

          assert_received {:telemetry, [:core, :es, :aggregate, :load], %{streams: 2, events: 3},
                           %{type: "account", op: :get_many_at, result: :ok}}
        end

        test "чтение пакета не пишет снапшоты" do
          id = Account.ID.new()
          write!(@write_repo_impl, id, [open("Первый"), rename("Второй"), freeze()])
          attach_read_telemetry()

          pairs = [{id, Version.new!(1)}, {id, Version.new!(3)}]

          assert {:ok, [%View{version: 1}, %View{version: 3}]} =
                   @read_repo_impl.get_many_at(pairs, Context.new())

          refute_received {:telemetry, [:core, :es, :snapshot, :write], _measurements, _metadata}
        end
      end
    end
  end

  # ===== команды =====

  @doc "Команда «назначить владельца счёта»."
  @spec set_holder(String.t()) :: Account.Cmd.t()

  def set_holder(value),
    do: %Account.Cmd.SetHolder{
      holder: Account.Holder.new!(value),
      by: UserID.new(),
      at: Es.Event.At.new!(~U[2026-09-01 10:00:00Z])
    }

  # ===== telemetry =====

  @doc "Подписать тест на telemetry загрузки и свёртки."
  @spec attach_read_telemetry() :: :ok

  def attach_read_telemetry do
    handler = {__MODULE__, make_ref()}

    events = [
      Telemetry.event([:es, :aggregate, :load]),
      Telemetry.event([:es, :aggregate, :fold]),
      Telemetry.event([:es, :snapshot, :write])
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_read_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  @spec handle_read_telemetry([atom()], map(), map(), pid()) :: :ok

  def handle_read_telemetry(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
    :ok
  end
end
