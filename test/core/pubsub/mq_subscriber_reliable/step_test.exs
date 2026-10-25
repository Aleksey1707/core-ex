defmodule Core.PubSub.MqSubscriberReliable.StepTest do
  # Экспортёр span'ов — глобальный ресурс SDK.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Otel
  alias Core.OtelFixture
  alias Core.PubSub.MqSubscriberReliable.Step
  alias Core.Repo

  require Error

  test ":ok обработчика — :processed; on_message получает сообщение, данные и контекст фабрики" do
    parent = self()
    context = Context.new()

    on = fn message, data, ctx ->
      send(parent, {:got, message, data, ctx})
      :ok
    end

    raw = message()
    step = step(on_message: on, data: :data, context_factory: fn -> context end)

    assert :processed = Step.run(raw, step, 1)
    assert_received {:got, ^raw, :data, ^context}
  end

  test "new!/2 по умолчанию пропускает всё и даёт свежий контекст на сообщение" do
    parent = self()

    on = fn _m, data, ctx ->
      send(parent, {:got, data, ctx})
      :ok
    end

    step = Step.new!(topic: "products", from_message: &{:ok, &1}, on_message: on)

    assert :processed = Step.run(message(), step, 1)
    assert_received {:got, nil, %Context{}}
  end

  test "{:skip, _} обработчика — :processed" do
    assert :processed = Step.run(message(), step(on_message: fn _m, _d, _c -> {:skip, :ignored} end), 1)
  end

  test "контекст живёт одно сообщение: эталоны Repo.Sc удалены после обработки" do
    parent = self()

    on = fn _m, _d, ctx ->
      send(parent, {:ctx, ctx})
      :ok
    end

    step = step(on_message: on, context_factory: fn -> Repo.Sc.init(Context.new()) end)

    assert :processed = Step.run(message(), step, 1)
    assert_received {:ctx, ctx}
    assert :ets.info(Context.find(ctx, :shadow_copy)) == :undefined
  end

  describe "основание" do
    test "заголовок operation_id — основание в контексте on_message" do
      operation = Es.Event.OperationID.new()
      headers = %{"name" => "product_created", "operation_id" => Config.codec().dump(operation)}

      assert :processed = Step.run(message(headers), step(on_message: basis_probe()), 1)
      assert_received {:basis, ^operation}
    end

    test "без заголовка operation_id — основания нет" do
      assert :processed = Step.run(message(), step(on_message: basis_probe()), 1)
      assert_received {:basis, nil}
    end

    test "значение заголовка не UUID — основания нет, обработка идёт" do
      headers = %{"name" => "product_created", "operation_id" => "not-a-uuid"}

      log = capture_log(fn -> assert :processed = Step.run(message(headers), step(on_message: basis_probe()), 1) end)

      assert_received {:basis, nil}
      assert log =~ "pubsub reliable basis"
    end
  end

  describe "фильтр" do
    test "false — :filtered без from_message" do
      parent = self()

      from = fn m ->
        send(parent, :decoded)
        {:ok, m}
      end

      assert :filtered = Step.run(message(), step(filter: fn _m -> false end, from_message: from), 1)
      refute_received :decoded
    end

    test "исключение — повтор с ошибкой :handler_crashed" do
      step = step(filter: fn _m -> raise "boom" end)

      log = capture_log(fn -> assert {:retry, %Error{code: :handler_crashed}} = Step.run(message(), step, 1) end)

      assert log =~ "pubsub reliable filter"
    end

    test "не-boolean — повтор с ошибкой :unexpected_handler_result" do
      step = step(filter: fn _m -> :yes end)

      capture_log(fn ->
        assert {:retry, %Error{code: :unexpected_handler_result, detail: :yes}} = Step.run(message(), step, 1)
      end)
    end
  end

  describe "from_message" do
    test "{:error, _} — повтор с этой ошибкой, без on_message" do
      error = fail(:decode)
      step = step(from_message: fn _m -> {:error, error} end, on_message: fn _m, _d, _c -> flunk("on_message") end)

      log = capture_log(fn -> assert {:retry, ^error} = Step.run(message(), step, 1) end)

      assert log =~ "pubsub reliable from_message: boom"
    end

    test "{:reject, _} — отказ без повторов" do
      error = fail(:invariant, "инвариант")

      assert {:reject, ^error} = Step.run(message(), step(from_message: fn _m -> {:reject, error} end), 1)
    end

    test "исключение — повтор с ошибкой :handler_crashed" do
      step = step(from_message: fn _m -> raise "decode boom" end)

      capture_log(fn -> assert {:retry, %Error{code: :handler_crashed}} = Step.run(message(), step, 1) end)
    end

    test "{:reject, _} не с %Error{} — повтор с ошибкой :unexpected_handler_result" do
      step = step(from_message: fn _m -> {:reject, :nope} end)

      capture_log(fn ->
        assert {:retry, %Error{code: :unexpected_handler_result}} = Step.run(message(), step, 1)
      end)
    end
  end

  describe "on_message" do
    test "{:error, _} — повтор с этой ошибкой" do
      error = fail(:fail)

      log =
        capture_log(fn ->
          assert {:retry, ^error} = Step.run(message(), step(on_message: fn _m, _d, _c -> {:error, error} end), 1)
        end)

      assert log =~ "pubsub reliable on_message: boom"
    end

    test "{:reject, _} — отказ без повторов" do
      error = fail(:invariant, "инвариант")

      assert {:reject, ^error} = Step.run(message(), step(on_message: fn _m, _d, _c -> {:reject, error} end), 1)
    end

    test "исключение — повтор с ошибкой :handler_crashed" do
      step = step(on_message: fn _m, _d, _c -> raise "boom" end)

      capture_log(fn ->
        assert {:retry, %Error{code: :handler_crashed, ns: :pubsub}} = Step.run(message(), step, 1)
      end)
    end

    test "неожиданный результат — повтор с ошибкой :unexpected_handler_result" do
      step = step(on_message: fn _m, _d, _c -> :done end)

      capture_log(fn ->
        assert {:retry, %Error{code: :unexpected_handler_result, detail: :done}} = Step.run(message(), step, 1)
      end)
    end
  end

  describe "трассировка" do
    setup do
      :ok = OtelFixture.attach()
      :ok
    end

    test "span обработки продолжает трейс из заголовков и несёт номер попытки" do
      headers = Otel.span("cmd", fn -> Otel.inject(%{"name" => "product_created"}) end)

      assert :processed = Step.run(message(headers), step([]), 3)

      spans = OtelFixture.drain()
      command = OtelFixture.find(spans, "cmd")
      process = OtelFixture.find(spans, "process products")

      assert process.kind == :consumer
      assert process.parent_span_id == command.span_id
      assert process.attributes["messaging.message.id"] == "agg-1"
      assert process.attributes["core.pubsub.attempt"] == 3
    end

    test "исход приходит в fun внутри span'а, ошибка обработчика — статус :error" do
      on = fn _m, _d, _c -> {:reject, fail(:invariant, "инвариант")} end

      fun = fn outcome ->
        Otel.set_attributes(%{"test.outcome" => "reject"})
        {:settled, outcome}
      end

      assert {:settled, {:reject, %Error{code: :invariant}}} = Step.run(message(), step(on_message: on), 1, fun)

      process = OtelFixture.drain() |> OtelFixture.find("process products")

      assert process.attributes["test.outcome"] == "reject"
      assert {:error, "инвариант"} = process.status
      assert process.attributes["error.type"] == "pubsub/invariant"
    end

    test "отфильтрованное сообщение span'а не открывает, исход приходит в fun" do
      assert {:settled, :filtered} = Step.run(message(), step(filter: fn _m -> false end), 1, &{:settled, &1})

      assert OtelFixture.drain() == []
    end
  end

  # ---

  defp step(opts) do
    struct!(
      Step,
      Keyword.merge(
        [
          topic: "products",
          filter: fn _m -> true end,
          from_message: fn m -> {:ok, m} end,
          on_message: fn _m, _d, _c -> :ok end,
          context_factory: &Context.new/0,
          data: nil
        ],
        opts
      )
    )
  end

  defp basis_probe do
    parent = self()

    fn _m, _d, context ->
      send(parent, {:basis, Context.Basis.find(context)})
      :ok
    end
  end

  defp fail(code, message \\ "boom"), do: Error.app(__MODULE__, code: code, ns: :pubsub, message: message)

  defp message(headers \\ %{"name" => "product_created"}) do
    {:ok, message} = Message.new(Mq.Topic.new!("products"), headers, "body", Mq.Key.new!("agg-1"))

    message
  end
end
