defmodule Core.Otel.LogFilterTest do
  use ExUnit.Case, async: true

  alias Core.Otel

  @event %{level: :info, meta: %{application: :core}, msg: {:string, "сообщение создано"}}

  test "внутри span'а в metadata появляются trace_id и span_id" do
    event = Otel.span("cmd", [], fn -> Otel.LogFilter.filter(@event, []) end)

    assert %{meta: %{trace_id: trace_id, span_id: span_id}} = event
    assert trace_id =~ ~r/^[0-9a-f]{32}$/
    assert span_id =~ ~r/^[0-9a-f]{16}$/
  end

  test "прочая metadata сохраняется" do
    event = Otel.span("cmd", [], fn -> Otel.LogFilter.filter(@event, []) end)

    assert event.meta.application == :core
    assert event.msg == @event.msg
    assert event.level == :info
  end

  test "вне span'а запись не меняется" do
    assert Otel.LogFilter.filter(@event, []) == @event
  end
end
