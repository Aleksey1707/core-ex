defmodule Core.Es.Personal.KeyReservationTest do
  use Core.DataCase, async: true

  import Core.EsAggregateRepoContract, only: [close: 0, dump: 1, execute!: 2, open: 1, stream_tags: 1, write!: 3]
  import Ecto.Query, only: [from: 2]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Port
  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID
  alias Core.Helper.Transact

  require Config

  @repo Config.repo!(Account.KeyedRepo)
  @scope "fixture.holder"

  describe "резерв ключа из ПДн" do
    test "в строке — индекс ключа, а не значение; find/2 — по значению" do
      holder = unique_holder()
      id = Account.ID.new()
      write!(@repo, id, [open(unique_name()), set_holder(holder)])
      {:ok, [index]} = Port.index([{@scope, [holder]}])

      assert reservations(id) == [[index]]
      refute index =~ holder
      assert Account.HolderKey.find(Account.Holder.new!(holder), Context.new()) == id
      assert Account.HolderKey.find(Account.Holder.new!(unique_holder()), Context.new()) == nil
    end

    test "ключ другого агрегата — отказ code: с областью в detail, события не записаны" do
      holder = unique_holder()
      [owner, rival] = [Account.ID.new(), Account.ID.new()]
      write!(@repo, owner, [open(unique_name()), set_holder(holder)])
      state = write!(@repo, rival, [open(unique_name())])
      {events, _state} = execute!(state, set_holder(holder))

      assert {:error, %Error{kind: :domain, module: Account.KeyedRepo, code: :holder_taken} = error} =
               @repo.append(events, Context.new())

      assert error.detail == %{scope: @scope}
      assert [_opened] = stream_tags(rival)
      assert Account.HolderKey.find(Account.Holder.new!(holder), Context.new()) == owner
    end

    test ":release в транзакции destroy_key/3 освобождает ключ, и его занимает другой агрегат" do
      holder = unique_holder()
      [owner, rival] = [Account.ID.new(), Account.ID.new()]
      state = write!(@repo, owner, [open(unique_name()), set_holder(holder)])
      {closed, _state} = execute!(state, close())

      assert :ok =
               Transact.run(Config.dao(), fn ->
                 with :ok <- Personal.destroy_key(owner, UserID.new(), Context.new()),
                      do: @repo.append(closed, Context.new())
               end)

      assert reservations(owner) == []
      assert Account.HolderKey.find(Account.Holder.new!(holder), Context.new()) == nil

      write!(@repo, rival, [open(unique_name()), set_holder(holder)])
      assert Account.HolderKey.find(Account.Holder.new!(holder), Context.new()) == rival
    end

    test "Prim personal: true у модуля ключа без флага — ArgumentError на append" do
      repo = compile_repo!(OpenKeyRepo, compile_key!(OpenKey))
      holder = unique_holder()
      state = write!(repo, Account.ID.new(), [open(unique_name())])
      {events, _state} = execute!(state, set_holder(holder))

      message = ~r/OpenKey: \{:reserve, value\} с Prim personal: true .*Account\.Holder.* без personal: true/

      assert_raise ArgumentError, message, fn -> repo.append(events, Context.new()) end
    end
  end

  describe "сборка модуля ключа" do
    test "personal: — boolean" do
      assert_raise CompileError, ~r/Es\.KeyReservation: personal: ожидается boolean, получено :yes/, fn ->
        compile_key!(NotBoolean, personal: :yes)
      end
    end
  end

  defp unique_holder, do: "Владелец #{System.unique_integer([:positive])}"

  defp unique_name, do: "Счёт #{System.unique_integer([:positive])}"

  defp set_holder(value),
    do: %Account.Cmd.SetHolder{holder: Account.Holder.new!(value), by: UserID.new(), at: Es.Event.At.now!()}

  defp reservations(id) do
    aggregate_id = dump(id)

    from(r in Es.KeyReservation.Schema, where: r.scope == @scope and r.aggregate_id == ^aggregate_id, select: r.key)
    |> Config.dao().all()
  end

  defp compile_key!(name, opts \\ []) do
    module = Module.concat(__MODULE__, name)
    opts = [scope: "fixture.open_holder.#{name}", event: Account.Event, id: Account.ID, code: :holder_taken] ++ opts

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.KeyReservation, unquote(opts)

          def reservation(%Core.EsFixture.Account.Event.HolderSet{payload: payload}), do: {:reserve, payload.holder}
          def reservation(_event), do: :keep
          def to_key(holder), do: Core.EsFixture.Account.Holder.value(holder)
        end
      end
    )

    module
  end

  defp compile_repo!(name, key) do
    module = Module.concat(__MODULE__, name)

    opts = [
      behaviour: Account.KeyedRepo,
      aggregate: Account,
      id: Account.ID,
      errors: Account.Errors,
      outbox: Account.Outbox,
      key_reservations: [key]
    ]

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Aggregate.Repo.Pg, unquote(opts)
        end
      end
    )

    module
  end
end
