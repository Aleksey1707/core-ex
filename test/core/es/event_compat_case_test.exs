defmodule Core.Es.EventCompatCaseTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Error
  alias Core.Es.EventCompatCase
  alias Core.EsFixture.Account
  alias Core.EsFixture.BrokenAccount
  alias Core.EventFixture

  # Сломанный каталог фикстур того же кодека: у тега `fixture.closed` и источника
  # `fixture.opened` фикстур нет, остальные не грузятся или несут тег не из имени файла.
  @broken "test/support/fixtures/events_broken/fixture"
  @account "test/support/fixtures/events/account"

  describe "check_tag_fixtures/2" do
    test "тег без фикстуры — путь к недостающей" do
      path = Path.join(@broken, "fixture.closed.json")

      assert {:error, %{missing: [^path]}} =
               EventCompatCase.check_tag_fixtures(EventFixture.Event.Codec, @broken)
    end
  end

  describe "check_fixtures_load/3" do
    test "фикстура, которая не грузится, и фикстура тега вне кодека — путь и причина" do
      created = Path.join(@broken, "fixture.created.json")
      gone = Path.join(@broken, "fixture.gone.json")

      assert {:error, %{failed: failed}} =
               EventCompatCase.check_fixtures_load(EventFixture.Event.Codec, @broken, InCodec)

      assert [{^created, %Error{kind: :domain}}, {^gone, %Error{code: :unknown_event_type}}] =
               failed
    end
  end

  describe "check_upcast_fixtures/2" do
    test "источник апкаста без фикстуры — путь к недостающей" do
      path = Path.join(@broken, "fixture.opened.json")

      assert {:error, %{missing: [^path]}} =
               EventCompatCase.check_upcast_fixtures(EventFixture.Event.Codec, @broken)
    end
  end

  describe "check_upcasts_load/3" do
    test "фикстура источника под чужим тегом или не грузится — путь и причина" do
      v1 = Path.join(@broken, "fixture.created.v1.json")
      v2 = Path.join(@broken, "fixture.created.v2.json")

      assert {:error, %{failed: failed}} =
               EventCompatCase.check_upcasts_load(EventFixture.Event.Codec, @broken, InCodec)

      assert [{^v1, %{type: "fixture.created"}}, {^v2, %Error{kind: :domain}}] = failed
    end
  end

  describe "check_evolve/3" do
    test "у evolve/2 нет клаузы события — путь фикстуры и модуль события" do
      path = Path.join(@account, "account.closed.json")

      assert {:error, %{unhandled: [{^path, Account.Event.Closed}]}} =
               EventCompatCase.check_evolve(BrokenAccount, @account, InCodec)
    end
  end

  describe "опции" do
    test "обе опции aggregate: и event_codec: или ни одной — CompileError" do
      both = [aggregate: Account, event_codec: EventFixture.Event.Codec]

      for opts <- [[], both] do
        assert_raise CompileError, ~r/ровно одна из опций aggregate: и event_codec:/, fn ->
          use_case(opts)
        end
      end
    end

    test "aggregate: не event-sourced агрегат — CompileError" do
      assert_raise CompileError,
                   ~r/aggregate: модуль .* должен экспортировать __es_event_codec__\/0/,
                   fn ->
                     use_case(aggregate: EventFixture.Event.Codec)
                   end
    end

    test "event_codec: не кодек событий — CompileError" do
      assert_raise CompileError, ~r/должен экспортировать __es_type__\/0/, fn ->
        use_case(event_codec: Core.Version)
      end
    end

    test "fixtures: не непустая строка — CompileError" do
      for fixtures <- ["", :fixtures] do
        assert_raise CompileError, ~r/fixtures: ожидается непустая строка/, fn ->
          use_case(event_codec: EventFixture.Event.Codec, fixtures: fixtures)
        end
      end
    end

    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/async: ожидается boolean/, fn ->
        use_case(event_codec: EventFixture.Event.Codec, async: :yes)
      end
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:codec\]/, fn ->
        use_case(event_codec: EventFixture.Event.Codec, codec: InCodec)
      end
    end
  end

  # ---

  defp use_case(opts) do
    Code.eval_quoted(
      quote do
        defmodule Core.Es.EventCompatCaseTest.Compat do
          use Core.Es.EventCompatCase, unquote(opts)
        end
      end
    )
  end
end
