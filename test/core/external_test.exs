defmodule Core.ExternalTest do
  # Экспортёр span'ов и обработчик telemetry — глобальные ресурсы.
  use ExUnit.Case, async: false

  alias Core.External
  alias Core.OtelFixture
  alias Core.Telemetry

  setup do
    :ok = OtelFixture.attach()

    handler_id = "external-#{inspect(self())}"
    events = [Telemetry.event([:external, :call, :stop]), Telemetry.event([:external, :call, :exception])]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, test_pid -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "исход вызова" do
    for {outcome, status} <- [ok: :undefined, rejected: :undefined, timeout: :error, down: :error] do
      test "#{outcome}: span, статус и telemetry" do
        outcome = unquote(outcome)
        result = {:reply, outcome}

        assert External.call(:payment_gateway, :charge, fn -> result end, outcome: fn {:reply, o} -> o end) ==
                 result

        span = OtelFixture.drain() |> OtelFixture.find("payment_gateway charge")

        assert span.kind == :client

        assert Map.drop(span.attributes, ["error.type"]) == %{
                 "core.external.system" => "payment_gateway",
                 "core.external.operation" => "charge",
                 "core.external.outcome" => Atom.to_string(outcome),
                 "peer.service" => "payment_gateway"
               }

        case unquote(status) do
          :error -> assert span.status == {:error, Atom.to_string(outcome)}
          :undefined -> assert span.status == :undefined and not Map.has_key?(span.attributes, "error.type")
        end

        stop = Telemetry.event([:external, :call, :stop])

        assert_receive {:telemetry, ^stop, %{duration: duration},
                        %{system: :payment_gateway, operation: :charge, outcome: ^outcome}}

        assert is_integer(duration)
      end
    end
  end

  test "span вызова — дочерний span'у вызывающего" do
    Core.Otel.span("usecase", [], fn ->
      External.call(:sms, :send, fn -> :ok end, outcome: fn :ok -> :ok end)
    end)

    spans = OtelFixture.drain()
    usecase = OtelFixture.find(spans, "usecase")
    call = OtelFixture.find(spans, "sms send")

    assert call.parent_span_id == usecase.span_id
  end

  describe "исключение" do
    test "повторный raise, исход exception, статус error без текста исключения" do
      assert_raise RuntimeError, "секрет запроса", fn ->
        External.call(:sms, :send, fn -> raise "секрет запроса" end, outcome: fn _ -> :ok end)
      end

      span = OtelFixture.drain() |> OtelFixture.find("sms send")

      assert span.attributes["core.external.outcome"] == "exception"
      assert span.attributes["error.type"] == "RuntimeError"
      assert span.status == {:error, "RuntimeError"}

      stop = Telemetry.event([:external, :call, :stop])
      assert_receive {:telemetry, ^stop, %{duration: _}, %{system: :sms, operation: :send, outcome: :exception}}

      exception = Telemetry.event([:external, :call, :exception])
      refute_received {:telemetry, ^exception, _measurements, _metadata}
    end

    test "exit из вызова — тот же exit" do
      assert catch_exit(External.call(:sms, :send, fn -> exit(:timeout) end, outcome: fn _ -> :ok end)) ==
               :timeout

      span = OtelFixture.drain() |> OtelFixture.find("sms send")

      assert span.attributes["error.type"] == "exit"
      assert span.status == {:error, "exit"}
      assert span.attributes["core.external.outcome"] == "exception"
    end
  end

  describe "ошибка программиста" do
    test "исход вне множества — ArgumentError" do
      assert_raise ArgumentError, ~r/:maybe/, fn ->
        External.call(:sms, :send, fn -> :ok end, outcome: fn _ -> :maybe end)
      end

      exception = Telemetry.event([:external, :call, :exception])
      assert_receive {:telemetry, ^exception, _measurements, %{system: :sms, operation: :send}}
    end

    test "без outcome: — ArgumentError" do
      assert_raise ArgumentError, ~r/outcome/, fn -> External.call(:sms, :send, fn -> :ok end, []) end
    end

    test "неизвестный ключ опций — ArgumentError" do
      assert_raise ArgumentError, ~r"^Core.External.call/4: unknown options \[:classify\]", fn ->
        External.call(:sms, :send, fn -> :ok end, outcome: fn _ -> :ok end, classify: & &1)
      end
    end
  end
end
