defmodule Core.Es.Event.FamilyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Core.Es.Event.Family
  alias Core.EventFixture

  describe "объявление" do
    test "интроспекция — значения опций" do
      assert EventFixture.Event.__es_aggregate__() == Core.StateStoredFixture.Entity
      assert EventFixture.Event.__es_aggregate_id__() == EventFixture.AggID
      assert EventFixture.Event.__es_by__() == EventFixture.ActorID
      assert EventFixture.Event.__es_codec__() == EventFixture.Event.Codec
    end

    test "нет @type t — CompileError" do
      message = ~r/Es\.Event\.Family: .*Untyped не объявляет @type t/

      assert_raise CompileError, message, fn ->
        compile!("""
        defmodule Core.Es.Event.FamilyTest.Untyped do
          use Core.Es.Event.Family,
            aggregate: Core.StateStoredFixture.Entity,
            aggregate_id: Core.EventFixture.AggID,
            by: Core.EventFixture.ActorID,
            codec: Core.EventFixture.Event.Codec
        end
        """)
      end
    end

    test "опции — недостающие и неизвестные одним сообщением" do
      message =
        ~r/Es\.Event\.Family: нет обязательных опций: \[:aggregate, :codec\]; неизвестные опции: \[:event\]$/

      assert_raise CompileError, message, fn ->
        compile!("""
        defmodule Core.Es.Event.FamilyTest.OldForm do
          use Core.Es.Event.Family,
            aggregate_id: Core.EventFixture.AggID,
            by: Core.EventFixture.ActorID,
            event: Core.EventFixture.Event
        end
        """)
      end
    end
  end

  describe "сверки ссылок после сборки" do
    test "верные ссылки — без предупреждений" do
      assert capture_io(:stderr, fn -> Family.__after_verify__(EventFixture.Event) end) == ""
      assert capture_io(:stderr, fn -> Family.__after_verify__(Core.EsFixture.Account.Event) end) == ""
      assert capture_io(:stderr, fn -> Family.__after_verify__(Core.Es.Personal.Event) end) == ""
    end

    test "aggregate: не найден — предупреждение с файлом семейства" do
      output =
        compile_family(Missing, aggregate: Core.Es.Event.FamilyTest.NoSuchAggregate, codec: EventFixture.Event.Codec)

      assert output =~
               ~r/Es\.Event\.Family: .*Missing: aggregate: Core\.Es\.Event\.FamilyTest\.NoSuchAggregate не найден/

      assert output =~ "family_test.exs"
    end

    test "codec: не кодек этого семейства" do
      output = compile_family(ForeignCodec, aggregate: Core.StateStoredFixture.Entity, codec: EventFixture.Event.Codec)

      assert output =~
               ~r/Es\.Event\.Family: .*ForeignCodec: codec: Core\.EventFixture\.Event\.Codec не кодек этого семейства/

      output = compile_family(NotCodec, aggregate: Core.StateStoredFixture.Entity, codec: EventFixture.AggID)

      assert output =~ ~r/NotCodec: codec: Core\.EventFixture\.AggID не кодек этого семейства/
    end

    test "event-sourced владелец объявляет другой event_codec:" do
      output = compile_family(OtherOwner, aggregate: Core.EsFixture.Account, codec: EventFixture.Event.Codec)

      assert output =~
               "OtherOwner: aggregate: Core.EsFixture.Account объявляет event_codec: " <>
                 "Core.EsFixture.Account.Event.Codec, а не Core.EventFixture.Event.Codec"
    end
  end

  # ---

  defp compile_family(name, refs) do
    module = Module.concat(__MODULE__, name)

    capture_io(:stderr, fn ->
      compile!("""
      defmodule #{inspect(module)} do
        use Core.Es.Event.Family,
          aggregate: #{inspect(refs[:aggregate])},
          aggregate_id: Core.EventFixture.AggID,
          by: Core.EventFixture.ActorID,
          codec: #{inspect(refs[:codec])}

        @type t :: struct()
      end
      """)
    end)
  end

  defp compile!(source), do: Code.compile_string(source, __ENV__.file)
end
