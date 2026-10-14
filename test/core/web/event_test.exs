defmodule Core.Web.EventTest do
  use ExUnit.Case, async: true

  import OpenApiSpex.TestAssertions

  alias Core.CodecFixture.External
  alias Core.Es.Event.At
  alias Core.EventFixture
  alias Core.LabelsFixture
  alias Core.Pagination
  alias Core.Version
  alias Core.Web.Response
  alias Core.WebEventFixture.AggID
  alias Core.WebEventFixture.Event
  alias Core.WebEventFixture.Plain
  alias Core.WebEventFixture.UserID
  alias Core.WebEventFixture.UserRef
  alias Core.WebEventFixture.WithUser
  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.MediaType
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Operation
  alias OpenApiSpex.PathItem

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

  describe "схема" do
    test "дамп и страница каждой конфигурации проходят схему того же use и Response.Schema.page/1" do
      [by, labelled_by] = [UserID.new(), LabelsFixture.UserID.new()]
      noted = noted(by)
      labelled = LabelsFixture.Event.Closed.new(EventFixture.AggID.new(), Version.new(), labelled_by, At.now!())

      for {module, event, refs} <- [
            {Plain, noted, %{}},
            {Plain, closed(by), %{}},
            {WithUser, noted, %{by => "Автор"}},
            {WithUser, closed(by), %{by => nil}},
            {LabelsFixture.WebEvent, labelled, %{labelled_by => "Автор"}}
          ] do
        title = List.last(Module.split(module))
        page = %Pagination.Result{items: [event, event], total: 7}

        assert_schema(json(module.to_wire(event, refs)), title, spec([module]))
        assert {:ok, _} = cast_page(Response.success(Response.page_data(page, &module.to_wire(&1, refs))), module)
      end
    end

    test "названия от последнего сегмента имени модуля, все поля обязательны, by — строка или schema:" do
      %OpenApi{components: %Components{schemas: schemas}} = spec([Plain, WithUser])
      fields = ~w(id aggregateId version type payload at by)a

      assert %{type: :object, additionalProperties: nil, required: required, properties: properties} = schemas["Plain"]
      assert Enum.sort(required) == Enum.sort(fields)
      assert Enum.sort(Map.keys(properties)) == Enum.sort(fields)

      assert %{
               type: %{type: :string, enum: nil},
               version: %{type: :integer, minimum: 1},
               payload: %{type: nil, nullable: true},
               at: %{type: :string, format: :"date-time"},
               by: %{type: :string}
             } = properties

      assert %{properties: %{by: %OpenApiSpex.Reference{"$ref": "#/components/schemas/UserRef"}}} = schemas["WithUser"]
      assert Map.has_key?(schemas, "UserRef")
    end

    test "labels: true — title и details со схемой сведений Detail" do
      %OpenApi{components: %Components{schemas: %{"WebEvent" => schema}}} = spec([LabelsFixture.WebEvent])

      assert %{
               required: required,
               properties: %{
                 title: %{type: :string},
                 details: %{type: :array, items: %OpenApiSpex.Reference{"$ref": "#/components/schemas/WebEventDetail"}}
               }
             } = schema

      assert :title in required and :details in required
    end

    test "новое поле события проходит схему" do
      wire = json(Map.put(Plain.to_wire(noted(UserID.new()), %{}), :seq, 1))

      assert_schema(wire, "Plain", spec([Plain]))
    end

    test "форма вне схемы — отказ" do
      by = UserID.new()
      %OpenApi{components: %Components{schemas: schemas}} = spec = spec([Plain, WithUser])
      plain = json(Plain.to_wire(noted(by), %{}))
      with_user = json(WithUser.to_wire(noted(by), %{by => "Автор"}))

      for {wire, title} <- [
            {%{plain | "version" => 0}, "Plain"},
            {%{plain | "at" => "14.10.2026"}, "Plain"},
            {Map.delete(plain, "payload"), "Plain"},
            {%{plain | "by" => %{"id" => "u1", "login" => nil}}, "Plain"},
            {%{with_user | "by" => "u1"}, "WithUser"}
          ] do
        assert {:error, _} = OpenApiSpex.cast_value(wire, schemas[title], spec), inspect(wire)
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
        compile_event(:LabelsNotBoolean, codec: External, user_ref: user_ref(), labels: :yes)
      end
    end

    test "user_ref: без dump: — CompileError" do
      assert_raise CompileError, ~r/NoDump: user_ref: нет обязательных опций: \[:dump\]/, fn ->
        compile_event(:NoDump, codec: External, user_ref: [schema: UserRef])
      end
    end

    test "user_ref: с неизвестной опцией — CompileError" do
      assert_raise CompileError, ~r/UnknownRef: user_ref: неизвестные опции: \[:login\]/, fn ->
        compile_event(:UnknownRef, codec: External, user_ref: [login: true] ++ user_ref())
      end
    end

    test "dump: не захват функции арности 2 — CompileError" do
      assert_raise CompileError, ~r/Arity: user_ref: dump: — захват функции арности 2/, fn ->
        compile_event(:Arity, codec: External, user_ref: [dump: &Kernel.inspect/1, schema: UserRef])
      end
    end

    test "user_ref: без schema: при open_api_spex — CompileError" do
      assert_raise CompileError, ~r/NoSchema: user_ref: нет обязательных опций: \[:schema\]/, fn ->
        compile_event(:NoSchema, codec: External, user_ref: [dump: &WithUser.user_ref/2])
      end
    end

    test "schema: не схема OpenApiSpex — CompileError" do
      assert_raise CompileError, ~r/BadSchema: user_ref: schema: модуль URI должен экспортировать schema\/0/, fn ->
        compile_event(:BadSchema, codec: External, user_ref: [dump: &WithUser.user_ref/2, schema: URI])
      end
    end
  end

  # ---

  defp closed(by), do: Event.Closed.new(AggID.new(), Version.new(), by, At.now!())

  defp noted(by) do
    payload = %Event.Noted.Payload{first_name: "Анна", extra_data: %{"source_kind" => %{"line_no" => 2}}}

    Event.Noted.new(payload, AggID.new(), Version.new!(3), by, At.now!())
  end

  defp user_ref, do: [dump: &WithUser.user_ref/2, schema: UserRef]

  # Страница — через спеку операции: модуль события в page/1 резолвится, как у приложения.
  defp cast_page(body, module) do
    operation = %Operation{
      operationId: "index",
      responses: %{
        200 => %OpenApiSpex.Response{
          description: "Страница событий",
          content: %{"application/json" => %MediaType{schema: Response.Schema.page(module)}}
        }
      }
    }

    %OpenApi{paths: %{"/" => %PathItem{get: %Operation{responses: %{200 => response}}}}} =
      spec = OpenApiSpex.resolve_schema_modules(%{spec([]) | paths: %{"/" => %PathItem{get: operation}}})

    %{content: %{"application/json" => %MediaType{schema: schema}}} = response

    OpenApiSpex.cast_value(json(body), schema, spec)
  end

  defp json(body), do: Jason.decode!(Jason.encode!(body))

  defp spec(modules) do
    OpenApiSpex.add_schemas(
      %OpenApi{
        info: %Info{title: "Core.Web.EventTest", version: "0"},
        paths: %{},
        components: %Components{schemas: %{}}
      },
      modules
    )
  end

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
