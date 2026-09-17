# Usage: elixir sig.exs [-pa dir] Mod:fun/arity ...
alias Module.Types.Descr

for spec <- System.argv() do
  [mod, fa] = String.split(spec, ":")
  [fun, arity] = String.split(fa, "/")
  module = Module.concat([mod])
  {fun, arity} = {String.to_atom(fun), String.to_integer(arity)}
  {^module, bin, _} = :code.get_object_code(module)
  {:ok, {_, [{_, chunk}]}} = :beam_lib.chunks(bin, [~c"ExCk"])
  {_, %{exports: exports}} = :erlang.binary_to_term(chunk)

  case List.keyfind(exports, {fun, arity}, 0) do
    {_, %{sig: {kind, domain, clauses}}} ->
      rendered =
        Enum.map(clauses, fn {args, ret} ->
          "(" <> Enum.map_join(args, ", ", &Descr.to_quoted_string/1) <> " -> " <>
            Descr.to_quoted_string(ret) <> ")"
        end)

      IO.puts("#{spec} [#{kind}, #{length(clauses)} clause(s), domain #{if domain, do: "set", else: "nil"}]")
      Enum.each(rendered, &IO.puts("    " <> &1))

    {_, %{sig: other}} ->
      IO.puts("#{spec} sig=#{inspect(other)}")

    nil ->
      IO.puts("#{spec} not exported")
  end
end
