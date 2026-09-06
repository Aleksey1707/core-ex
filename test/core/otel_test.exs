defmodule Core.OtelTest do
  # Экспортёр span'ов — глобальный ресурс SDK.
  use ExUnit.Case, async: false

  alias Core.Error
  alias Core.Otel
  alias Core.OtelFixture

  require Error

  setup do
    :ok = OtelFixture.attach()
    :ok
  end

  describe "inject/1" do
    test "добавляет traceparent внутри span'а" do
      carrier = Otel.span("cmd", [], fn -> Otel.inject(%{"name" => "created"}) end)

      assert %{"name" => "created", "traceparent" => traceparent} = carrier
      assert traceparent =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$/
    end

    test "вне span'а carrier не меняется" do
      assert Otel.inject(%{"name" => "created"}) == %{"name" => "created"}
    end

    test "снимает поля прежнего контекста" do
      stale = %{"name" => "created", "tracestate" => "vendor=stale", "baggage" => "k=v"}
      carrier = Otel.span("cmd", [], fn -> Otel.inject(stale) end)

      assert carrier["name"] == "created"
      refute Map.has_key?(carrier, "tracestate")
      refute Map.has_key?(carrier, "baggage")
    end
  end

  describe "span/3" do
    test "kind и атрибуты уходят в span как есть" do
      Otel.span("работа", [kind: :producer, attributes: %{"my.attr" => 3}], fn -> :ok end)

      span = OtelFixture.drain() |> OtelFixture.find("работа")

      assert span.kind == :producer
      assert span.attributes["my.attr"] == 3
    end

    test "links ссылаются на переданные контексты, не делая их родителями" do
      linked = Otel.span("linked", [], fn -> Otel.current_span() end)
      first = OtelFixture.drain() |> OtelFixture.find("linked")

      Otel.span("работа", [links: [linked]], fn -> :ok end)

      span = OtelFixture.drain() |> OtelFixture.find("работа")

      assert span.links == [OtelFixture.ref(first)]
      assert span.parent_span_id == :undefined
    end

    test "невалидный контекст в links отбрасывается" do
      Otel.span("работа", [links: [:undefined]], fn -> :ok end)

      span = OtelFixture.drain() |> OtelFixture.find("работа")

      assert span.links == []
    end
  end

  describe "with_span_from/4" do
    test "продолжает трейс из carrier" do
      carrier = Otel.span("cmd", [], fn -> Otel.inject(%{}) end)

      Otel.with_span_from(carrier, "обработка", [kind: :consumer], fn -> :ok end)

      spans = OtelFixture.drain()
      parent = OtelFixture.find(spans, "cmd")
      child = OtelFixture.find(spans, "обработка")

      assert child.trace_id == parent.trace_id
      assert child.parent_span_id == parent.span_id
      assert child.kind == :consumer
    end

    test "возвращает процессу прежний контекст" do
      carrier = Otel.span("cmd", [], fn -> Otel.inject(%{}) end)
      before = Otel.ctx()

      Otel.with_span_from(carrier, "обработка", [], fn -> :ok end)

      assert Otel.ctx() == before
    end
  end

  test "set_attributes дополняет текущий span" do
    Otel.span("работа", [], fn -> Otel.set_attributes(%{"my.attr" => "поздно"}) end)

    span = OtelFixture.drain() |> OtelFixture.find("работа")

    assert span.attributes["my.attr"] == "поздно"
  end

  test "record_error кладёт error.type и цепочку причин в статус" do
    root = Error.app(code: :timeout, ns: :mq, message: "брокер не ответил")

    error =
      Error.domain(code: :not_delivered, ns: :outbox, message: "не доставлено", parent: root)

    Otel.span("работа", [], fn -> Otel.record_error(error) end)

    span = OtelFixture.drain() |> OtelFixture.find("работа")

    assert span.attributes["error.type"] == "outbox/not_delivered"
    assert span.attributes["core.error.kind"] == "domain"
    assert {:error, "не доставлено: брокер не ответил"} = span.status
  end

  test "with_ctx переносит контекст в порождённый процесс" do
    ctx = Otel.span("cmd", [], fn -> Otel.ctx() end)
    parent = OtelFixture.drain() |> OtelFixture.find("cmd")

    task =
      Task.async(fn -> Otel.with_ctx(ctx, fn -> Otel.span("child", [], fn -> :ok end) end) end)

    Task.await(task)

    child = OtelFixture.drain() |> OtelFixture.find("child")

    assert child.trace_id == parent.trace_id
    assert child.parent_span_id == parent.span_id
  end
end
