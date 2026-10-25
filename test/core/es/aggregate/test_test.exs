defmodule Core.Es.Aggregate.TestTest do
  use ExUnit.Case, async: true

  import Core.Es.Aggregate.Test, only: [given: 3]

  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Event
  alias Core.EsFixture.UserID
  alias Core.EventFixture
  alias Core.Version

  @at Es.Event.At.new!(~U[2026-09-01 10:00:00Z])

  describe "given/3" do
    test "состояние после результатов decide/2: id из состояния, версии с 1" do
      id = Account.ID.new()
      name = Account.Name.new!("Приёмка")
      results = [{Event.Opened, Event.Opened.Payload.new(name)}, Event.Frozen]

      state = given(%Account{id: id}, results, by: UserID.new(), at: @at)

      assert %Account{id: ^id, name: ^name, status: :frozen} = state
      assert state.version == Version.new!(2)
    end

    test "цепочка разных авторов — версии продолжаются от state.version" do
      name = Account.Name.new!("Приёмка")

      state =
        %Account{id: Account.ID.new()}
        |> given([{Event.Opened, Event.Opened.Payload.new(name)}], by: UserID.new(), at: @at)
        |> given([Event.Frozen, Event.Closed], by: UserID.new(), at: @at)

      assert %Account{status: :closed} = state
      assert state.version == Version.new!(3)
      assert given(state, [], by: UserID.new(), at: @at) == state
    end

    test "by: и at: обязательны" do
      state = %Account{id: Account.ID.new()}

      assert_raise ArgumentError, ~r/^Core\.Es\.Aggregate\.Test\.given\/3: required :by option not found/, fn ->
        given(state, [], at: @at)
      end

      assert_raise ArgumentError, ~r/required :at option not found/, fn -> given(state, [], by: UserID.new()) end
    end

    test "неизвестная опция — ArgumentError" do
      state = %Account{id: Account.ID.new()}

      assert_raise ArgumentError, ~r/^Core\.Es\.Aggregate\.Test\.given\/3: unknown options \[:version\]/, fn ->
        given(state, [], by: UserID.new(), at: @at, version: 1)
      end
    end

    test "at: не Es.Event.At — ArgumentError" do
      assert_raise ArgumentError, ~r/given\/3: invalid value for :at option: expected Core\.Es\.Event\.At/, fn ->
        given(%Account{id: Account.ID.new()}, [], by: UserID.new(), at: ~U[2026-09-01 10:00:00Z])
      end
    end

    test "by: не Prim автора событий или модуль не из кодека агрегата — FunctionClauseError" do
      state = %Account{id: Account.ID.new()}

      assert_raise FunctionClauseError, fn ->
        given(state, [Event.Frozen], by: EventFixture.ActorID.new(), at: @at)
      end

      assert_raise FunctionClauseError, fn ->
        given(state, [EventFixture.Event.Closed], by: UserID.new(), at: @at)
      end
    end
  end
end
