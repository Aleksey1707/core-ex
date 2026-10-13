defmodule Core.Web.EventTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.External
  alias Core.Es.Event.At
  alias Core.Version
  alias Core.WebEventFixture.AggID
  alias Core.WebEventFixture.Event
  alias Core.WebEventFixture.Plain
  alias Core.WebEventFixture.UserID
  alias Core.WebEventFixture.WithUser

  describe "без user_ref:" do
    test "поля конверта, ключи нагрузки в camelCase, by — дамп id" do
      [id, agg, by] = [Core.Es.Event.ID.new(), AggID.new(), UserID.new()]
      at = At.new!(~U[2026-10-14 09:30:00.000000Z])
      payload = %Event.Noted.Payload{first_name: "Анна", extra_data: %{"source_kind" => %{"line_no" => 2}}}
      event = Event.Noted.new(payload, agg, Version.new!(3), by, at, id)

      assert Plain.to_wire(event, %{}) == %{
               id: External.dump(id),
               aggregateId: External.dump(agg),
               version: 3,
               type: "web_event.noted",
               payload: %{"firstName" => "Анна", "extraData" => %{"sourceKind" => %{"lineNo" => 2}}},
               at: External.dump(at),
               by: External.dump(by)
             }
    end

    test "нагрузки нет — payload: nil" do
      assert %{type: "web_event.closed", payload: nil} = Plain.to_wire(closed(UserID.new()), %{})
    end
  end

  describe "с user_ref:" do
    test "by — дамп user_ref: от дампа id и имени из словаря ссылок" do
      by = UserID.new()

      assert WithUser.to_wire(closed(by), %{by => "Автор"}).by == %{id: External.dump(by), login: "Автор"}
    end

    test "имени нет — nil в dump:" do
      by = UserID.new()

      assert %{by: %{login: nil}} = WithUser.to_wire(closed(by), %{by => nil})
    end

    test "автора нет в словаре ссылок — ArgumentError" do
      assert_raise ArgumentError, ~r/автор события .*: нет в словаре ссылок/, fn ->
        WithUser.to_wire(closed(UserID.new()), %{})
      end
    end
  end

  describe "отказ сборки" do
    test "без codec: — CompileError" do
      assert_raise CompileError, ~r/Web.Event: нет обязательных опций: \[:codec\]/, fn ->
        compile_event(:NoCodec, [])
      end
    end

    test "codec: без dump/1 — CompileError" do
      assert_raise CompileError, ~r/Web.Event: codec: модуль URI должен экспортировать dump\/1/, fn ->
        compile_event(:BadCodec, codec: URI)
      end
    end

    test "неизвестная опция — CompileError" do
      assert_raise CompileError, ~r/Web.Event: неизвестные опции: \[:title\]/, fn ->
        compile_event(:Unknown, codec: External, title: true)
      end
    end

    test "labels: true без user_ref: — CompileError" do
      assert_raise CompileError, ~r/LabelsNoUserRef: labels: true требует user_ref:/, fn ->
        compile_event(:LabelsNoUserRef, codec: External, labels: true)
      end

      assert_raise CompileError, ~r/LabelsNilUserRef: labels: true требует user_ref:/, fn ->
        compile_event(:LabelsNilUserRef, codec: External, user_ref: nil, labels: true)
      end
    end

    test "labels: не boolean — CompileError" do
      assert_raise CompileError, ~r/LabelsNotBoolean: labels: ожидается boolean, получено :yes/, fn ->
        compile_event(:LabelsNotBoolean, codec: External, user_ref: [dump: &WithUser.user_ref/2], labels: :yes)
      end
    end

    test "user_ref: без dump: — CompileError" do
      assert_raise CompileError, ~r/NoDump: user_ref: нет обязательных опций: \[:dump\]/, fn ->
        compile_event(:NoDump, codec: External, user_ref: [])
      end
    end

    test "user_ref: с неизвестной опцией — CompileError" do
      assert_raise CompileError, ~r/UnknownRef: user_ref: неизвестные опции: \[:login\]/, fn ->
        compile_event(:UnknownRef, codec: External, user_ref: [dump: &WithUser.user_ref/2, login: true])
      end
    end

    test "dump: не захват функции арности 2 — CompileError" do
      assert_raise CompileError, ~r/Arity: user_ref: dump: — захват функции арности 2/, fn ->
        compile_event(:Arity, codec: External, user_ref: [dump: &Kernel.inspect/1])
      end
    end
  end

  # ---

  defp closed(by), do: Event.Closed.new(AggID.new(), Version.new(), by, At.now!())

  defp compile_event(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Web.Event, unquote(opts)
        end
      end
    )
  end
end
