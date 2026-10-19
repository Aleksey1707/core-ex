defmodule Core.Web.Event.Details do
  @moduledoc false

  alias Core.Helper
  alias Core.Labels

  @doc false
  @spec to_wire(struct(), Labels.Refs.t(), module(), Core.Web.Event.user_dump()) :: %{
          title: String.t(),
          details: [Core.Web.Event.detail()]
        }

  def to_wire(%_{payload: _} = event, refs, codec, user_dump)
      when is_map(refs) and is_atom(codec) and is_function(user_dump, 2) do
    {title, details} = Labels.Details.build(event)
    env = %{refs: refs, codec: codec, user_dump: user_dump}

    %{title: title, details: Enum.map(details, &detail(&1, env))}
  end

  # ---

  defp detail(%{kind: :change, old: old, new: new} = detail, env),
    do: labelled(detail, %{kind: "change", old: detail(old, env), new: detail(new, env)})

  defp detail(%{kind: :destroyed} = detail, _env), do: labelled(detail, %{kind: "destroyed"})

  defp detail(%{kind: kind, value: value} = detail, env),
    do: labelled(detail, %{kind: Atom.to_string(kind), value: value(detail, value, env)})

  defp labelled(%{label: label}, dumped), do: Map.put(dumped, :label, label)
  defp labelled(%{}, dumped), do: dumped

  defp value(_detail, nil, _env), do: nil
  defp value(%{kind: kind}, details, env) when kind in ~w(group list)a, do: Enum.map(details, &detail(&1, env))
  defp value(%{kind: :user}, id, env), do: env.user_dump.(env.codec.dump(id), name!(env.refs, id))

  defp value(%{kind: :ref, entity: entity}, id, env),
    do: %{entity: Helper.Keys.camelize_key(entity), id: env.codec.dump(id), name: name!(env.refs, id)}

  defp value(%{kind: :number}, number, env), do: number(dump(number, env))
  defp value(%{kind: kind}, value, env) when kind in ~w(text date datetime)a, do: dump(value, env)

  defp name!(refs, id) do
    case refs do
      %{^id => name} ->
        name

      %{} ->
        raise ArgumentError,
              "#{inspect(id)}: нет в словаре ссылок — словарь собирают с той же страницы событий " <>
                "(`Core.Labels.Refs.get/2`)"
    end
  end

  defp dump(%_{} = prim, env), do: env.codec.dump(prim)
  defp dump(value, _env), do: value

  # Число — строкой с десятичной точкой, как `Decimal` на wire: без потери точности.
  defp number(number) when is_binary(number), do: number
  defp number(number) when is_integer(number), do: Integer.to_string(number)
  defp number(number) when is_float(number), do: number(Decimal.from_float(number))
  defp number(%Decimal{} = number), do: Decimal.to_string(number, :normal)
end
