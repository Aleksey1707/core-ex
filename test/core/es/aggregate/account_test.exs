defmodule Core.Es.Aggregate.AccountTest do
  use ExUnit.Case, async: true

  import Core.Es.Aggregate.Test, only: [given: 3]

  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.EsFixture.Account.Cmd
  alias Core.EsFixture.Account.Event
  alias Core.EsFixture.UserID
  alias Core.Version

  @at Es.Event.At.new!(~U[2026-09-01 10:00:00Z])

  setup do
    %{id: Account.ID.new(), by: UserID.new()}
  end

  describe "decide/2" do
    test "открыть новый счёт — Opened", %{id: id, by: by} do
      name = name("Приёмка")

      assert {:ok, [{Event.Opened, %Event.Opened.Payload{name: ^name}}]} =
               Account.decide(%Cmd.Open{name: name, by: by, at: @at}, %Account{id: id})
    end

    test "открыть открытый счёт — already_exists", ctx do
      open = %Cmd.Open{name: name("Отгрузка"), by: ctx.by, at: @at}

      assert {:error, %Error{kind: :domain, code: :already_exists}} =
               Account.decide(open, opened(ctx))
    end

    test "команда несуществующему счёту — not_found", %{id: id, by: by} do
      for command <- [
            %Cmd.Rename{name: name("Отгрузка"), by: by, at: @at},
            %Cmd.Freeze{by: by, at: @at},
            %Cmd.Close{by: by, at: @at}
          ] do
        assert {:error, %Error{kind: :domain, code: :not_found}} =
                 Account.decide(command, %Account{id: id})
      end
    end

    test "переименовать в то же название — без событий", ctx do
      assert {:ok, []} =
               Account.decide(
                 %Cmd.Rename{name: name("Приёмка"), by: ctx.by, at: @at},
                 opened(ctx)
               )
    end

    test "переименовать открытый счёт — Renamed", ctx do
      name = name("Отгрузка")

      assert {:ok, [{Event.Renamed, %Event.Renamed.Payload{name: ^name}}]} =
               Account.decide(%Cmd.Rename{name: name, by: ctx.by, at: @at}, opened(ctx))
    end

    test "переименовать замороженный счёт — invalid_status", ctx do
      state = given(opened(ctx), [Event.Frozen], by: ctx.by, at: @at)

      assert {:error, %Error{kind: :domain, code: :invalid_status}} =
               Account.decide(%Cmd.Rename{name: name("Отгрузка"), by: ctx.by, at: @at}, state)
    end

    test "заморозить открытый счёт — Frozen", ctx do
      assert {:ok, [Event.Frozen]} = Account.decide(%Cmd.Freeze{by: ctx.by, at: @at}, opened(ctx))
    end

    test "закрыть открытый счёт — Frozen и Closed", ctx do
      assert {:ok, [Event.Frozen, Event.Closed]} =
               Account.decide(%Cmd.Close{by: ctx.by, at: @at}, opened(ctx))
    end

    test "закрыть замороженный счёт — Closed", ctx do
      state = given(opened(ctx), [Event.Frozen], by: ctx.by, at: @at)

      assert {:ok, [Event.Closed]} = Account.decide(%Cmd.Close{by: ctx.by, at: @at}, state)
    end

    test "закрыть закрытый счёт — invalid_status", ctx do
      state = given(opened(ctx), [Event.Frozen, Event.Closed], by: ctx.by, at: @at)

      assert {:error, %Error{kind: :domain, code: :invalid_status}} =
               Account.decide(%Cmd.Close{by: ctx.by, at: @at}, state)
    end
  end

  describe "evolve/2" do
    test "Opened — счёт открыт с названием", %{id: id, by: by} do
      name = name("Приёмка")
      event = Event.Opened.new(Event.Opened.Payload.new(name), id, Version.new!(1), by, @at)

      assert %Account{id: ^id, name: ^name, status: :open} =
               Account.fold(%Account{id: id}, [event])
    end

    test "Renamed — новое название", ctx do
      name = name("Отгрузка")

      event =
        Event.Renamed.new(Event.Renamed.Payload.new(name), ctx.id, Version.new!(2), ctx.by, @at)

      assert %Account{name: ^name, status: :open} = Account.fold(opened(ctx), [event])
    end

    test "Frozen и Closed — статус счёта", ctx do
      frozen = Event.Frozen.new(ctx.id, Version.new!(2), ctx.by, @at)
      closed = Event.Closed.new(ctx.id, Version.new!(3), ctx.by, @at)

      assert %Account{status: :frozen} = Account.fold(opened(ctx), [frozen])
      assert %Account{status: :closed} = Account.fold(opened(ctx), [frozen, closed])
    end

    test "Verified — удалённый тип: состояние как есть", ctx do
      state = opened(ctx)
      event = Event.Verified.new(ctx.id, Version.new!(2), ctx.by, @at)

      assert Account.fold(state, [event]) == %{state | version: Version.new!(2)}
    end
  end

  # ---

  defp opened(%{id: id, by: by}) do
    payload = Event.Opened.Payload.new(name("Приёмка"))
    given(%Account{id: id}, [{Event.Opened, payload}], by: by, at: @at)
  end

  defp name(value), do: Account.Name.new!(value)
end
