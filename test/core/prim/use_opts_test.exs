defmodule Core.Prim.UseOptsTest do
  use ExUnit.Case, async: true

  defmodule Base do
    use Core.Prim.String,
      name: "База",
      max_len: 10
  end

  # Минимальный валидный набор опций каждой обёртки, без `name:`.
  @wrappers [
    {Core.Prim.String, "Prim.String", quote(do: [max_len: 10])},
    {Core.Prim.Integer, "Prim.Integer", []},
    {Core.Prim.Decimal, "Prim.Decimal", []},
    {Core.Prim.UUID, "Prim.UUID", []},
    {Core.Prim.Date, "Prim.Date", []},
    {Core.Prim.DateTime, "Prim.DateTime", []},
    {Core.Prim.Compose, "Prim.Compose", quote(do: [of: Core.Prim.UseOptsTest.Base])}
  ]

  def cast(value), do: {:ok, value}

  describe "use Core.Prim" do
    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Prim: неизвестные опции: \[:sensitve\]$/, fn ->
        expand(Core.Prim, quote(do: [cast: &Core.Prim.UseOptsTest.cast/1, name: "X", kind: :x, sensitve: true]))
      end
    end

    test "атрибут в опции-литерале — «ожидается литерал»" do
      for key <- ~w(kind sensitive personal)a do
        opts = Keyword.put(quote(do: [cast: &Core.Prim.UseOptsTest.cast/1, name: "X", kind: :x]), key, quote(do: @flag))

        assert_raise CompileError, ~r/^Prim: #{key}: ожидается литерал, получено @flag$/, fn ->
          expand(Core.Prim, opts)
        end
      end
    end

    test "неверное выражение — в теле, с меткой" do
      cases = [
        {quote(do: [cast: &Core.Prim.UseOptsTest.cast/1, name: @n, kind: :x]), "name: ожидается строка, получено 1"},
        {quote(do: [cast: @n, name: "X", kind: :x]), "cast: ожидается fun/1 или fun/2, получено 1"},
        {quote(do: [cast: &Core.Prim.UseOptsTest.cast/1, name: "X", kind: :x, custom_mutate: @n]),
         "custom_mutate: ожидается {Module, opts}, fun/1, fun/2 или их список, получено 1"},
        {quote(do: [cast: &Core.Prim.UseOptsTest.cast/1, name: "X", kind: :x, type_opts: @n]),
         "type_opts: ожидается keyword, получено 1"}
      ]

      for {opts, message} <- cases do
        expand(Core.Prim, opts)

        assert_raise CompileError, ~r/^Prim: #{Regex.escape(message)}$/, fn ->
          compile(quote(do: @n(1)), Core.Prim, opts)
        end
      end
    end

    test "опции-выражения принимаются" do
      mod =
        compile(quote(do: @moduledoc("Имя\n\nтекст")), Core.Prim,
          cast: quote(do: &Core.Prim.UseOptsTest.cast/1),
          name: quote(do: hd(String.split(@moduledoc, "\n"))),
          kind: :x,
          custom_mutate: quote(do: [&String.upcase/1])
        )

      assert "Имя" = mod.name()
      assert "AB" = mod.value(mod.new!("ab"))
    end
  end

  describe "use обёртки Prim" do
    test "опечатка в ключе — при раскрытии, с меткой обёртки" do
      for {wrapper, label, own} <- @wrappers do
        assert_raise CompileError, ~r/^#{label}: неизвестные опции: \[:nmae\]$/, fn ->
          expand(wrapper, [{:name, "X"}, {:nmae, "X"} | own])
        end
      end
    end

    test "атрибут в опции-литерале — «ожидается литерал»" do
      for {wrapper, label, own} <- @wrappers, key <- ~w(kind sensitive personal)a do
        assert_raise CompileError, ~r/^#{label}: #{key}: ожидается литерал, получено @flag$/, fn ->
          expand(wrapper, [{:name, "X"}, {key, quote(do: @flag)} | own])
        end
      end
    end

    test "неверное name: — в теле, с меткой Prim" do
      for {wrapper, _label, own} <- @wrappers do
        opts = [{:name, quote(do: @n)} | own]
        expand(wrapper, opts)

        assert_raise CompileError, ~r/^Prim: name: ожидается строка, получено 1$/, fn ->
          compile(quote(do: @n(1)), wrapper, opts)
        end
      end
    end

    test "неверные mutate: / validate: — в теле, с меткой обёртки" do
      for {wrapper, label, own} <- @wrappers, key <- ~w(mutate validate)a do
        opts = [{:name, "X"}, {key, quote(do: @n)} | own]
        expand(wrapper, opts)

        assert_raise CompileError, ~r/^#{label}: #{key}: ожидается \{Module, opts\}, fun\/1, fun\/2/, fn ->
          compile(quote(do: @n(1)), wrapper, opts)
        end
      end
    end

    test "sensitive: / personal: обёртки проверяет Core.Prim" do
      assert_raise CompileError, ~r/^Prim: personal: ожидается true или false, получено 1$/, fn ->
        compile(nil, Core.Prim.String, name: "X", max_len: 10, personal: 1)
      end
    end

    test "sensitive: / personal: Prim.Compose проверяет сама Prim.Compose" do
      assert_raise CompileError, ~r/^Prim.Compose: sensitive: ожидается true или false, получено 1$/, fn ->
        expand(Core.Prim.Compose, quote(do: [name: "X", of: Core.Prim.UseOptsTest.Base, sensitive: 1]))
      end
    end
  end

  describe "use Core.Prim.Wrapper" do
    test "ключи обёртки — список атомов, при раскрытии" do
      assert_raise CompileError, ~r/^Prim\.Wrapper: optional: ожидается список атомов, получено :min$/, fn ->
        expand(Core.Prim.Wrapper, label: "X", native_kind: :x, optional: :min)
      end
    end
  end

  describe "опции-выражения обёрток" do
    test "Prim.String: max_len: и re: — выражения, проверка в теле" do
      mod =
        compile(quote(do: @max_len(3)), Core.Prim.String,
          name: "X",
          max_len: quote(do: @max_len),
          re: quote(do: ~r/^a/)
        )

      assert {:ok, _prim} = mod.new("ab")
      assert {:error, _error} = mod.new("abcd")
      assert {:error, _error} = mod.new("b")

      cases = [
        {[max_len: quote(do: @n)], ~S'max_len: ожидается целое ≥ 0, получено "x"'},
        {[max_len: 3, re: quote(do: @n)], ~S're: ожидается %Regex{} (`~r/.../`), получено "x"'},
        {[min_len: 5, max_len: quote(do: @m)], "min_len (5) больше max_len (3)"}
      ]

      for {own, message} <- cases do
        opts = [{:name, "X"} | own]
        expand(Core.Prim.String, opts)

        assert_raise CompileError, ~r/^Prim\.String: #{Regex.escape(message)}/, fn ->
          compile(
            quote(
              do:
                (
                  @n "x"
                  @m 3
                )
            ),
            Core.Prim.String,
            opts
          )
        end
      end
    end

    test "Prim.Decimal: min: / max: — выражения, проверка в теле" do
      mod = compile(nil, Core.Prim.Decimal, name: "X", min: quote(do: Decimal.new("0.01")))

      assert {:error, _error} = mod.new("0")
      assert {:ok, _prim} = mod.new("0.01")

      opts = [name: "X", min: quote(do: @n)]
      expand(Core.Prim.Decimal, opts)

      assert_raise CompileError, ~r/^Prim.Decimal: min: ожидается число, строку или %Decimal\{\}, получено :x$/, fn ->
        compile(quote(do: @n(:x)), Core.Prim.Decimal, opts)
      end
    end

    test "Prim.UUID: namespace: — выражение, проверка в теле" do
      opts = [name: "X", version: 5, namespace: quote(do: @n), scope: "s"]
      expand(Core.Prim.UUID, opts)

      assert_raise CompileError, ~r/^Prim.UUID: namespace: ожидается UUID-строка, получено "x"$/, fn ->
        compile(quote(do: @n("x")), Core.Prim.UUID, opts)
      end
    end
  end

  # ---

  defp expand(builder, opts) do
    {:ok, env} = Macro.Env.define_require(__ENV__, [], builder)
    Macro.expand(quote(do: unquote(builder).__using__(unquote(opts))), env)
  end

  defp compile(attrs, builder, opts) do
    name = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")

    {{:module, mod, _bin, _}, _binding} =
      Code.eval_quoted(
        quote do
          defmodule unquote(name) do
            unquote(attrs)
            use unquote(builder), unquote(opts)
          end
        end
      )

    mod
  end
end
