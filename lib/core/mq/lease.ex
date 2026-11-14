defmodule Core.Mq.Lease do
  @moduledoc false

  alias Core.Error

  require Error

  @typedoc false
  @type token :: <<_::128>>

  @typedoc false
  @type scope :: atom()

  # ===== токен и срок =====

  @doc false
  @spec new_token() :: token()

  def new_token, do: Ecto.UUID.bingenerate()

  @doc false
  @spec deadline(timeout()) :: integer() | :infinity

  def deadline(:infinity), do: :infinity
  def deadline(ttl_ms) when is_integer(ttl_ms), do: System.monotonic_time(:millisecond) + ttl_ms

  # ===== потеря аренды =====

  @doc false
  @spec lost_error(scope(), map()) :: Error.t()

  def lost_error(scope, detail) when is_atom(scope) and is_map(detail) do
    Error.app(
      code: :lease_lost,
      ns: :mq,
      message: "Аренда потеряна: результат не записан",
      detail: Map.put(detail, :scope, scope)
    )
  end
end
