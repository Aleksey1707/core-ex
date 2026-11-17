defmodule Core.Field.SpecTest do
  use ExUnit.Case, async: true

  alias Core.Field.Spec
  alias Core.Prim

  defmodule Name do
    use Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Tag do
    defstruct [:name]
  end

  defmodule Family do
  end

  defmodule Status do
    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  @where "W"

  describe "форма поля" do
    test "разобранное поле — имя, вид, wire-ключ и метаданные" do
      assert [
               %{name: :a, spec: {:prim, Name}, optional?: false, wire: "a", default: :none, subject: nil},
               %{name: :b, spec: {:list, {:enum, Status}}, optional?: true, wire: "bee", default: :none},
               %{name: :c, spec: {:entity, Tag}, default: :none}
             ] =
               Spec.parse!(
                 [
                   a: [prim: Name],
                   b: [list: [enum: Status], optional: true, wire: "bee"],
                   c: [entity: Tag]
                 ],
                 :struct,
                 @where
               )
    end

    test "subject: в режиме нагрузки ложится в поле" do
      assert [%{name: :a, subject: :aggregate_id}] =
               Spec.parse!([a: [prim: Name, subject: :aggregate_id]], :payload, @where)
    end

    test "value_spec — спека значения по модулю типа" do
      assert Spec.value_spec(Name, @where) == {:prim, Name}
      assert Spec.value_spec(Status, @where) == {:enum, Status}
      assert Spec.value_spec(Tag, @where) == {:entity, Tag}
    end
  end

  describe "kind-ключ" do
    test "ровно один" do
      assert_raise CompileError,
                   ~r/W: a: ожидается ровно один из prim:\/enum:\/entity:\/union:\/list:\/set:\/map:\/type:/,
                   fn ->
                     Spec.parse!([a: [prim: Name, enum: Status]], :struct, @where)
                   end
    end

    test "неизвестный ключ" do
      assert_raise CompileError, ~r/W: a: неизвестные ключи \[:default_value\]/, fn ->
        Spec.parse!([a: [prim: Name, default_value: 1]], :struct, @where)
      end
    end

    test "неизвестный type:" do
      assert_raise CompileError, ~r/W: a: неизвестный type: :atom/, fn ->
        Spec.parse!([a: [type: :atom]], :struct, @where)
      end
    end
  end

  describe "optional: и list:" do
    test "optional: — boolean" do
      assert_raise CompileError, ~r/W: a: optional: ожидается boolean, получено :yes/, fn ->
        Spec.parse!([a: [prim: Name, optional: :yes]], :struct, @where)
      end
    end

    test "optional: не внутри list:" do
      assert_raise CompileError, ~r/W: a: optional: задаётся у самого поля, не в list:/, fn ->
        Spec.parse!([a: [list: [prim: Name, optional: true]]], :struct, @where)
      end
    end

    test "list: — keyword-спека элемента без лишних ключей" do
      assert_raise CompileError, ~r/W: a: list: неизвестные ключи \[:wire\]/, fn ->
        Spec.parse!([a: [list: [prim: Name, wire: "x"]]], :struct, @where)
      end
    end
  end

  describe "wire:" do
    test "непустая строка" do
      assert_raise CompileError, ~r/W: a: wire: ожидается непустая строка, получено ""/, fn ->
        Spec.parse!([a: [prim: Name, wire: ""]], :struct, @where)
      end
    end

    test "в нагрузке не начинается с $" do
      assert_raise CompileError, ~r/W: a: wire-ключ "\$pd" начинается с \$/, fn ->
        Spec.parse!([a: [prim: Name, wire: "$pd"]], :payload, @where)
      end
    end
  end

  describe "уникальность" do
    test "имён полей" do
      assert_raise CompileError, ~r/W: повторяются \[:a\]/, fn ->
        Spec.parse!([a: [prim: Name], a: [prim: Name]], :struct, @where)
      end
    end

    test "wire-ключей" do
      assert_raise CompileError, ~r/W: wire: повторяются \["b"\]/, fn ->
        Spec.parse!([a: [prim: Name, wire: "b"], b: [prim: Name]], :struct, @where)
      end
    end
  end

  describe "default: по режиму" do
    test "нагрузка default: не принимает" do
      assert_raise CompileError, ~r/W: default: у нагрузки события нет \(поля \[:a\]\)/, fn ->
        Spec.parse!([a: [prim: Name, default: "x"]], :payload, @where)
      end
    end
  end

  describe "subject: по режиму" do
    test "подписи subject: не принимают" do
      assert_raise CompileError, ~r/W: a: неизвестные ключи \[:subject\]/, fn ->
        Spec.parse!([a: [prim: Name, subject: :aggregate_id]], :labels, @where)
      end
    end

    test "в нагрузке subject: — атом" do
      assert_raise CompileError, ~r/W: a: subject: ожидается .*получено "b"/, fn ->
        Spec.parse!([a: [prim: Name, subject: "b"]], :payload, @where)
      end
    end
  end

  describe "вид × хост" do
    @kinds ~w(prim enum entity union list set map type view form jsonb)a
    @hosts [
      struct: {"структура по полям", ~w(prim enum entity union list set map type)a},
      payload: {"нагрузка события", ~w(prim enum entity union list set map type)a},
      labels: {"подписи", ~w(prim enum entity union list set map type)a},
      view: {"View", ~w(prim enum type view form list set map jsonb)a}
    ]

    test "kinds/0 — объединение видов" do
      assert Enum.sort(Spec.kinds()) == Enum.sort(@kinds)
    end

    test "допустимый вид проходит, чужой — CompileError с хостом и видом" do
      for {host, {name, allowed}} <- @hosts, kind <- @kinds do
        case compile(host, kind) do
          :ok ->
            assert kind in allowed, "#{name} не должен принимать #{kind}:"

          {:error, %CompileError{description: description}} ->
            refute kind in allowed, "#{name} должен принимать #{kind}: #{description}"
            assert description =~ "недопустим в хосте «#{name}»", "нет имени хоста #{name}: #{description}"
            assert description =~ "#{kind}", "нет вида #{kind}: #{description}"
        end
      end
    end

    test "вложенный вид проверяется по allowlist того же хоста" do
      assert_raise CompileError, ~r/W: a: list: вид view: недопустим в хосте «структура по полям»/, fn ->
        Spec.parse!([a: [list: [view: Core.ViewFixture.Nested]]], :struct, @where)
      end
    end

    defp compile(:view, kind) do
      forms = if kind == :form, do: [form: [x: [type: :string]]], else: []

      Code.eval_quoted(
        quote do
          defmodule unquote(
                      Module.concat(
                        __MODULE__,
                        :"Kinds#{System.unique_integer([:positive])}"
                      )
                    ) do
            use Core.View,
              fields: [a: unquote(Macro.escape(spec_opts(kind)))],
              forms: unquote(Macro.escape(forms))
          end
        end
      )

      :ok
    rescue
      error in CompileError -> {:error, error}
    end

    defp compile(host, kind) do
      Spec.parse!([a: spec_opts(kind)], host, @where)
      :ok
    rescue
      error in CompileError -> {:error, error}
    end

    defp spec_opts(:prim), do: [prim: Name]
    defp spec_opts(:enum), do: [enum: Status]
    defp spec_opts(:entity), do: [entity: Tag]
    defp spec_opts(:union), do: [union: Family]
    defp spec_opts(:list), do: [list: [prim: Name]]
    defp spec_opts(:set), do: [set: [prim: Name]]
    defp spec_opts(:map), do: [map: [key: [type: :string], value: [prim: Name]]]
    defp spec_opts(:type), do: [type: :string]
    defp spec_opts(:view), do: [view: Core.ViewFixture.Nested]
    defp spec_opts(:form), do: [form: :form]
    defp spec_opts(:jsonb), do: [jsonb: {Core.ViewFixture.Specs, :payload_spec}]
  end
end
