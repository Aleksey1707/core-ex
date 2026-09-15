defmodule Core.Es.AggregateTest do
  use ExUnit.Case, async: true

  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Cmd
  alias Core.EsFixture.Account.Event
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.Version

  @at Es.Event.At.new!(~U[2026-09-01 10:00:00Z])

  defmodule Tampering do
    @moduledoc "Агрегат, чей `evolve/2` пытается сам вести `id` и `version`."

    use Core.Es.Aggregate,
      event_codec: Core.EsFixture.Account.Event.Codec

    defstruct id: nil, version: nil

    @spec decide(struct(), %__MODULE__{}) :: {:ok, [module()]}

    @impl true
    def decide(_command, _state), do: {:ok, [Event.Frozen]}

    @spec evolve(%__MODULE__{}, Event.Frozen.t()) :: %__MODULE__{}

    @impl true
    def evolve(state, %Event.Frozen{}), do: %{state | id: nil, version: Version.new!(99)}
  end

  describe "execute/2" do
    test "создание — событие с id, aggregate_id из состояния, версией 1, by и at из команды" do
      id = Account.ID.new()
      by = UserID.new()
      name = Account.Name.new!("Приёмка")

      assert {:ok, {[event], state}} =
               Account.execute(%Account{id: id}, %Cmd.Open{name: name, by: by, at: @at})

      assert %Event.Opened{
               id: %Es.Event.ID{},
               payload: %Event.Opened.Payload{name: ^name},
               aggregate_id: ^id,
               by: ^by,
               at: @at
             } = event

      assert event.aggregate_version == Version.new!(1)
      assert %Account{id: ^id, name: ^name, status: :open} = state
      assert state.version == Version.new!(1)
    end

    test "версии событий — по порядку от state.version, два события одной команды" do
      opened = opened()

      assert {:ok, {[%Event.Frozen{} = frozen, %Event.Closed{} = closed], state}} =
               Account.execute(opened, close())

      assert [2, 3] == Enum.map([frozen, closed], &Version.value(&1.aggregate_version))
      assert frozen.id != closed.id
      assert %Account{status: :closed} = state
      assert state.version == Version.new!(3)
    end

    test "{:ok, []} — без событий и без роста версии" do
      opened = opened()
      rename = %Cmd.Rename{name: opened.name, by: UserID.new(), at: @at}

      assert {:ok, {[], ^opened}} = Account.execute(opened, rename)
    end

    test "отказ decide/2 — как есть" do
      open = %Cmd.Open{name: Account.Name.new!("Отгрузка"), by: UserID.new(), at: @at}

      assert {:error, %Error{kind: :domain, code: :already_exists}} =
               Account.execute(opened(), open)
    end

    test "id и version состояния ведёт библиотека, а не evolve/2" do
      id = Account.ID.new()

      assert {:ok, {[_frozen], state}} = Tampering.execute(%Tampering{id: id}, close())
      assert %Tampering{id: ^id} = state
      assert state.version == Version.new!(1)
    end
  end

  describe "fold/2" do
    test "свёртка от любого состояния продолжает версии от state.version" do
      opened = opened()
      {:ok, {events, closed}} = Account.execute(opened, close())

      assert Account.fold(opened, events) == closed
      assert Account.fold(opened, []) == opened
    end

    test "разрыв версий — ArgumentError" do
      opened = opened()
      {:ok, {[frozen, closed], _state}} = Account.execute(opened, close())

      assert_raise ArgumentError, ~r/разрыв версий .*ожидалась 2, пришла 3/, fn ->
        Account.fold(opened, [closed])
      end

      assert_raise ArgumentError, ~r/разрыв версий .*ожидалась 1, пришла 2/, fn ->
        Account.fold(%Account{id: opened.id}, [frozen])
      end
    end

    test "чужой aggregate_id — ArgumentError" do
      {:ok, {events, _state}} = Account.execute(opened(), close())

      assert_raise ArgumentError, ~r/событие чужого агрегата/, fn ->
        Account.fold(opened(), events)
      end
    end
  end

  describe "fold/3" do
    test "результат decide/2 — события по команде, состояние после них" do
      opened = opened()
      name = Account.Name.new!("Отгрузка")
      rename = %Cmd.Rename{name: name, by: UserID.new(), at: @at}

      state = Account.fold(opened, rename, [{Event.Renamed, Event.Renamed.Payload.new(name)}])

      assert %Account{name: ^name, status: :open} = state
      assert state.version == Version.new!(2)
    end

    test "модуль события не из кодека агрегата — FunctionClauseError" do
      opened = opened()
      payload = EventFixture.Event.Created.Payload.new(EventFixture.Name.new!("Приёмка"))

      for results <- [[EventFixture.Event.Closed], [{EventFixture.Event.Created, payload}]] do
        assert_raise FunctionClauseError, fn -> Account.fold(opened, close(), results) end
      end
    end
  end

  describe "use Core.Es.Aggregate" do
    test "кодек событий — в интроспекции" do
      assert Account.__es_event_codec__() == Account.Event.Codec
    end

    test "без id или version в defstruct — CompileError" do
      for {name, fields} <- [{NoId, ~w(version name)a}, {NoVersion, ~w(id name)a}] do
        assert_raise CompileError, ~r/обязан объявить \[:id, :version\] в defstruct/, fn ->
          compile(name, [event_codec: Account.Event.Codec], fields)
        end
      end
    end

    test "event_codec: не атом — CompileError" do
      assert_raise CompileError, ~r/event_codec: ожидается атом/, fn ->
        compile(BadCodec, [event_codec: "account"], ~w(id version)a)
      end
    end

    test "без event_codec: — CompileError" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:event_codec\]/, fn ->
        compile(NoCodec, [], ~w(id version)a)
      end
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:snapshot\]/, fn ->
        compile(UnknownOpt, [event_codec: Account.Event.Codec, snapshot: true], ~w(id version)a)
      end
    end
  end

  # ---

  defp opened do
    open = %Cmd.Open{name: Account.Name.new!("Приёмка"), by: UserID.new(), at: @at}
    {:ok, {_events, state}} = Account.execute(%Account{id: Account.ID.new()}, open)
    state
  end

  defp close, do: %Cmd.Close{by: UserID.new(), at: @at}

  defp compile(name, opts, fields) do
    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Es.Aggregate, unquote(opts)

          defstruct unquote(fields)

          @impl true
          def decide(_command, _state), do: {:ok, []}

          @impl true
          def evolve(state, _event), do: state
        end
      end
    )
  end
end
