defmodule Core.Outbox.SingletonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Core.Outbox

  describe "check_singleton!/1" do
    test "выключенный outbox проходит при любой кластеризации" do
      assert :ok = Outbox.check_singleton!(enabled?: false, cluster_query: "app.internal")
      assert :ok = Outbox.check_singleton!(enabled?: false, cluster_query: nil)
    end

    test "выключенный outbox с allow_cluster?: true в кластере проходит без warning" do
      log =
        capture_log(fn ->
          assert :ok = Outbox.check_singleton!(enabled?: false, cluster_query: "app.internal", allow_cluster?: true)
        end)

      refute log =~ "порядок доставки"
    end

    test "включённый outbox без кластеризации проходит молча" do
      for query <- [nil, :ignore, ""] do
        log = capture_log(fn -> assert :ok = Outbox.check_singleton!(enabled?: true, cluster_query: query) end)

        refute log =~ "порядок доставки"
      end
    end

    test "включённый outbox с кластеризацией — отказ с инструкцией" do
      error =
        assert_raise ArgumentError, fn ->
          Outbox.check_singleton!(enabled?: true, cluster_query: "app.internal")
        end

      assert error.message =~ "app.internal"
      assert error.message =~ "OUTBOX_ENABLED"
      assert error.message =~ "allow_cluster?: true"
    end

    test "allow_cluster?: false равносилен отсутствию опции" do
      assert_raise ArgumentError, fn ->
        Outbox.check_singleton!(enabled?: true, cluster_query: "app.internal", allow_cluster?: false)
      end
    end

    test "allow_cluster?: true разрешает старт в кластере с warning" do
      log =
        capture_log(fn ->
          assert :ok =
                   Outbox.check_singleton!(enabled?: true, cluster_query: "app.internal", allow_cluster?: true)
        end)

      assert log =~ "[warning]"
      assert log =~ "порядок доставки между нодами не гарантирован"
      assert log =~ "cluster_query=\"app.internal\""
    end

    test "обязательные опции и неизвестный ключ — отказ" do
      assert_raise KeyError, fn -> Outbox.check_singleton!(cluster_query: nil) end
      assert_raise KeyError, fn -> Outbox.check_singleton!(enabled?: true) end

      assert_raise ArgumentError, fn ->
        Outbox.check_singleton!(enabled?: true, cluster_query: nil, allow_cluster: true)
      end
    end

    test "значение не той формы — отказ" do
      assert_raise FunctionClauseError, fn -> Outbox.check_singleton!(enabled?: "true", cluster_query: nil) end
      assert_raise FunctionClauseError, fn -> Outbox.check_singleton!(enabled?: true, cluster_query: 1) end

      assert_raise FunctionClauseError, fn ->
        Outbox.check_singleton!(enabled?: true, cluster_query: "app.internal", allow_cluster?: "true")
      end
    end
  end
end
