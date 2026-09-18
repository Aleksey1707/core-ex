defmodule Core.Es.TransactTest do
  use Core.DataCase, async: true

  import ExUnit.CaptureLog

  alias Core.Error
  alias Core.Es
  alias Core.EsFixture
  alias Core.Helper.Transact

  require Error

  @aggregate_id "01a0b23b-fb87-786a-9ea7-ed1aca28440a"

  describe "run/2" do
    test "без отказа — результат fun одной попыткой" do
      log = capture_at(:debug, fn -> assert Es.Transact.run(fn -> {:ok, :done} end) == {:ok, :done} end)

      refute log =~ "повтор"
    end

    test "отказ хранилища — повтор новой транзакцией до успеха, debug на каждый повтор" do
      fun = refusing(2, :storage)

      log = capture_at(:debug, fn -> assert Es.Transact.run(fun) == :ok end)

      assert log =~
               "транзакция команды: повтор после отказа записи: " <>
                 "aggregate_id=#{@aggregate_id} retry=1"

      assert log =~ "retry=2"
      refute log =~ "retry=3"
    end

    test "исчерпание retries: — warning и ошибка последней попытки" do
      fun = refusing(5, :storage)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :version_mismatch}} = Es.Transact.run(fun, retries: 2)
        end)

      assert log =~
               "транзакция команды: повторы после отказа записи исчерпаны: " <>
                 "aggregate_id=#{@aggregate_id} retries=2"
    end

    test "сверка ожидаемой версии — без повтора" do
      fun = refusing(1, :expected)

      log = capture_at(:debug, fn -> assert {:error, %Error{}} = Es.Transact.run(fun) end)

      refute log =~ "повтор"
    end

    test "список detail — без повтора" do
      detail = [mismatch_detail(:storage), mismatch_detail(:storage)]
      fun = fn -> {:error, version_mismatch(detail)} end

      log = capture_at(:debug, fn -> assert {:error, %Error{}} = Es.Transact.run(fun) end)

      refute log =~ "повтор"
    end

    test "detail без source: — без повтора" do
      detail = %{aggregate_id: @aggregate_id, expected: 2, actual: 1}
      fun = fn -> {:error, version_mismatch(detail)} end

      log = capture_at(:debug, fn -> assert {:error, %Error{}} = Es.Transact.run(fun) end)

      refute log =~ "повтор"
    end

    test "ошибка не %Error{} и другой код — как есть, без повтора" do
      log =
        capture_at(:debug, fn ->
          assert Es.Transact.run(fn -> {:error, :expired} end) == {:error, :expired}

          assert {:error, %Error{code: :not_found}} =
                   Es.Transact.run(fn -> {:error, not_found()} end)
        end)

      refute log =~ "повтор"
    end

    test "неудачная попытка откатывается целиком" do
      fun = refusing(1, :storage, fn -> write_row("попытка") end)

      assert capture_at(:debug, fn -> assert Es.Transact.run(fun) == :ok end) =~ "retry=1"
      assert names() == ["попытка"]
    end
  end

  describe "run_counted/2" do
    test "число повторов — измерение telemetry вызывающего" do
      assert Es.Transact.run_counted(fn -> :ok end) == {:ok, 0}

      assert capture_at(:debug, fn -> assert Es.Transact.run_counted(refusing(2, :storage)) == {:ok, 2} end) =~
               "retry=2"
    end
  end

  describe "ошибки программиста" do
    test "внутри транзакции — ArgumentError" do
      assert_raise ArgumentError, ~r/run вызван внутри транзакции/, fn ->
        Transact.run(TestRepo, fn -> Es.Transact.run(fn -> :ok end) end)
      end
    end

    test "retries: не положительное целое — ArgumentError" do
      assert_raise ArgumentError, ~r/:retries — ожидается положительное целое, получено 0/, fn ->
        Es.Transact.run(fn -> :ok end, retries: 0)
      end
    end

    test "неизвестная опция — ArgumentError" do
      assert_raise ArgumentError, fn -> Es.Transact.run(fn -> :ok end, limit: 1) end
    end
  end

  # Тело попытки: первые `count` раз отказывает отказом `source`, дальше — `:ok`. Счётчик
  # переживает откат транзакции — он в процессе, а не в базе.
  defp refusing(count, source, before \\ fn -> :ok end) do
    counter = :atomics.new(1, [])
    :atomics.put(counter, 1, count)

    fn ->
      :ok = before.()

      if :atomics.sub_get(counter, 1, 1) >= 0,
        do: {:error, version_mismatch(mismatch_detail(source))},
        else: :ok
    end
  end

  defp mismatch_detail(source),
    do: %{aggregate_id: @aggregate_id, expected: 2, actual: 1, source: source}

  defp version_mismatch(detail) do
    Error.domain(
      code: :version_mismatch,
      ns: :es,
      message: "Версия агрегата не совпадает с ожидаемой",
      detail: detail
    )
  end

  defp not_found, do: Error.domain(code: :not_found, ns: :es, message: "Не найдено")

  defp write_row(name) do
    row = %{
      aggregate_type: "transact",
      aggregate_id: Ecto.UUID.generate(),
      name: name,
      closed: false
    }

    {1, nil} = TestRepo.insert_all(EsFixture.Projection.Row, [row])
    :ok
  end

  defp names, do: TestRepo.all(from(r in EsFixture.Projection.Row, select: r.name))

  # Уровень логов тестов — `:warning`: `debug` модуля виден только с его уровнем.
  defp capture_at(level, fun) do
    Logger.put_module_level(Es.Transact, level)

    try do
      capture_log(fun)
    after
      Logger.delete_module_level(Es.Transact)
    end
  end
end
