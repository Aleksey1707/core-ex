defmodule Core.Es.KeyReservationTest do
  use Core.DataCase, async: true

  import Core.EsAggregateRepoContract,
    only: [close: 0, dump: 1, execute!: 2, freeze: 0, open: 1, outbox_names: 1, rename: 1, stream_tags: 1, write!: 3]

  import Ecto.Query, only: [from: 2]

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.Catalog
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.Version

  require Config

  @repo Config.repo!(Account.KeyedRepo)
  @catalog_repo Config.repo!(Catalog.Repo)
  @scope "fixture.name"

  describe "резерв" do
    test "занятый ключ — id агрегата в find, свободный — nil" do
      [name, free] = [unique_name(), unique_name()]
      id = Account.ID.new()
      write!(@repo, id, [open(name)])

      assert Account.NameKey.find(Account.Name.new!(name), Context.new()) == id
      assert Account.NameKey.find(Account.Name.new!(free), Context.new()) == nil
    end

    test "ключ другого агрегата — отказ code: с областью в detail; события и outbox не записаны" do
      name = unique_name()
      [owner, rival] = [Account.ID.new(), Account.ID.new()]
      write!(@repo, owner, [open(name)])
      {events, _state} = execute!(%Account{id: rival}, open(name))

      assert {:error, %Error{kind: :domain, module: Account.KeyedRepo, code: :name_taken} = error} =
               @repo.append(events, Context.new())

      assert error.detail == %{scope: @scope}
      assert stream_tags(rival) == []
      assert outbox_names(rival) == []
      assert Account.NameKey.find(Account.Name.new!(name), Context.new()) == owner
    end

    test "события пишутся до резервов: устаревшая команда с занятым ключом — :version_mismatch" do
      name = unique_name()
      id = Account.ID.new()
      write!(@repo, Account.ID.new(), [open(name)])
      write!(@repo, id, [open(unique_name())])
      {stale, _state} = execute!(%Account{id: id}, open(name))

      assert {:error, %Error{code: :version_mismatch}} = @repo.append(stale, Context.new())
    end

    test "повторный резерв ключа тем же агрегатом — успех" do
      name = unique_name()
      id = Account.ID.new()
      opened = write!(@repo, id, [open(name)])

      assert :ok = @repo.append([renamed(opened, name)], Context.new())
      assert reservations(id) == [[name]]
    end

    test "перенос ключа — прежний свободен для другого агрегата" do
      [old, new] = [unique_name(), unique_name()]
      [first, second] = [Account.ID.new(), Account.ID.new()]
      write!(@repo, first, [open(old), rename(new)])
      write!(@repo, second, [open(old)])

      assert reservations(first) == [[new]]
      assert reservations(second) == [[old]]
    end

    test ":keep не трогает ключ, :release снимает — ключ свободен для другого агрегата" do
      name = unique_name()
      [first, second] = [Account.ID.new(), Account.ID.new()]

      write!(@repo, first, [open(name), freeze()])
      assert reservations(first) == [[name]]

      write!(@repo, first, [close()])
      assert reservations(first) == []

      write!(@repo, second, [open(name)])
      assert reservations(second) == [[name]]
    end

    test "пачка одного потока — в таблице только последний ключ" do
      [first, second] = [unique_name(), unique_name()]
      id = Account.ID.new()
      {opened, state} = execute!(%Account{id: id}, open(first))
      {renamed, _state} = execute!(state, rename(second))

      assert :ok = @repo.append(opened ++ renamed, Context.new())
      assert reservations(id) == [[second]]
    end

    test "события пачки — в её порядке: обмен ключами двух агрегатов через третий ключ" do
      [x, y, z] = [unique_name(), unique_name(), unique_name()]
      [a, b] = [Account.ID.new(), Account.ID.new()]
      a_state = write!(@repo, a, [open(x)])
      b_state = write!(@repo, b, [open(y)])
      {a_parked, a_state} = execute!(a_state, rename(z))
      {b_moved, _b_state} = execute!(b_state, rename(x))
      {a_moved, _a_state} = execute!(a_state, rename(y))

      assert :ok = @repo.append(a_parked ++ b_moved ++ a_moved, Context.new())
      assert reservations(a) == [[y]]
      assert reservations(b) == [[x]]
    end

    test "освобождение ключа видно шагам после него: та же пачка в двух порядках" do
      [name, other] = [unique_name(), unique_name()]
      [taker, owner] = [Account.ID.new(), Account.ID.new()]
      taker_state = write!(@repo, taker, [open(other)])
      owner_state = write!(@repo, owner, [open(name)])
      {renamed, _state} = execute!(taker_state, rename(name))
      {closed, _state} = execute!(owner_state, close())

      assert {:error, %Error{kind: :domain, module: Account.KeyedRepo, code: :name_taken}} =
               @repo.append(renamed ++ closed, Context.new())

      assert reservations(taker) == [[other]]
      assert reservations(owner) == [[name]]

      assert :ok = @repo.append(closed ++ renamed, Context.new())
      assert reservations(taker) == [[name]]
      assert reservations(owner) == []
    end

    test "агрегаты разных видов в общей области: строка и список из одной части — один ключ" do
      name = unique_name()
      write!(@repo, Account.ID.new(), [open(name)])
      catalog = EventFixture.AggID.new()

      assert {:error, %Error{module: Catalog.Repo, code: :name_taken} = error} =
               @catalog_repo.append(create(catalog, name), Context.new())

      assert error.detail == %{scope: @scope}
      assert reservations(catalog) == []
    end

    test "составной ключ: части не склеиваются" do
      prefix = unique_name()
      [first, second, account] = [EventFixture.AggID.new(), EventFixture.AggID.new(), Account.ID.new()]

      assert :ok = @catalog_repo.append(create(first, "#{prefix}x:y/z"), Context.new())
      assert :ok = @catalog_repo.append(create(second, "#{prefix}x/y:z"), Context.new())
      write!(@repo, account, [open("#{prefix}x:y/z")])

      assert reservations(first) == [["#{prefix}x:y", "z"]]
      assert reservations(second) == [["#{prefix}x", "y:z"]]
      assert Catalog.PathKey.find(EventFixture.Name.new!("#{prefix}x/y:z"), Context.new()) == second
      assert Account.NameKey.find(Account.Name.new!("#{prefix}x:y/z"), Context.new()) == account
    end
  end

  describe "разбор отказа вставки" do
    test "строка нашего ключа называет владельца" do
      key = ["Приёмка"]

      assert Es.KeyReservation.outcome([%{key: key, mine?: true}], key, 0) == :ok
      assert Es.KeyReservation.outcome([%{key: key, mine?: false}], key, 0) == :taken
    end

    test "владелец назван и при занятой нашей паре — она разбору не мешает" do
      key = ["Приёмка"]
      rows = [%{key: ["Отгрузка"], mine?: true}, %{key: key, mine?: false}]

      assert Es.KeyReservation.outcome(rows, key, 0) == :taken
    end

    test "строки нашего ключа нет — повтор, пока есть попытки" do
      key = ["Приёмка"]

      assert Es.KeyReservation.outcome([], key, 0) == :retry
      assert Es.KeyReservation.outcome([%{key: ["Отгрузка"], mine?: true}], key, 0) == :retry
    end

    test "попытки исчерпаны — причина отказа в исходе" do
      key = ["Приёмка"]
      pair = [%{key: ["Отгрузка"], mine?: true}]

      assert Es.KeyReservation.outcome([], key, 1) == {:unresolved, :key_vanished}
      assert Es.KeyReservation.outcome(pair, key, 1) == {:unresolved, :pair_taken}
    end
  end

  describe "сборка модуля ключа" do
    test "обязательные и неизвестные опции" do
      assert_raise CompileError, ~r/Es\.KeyReservation: нет обязательных опций: \[:code\]/, fn ->
        compile_key!(NoCode, code: :__drop__)
      end

      assert_raise CompileError, ~r/Es\.KeyReservation: неизвестные опции: \[:codec\]/, fn ->
        compile_key!(UnknownOpt, codec: Core.CodecFixture.Internal)
      end
    end

    test "scope: — непустая строка" do
      assert_raise CompileError, ~r/Es\.KeyReservation: scope: ожидается непустая строка, получено ""/, fn ->
        compile_key!(EmptyScope, scope: "")
      end

      assert_raise CompileError, ~r/Es\.KeyReservation: scope: ожидается строка, получено :name/, fn ->
        compile_key!(AtomScope, scope: :name)
      end
    end

    test "event: и id: — модули, code: — атом" do
      assert_raise CompileError, ~r/Es\.KeyReservation: event: ожидается модуль, получено "event"/, fn ->
        compile_key!(StringEvent, event: "event")
      end

      assert_raise CompileError, ~r/Es\.KeyReservation: id: ожидается модуль, получено 1/, fn ->
        compile_key!(IntegerId, id: 1)
      end

      assert_raise CompileError, ~r/Es\.KeyReservation: code: ожидается атом, получено "name_taken"/, fn ->
        compile_key!(StringCode, code: "name_taken")
      end

      assert_raise CompileError, ~r/Es\.KeyReservation: code: :version_mismatch — код конфликта записи/, fn ->
        compile_key!(ConflictCode, code: :version_mismatch)
      end
    end
  end

  describe "сборка репозитория с key_reservations:" do
    test "список модулей ключа" do
      assert_raise CompileError,
                   ~r/Es\.Aggregate\.Repo\.Pg: key_reservations: ожидается список модулей ключа, получено Core/,
                   fn -> compile_repo!(NotList, Account.NameKey) end

      message = ~r/key_reservations: модуль .*Account\.Errors должен экспортировать __es_key_reservation__\/0/

      assert_raise CompileError, message, fn -> compile_repo!(NotKey, [Account.Errors]) end
    end

    test "событие модуля ключа — семейство кодека агрегата" do
      message =
        ~r/key_reservations: событие Core\.EventFixture\.Event у .*PathKey не равно семейству кодека .*Account\.Event$/

      assert_raise CompileError, message, fn -> compile_repo!(ForeignEvent, [Catalog.PathKey]) end
    end

    test "id: модуля ключа — id: репозитория" do
      compile_key!(ForeignIdKey, id: UserID)

      message =
        ~r/key_reservations: id: Core\.EsFixture\.UserID у .*ForeignIdKey не равен id: Core\.EsFixture\.Account\.ID/

      assert_raise CompileError, message, fn ->
        compile_repo!(ForeignId, [Module.concat(__MODULE__, ForeignIdKey)])
      end
    end

    test "clause code: модуля ключа в errors:" do
      compile_key!(UnknownCodeKey, code: :login_taken)

      message =
        ~r/errors: отсутствует clause для :login_taken в Core\.EsFixture\.Account\.Errors \(code: у .*UnknownCodeKey\)/

      assert_raise CompileError, message, fn ->
        compile_repo!(UnknownCode, [Module.concat(__MODULE__, UnknownCodeKey)])
      end
    end

    test "область не повторяется" do
      compile_key!(SameScopeKey, [])

      message =
        ~r/key_reservations: область "fixture\.name" повторяется: \[Core\.EsFixture\.Account\.NameKey, .*SameScopeKey\]/

      assert_raise CompileError, message, fn ->
        compile_repo!(SameScope, [Account.NameKey, Module.concat(__MODULE__, SameScopeKey)])
      end
    end
  end

  defp unique_name, do: "Счёт #{System.unique_integer([:positive])}"

  # Переименование в то же название: `decide` такое событие не выпускает.
  defp renamed(%Account{id: id, version: version}, name) do
    payload = Account.Event.Renamed.Payload.new(Account.Name.new!(name))
    next = Version.new!(Version.value(version) + 1)
    Account.Event.Renamed.new(payload, id, next, UserID.new(), Es.Event.At.now!())
  end

  defp create(id, path) do
    command = %Catalog.Cmd.Create{
      path: EventFixture.Name.new!(path),
      by: EventFixture.ActorID.new(),
      at: Es.Event.At.now!()
    }

    {:ok, {events, _state}} = Catalog.execute(%Catalog{id: id}, command)
    events
  end

  defp reservations(id) do
    aggregate_id = dump(id)

    from(r in Es.KeyReservation.Schema, where: r.aggregate_id == ^aggregate_id, select: r.key)
    |> Config.dao().all()
  end

  defp compile_key!(name, overrides) do
    opts =
      [scope: @scope, event: Account.Event, id: Account.ID, code: :name_taken]
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.KeyReservation, unquote(opts)

          def reservation(_event), do: :keep
          def to_key(name), do: Core.EsFixture.Account.Name.value(name)
        end
      end
    )
  end

  defp compile_repo!(name, keys) do
    opts = [
      behaviour: Account.KeyedRepo,
      aggregate: Account,
      id: Account.ID,
      errors: Account.Errors,
      outbox: Account.Outbox,
      key_reservations: keys
    ]

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.Aggregate.Repo.Pg, unquote(opts)
        end
      end
    )
  end
end
