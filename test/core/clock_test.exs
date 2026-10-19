defmodule Core.ClockTest do
  use ExUnit.Case, async: true

  alias Core.Clock

  defmodule At do
    use Core.Prim.DateTime,
      name: "Момент",
      precision: :microsecond
  end

  defmodule Day do
    use Core.Prim.Date, name: "День"
  end

  @at ~U[2026-03-01 10:00:00.000000Z]

  describe "freeze/1" do
    test "now/0 Prim видит остановленное время в поясе Prim" do
      :ok = Clock.Test.freeze(@at)

      assert {:ok, %At{value: value}} = At.now()
      assert DateTime.compare(value, @at) == :eq
      assert value.time_zone == Application.fetch_env!(:core, :tz)
    end

    test "today/0 Prim даты — дата остановленного времени в поясе Prim" do
      :ok = Clock.Test.freeze(~U[2026-03-01 20:00:00Z])

      assert {:ok, %Day{value: ~D[2026-03-02]}} = Day.today()
    end
  end

  describe "advance/1" do
    test "сдвигает остановленное время на Duration и на keyword" do
      :ok = Clock.Test.freeze(@at)

      :ok = Clock.Test.advance(Duration.new!(hour: 1))
      assert At.now!().value |> DateTime.compare(~U[2026-03-01 11:00:00Z]) == :eq

      :ok = Clock.Test.advance(minute: 30, second: 5)
      assert At.now!().value |> DateTime.compare(~U[2026-03-01 11:30:05Z]) == :eq
    end

    test "без freeze — ошибка программиста" do
      assert_raise ArgumentError, ~r/freeze/, fn -> Clock.Test.advance(minute: 1) end
    end
  end

  describe "кто видит время владельца" do
    test "Task — через $callers, без настройки" do
      :ok = Clock.Test.freeze(@at)

      assert Task.await(Task.async(fn -> Clock.now() end)) == @at
      assert %At{value: value} = Task.await(Task.async(fn -> At.now!() end))
      assert DateTime.compare(value, @at) == :eq
    end

    test "процесс вне $callers — после allow/2" do
      :ok = Clock.Test.freeze(@at)
      pid = spawn_receiver()

      refute ask_now(pid) == @at

      :ok = Clock.Test.allow(self(), pid)
      assert ask_now(pid) == @at

      :ok = Clock.Test.advance(day: 1)
      assert ask_now(pid) == ~U[2026-03-02 10:00:00.000000Z]
    end

    test "allow/2 из Task открывает время владельца теста, а не своё" do
      :ok = Clock.Test.freeze(@at)
      pid = spawn_receiver()

      task_now =
        Task.await(
          Task.async(fn ->
            :ok = Clock.Test.allow(self(), pid)
            Clock.now()
          end)
        )

      assert task_now == @at
      assert ask_now(pid) == @at
    end

    test "allow/2 до freeze — процесс видит время, остановленное позже" do
      pid = spawn_receiver()
      :ok = Clock.Test.allow(self(), pid)

      :ok = Clock.Test.freeze(@at)
      assert ask_now(pid) == @at
    end

    test "параллельный тест не видит чужое время" do
      :ok = Clock.Test.freeze(@at)
      parent = self()

      spawn(fn ->
        :ok = Clock.Test.freeze(~U[2000-01-01 00:00:00Z])
        send(parent, {:other, Clock.now()})
      end)

      assert_receive {:other, ~U[2000-01-01 00:00:00.000000Z]}
      assert Clock.now() == @at
    end
  end

  describe "без freeze" do
    test "реальное время в UTC с микросекундами" do
      before = DateTime.utc_now()
      now = Clock.now()

      assert %DateTime{time_zone: "Etc/UTC", microsecond: {_, 6}} = now
      assert DateTime.compare(now, before) in [:gt, :eq]
      assert DateTime.diff(now, before, :second) < 5
    end
  end

  # ---

  defp spawn_receiver do
    spawn_link(fn -> receive_loop() end)
  end

  defp receive_loop do
    receive do
      {:now, from} ->
        send(from, {:now, Clock.now()})
        receive_loop()
    end
  end

  defp ask_now(pid) do
    send(pid, {:now, self()})
    assert_receive {:now, now}
    now
  end
end

defmodule Core.ClockGlobalTest do
  # Глобальный режим виден всем процессам VM: параллельный тест увидел бы это время.
  use ExUnit.Case, async: false

  alias Core.Clock

  @at ~U[2026-03-01 10:00:00.000000Z]

  test "глобальный режим — время владельца видят все процессы" do
    :ok = Clock.Test.global()
    on_exit(&Clock.Test.private/0)
    :ok = Clock.Test.freeze(@at)
    parent = self()

    spawn(fn -> send(parent, {:now, Clock.now()}) end)

    assert_receive {:now, @at}
  end

  test "private/0 возвращает частный режим: другие процессы видят реальное время" do
    :ok = Clock.Test.global()
    on_exit(&Clock.Test.private/0)
    :ok = Clock.Test.freeze(@at)
    parent = self()

    :ok = Clock.Test.private()
    spawn(fn -> send(parent, {:now, Clock.now()}) end)

    assert_receive {:now, now}
    refute now == @at
    assert Clock.now() == @at
  end

  test "выход владельца глобального режима возвращает частный" do
    on_exit(&Clock.Test.private/0)
    parent = self()

    owner =
      spawn(fn ->
        :ok = Clock.Test.global()
        :ok = Clock.Test.freeze(@at)
        send(parent, :frozen)
        receive do: (:stop -> :ok)
      end)

    assert_receive :frozen
    assert Clock.now() == @at

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    refute Clock.now() == @at
  end
end
