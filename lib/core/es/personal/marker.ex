defmodule Core.Es.Personal.Marker do
  @moduledoc """
  Маркер ПДн-значения в результате `dump` кодека событий (ADR-0073): на месте значения поля
  нагрузки с `subject:` — идентификатор субъекта и wire-значение поля.

  Кодек событий чист и не шифрует: маркер заменяют шифротекстом `{"$pd": …}` писатели wire-формы
  в транзакции записи. Писатель, забывший шифрование, падает на маркере, а не пишет открытый
  текст: `Jason.Encoder` маркера поднимает исключение без значения. `inspect/1` показывает только
  идентификатор субъекта.

  | Поле | Значение |
  |---|---|
  | `subject` | идентификатор субъекта — дамп его UUID-Prim |
  | `value` | wire-значение поля; `nil` у маркера уничтоженного значения |
  | `destroyed` | `true` — маркер уничтоженного значения (`%Core.Es.Personal.Destroyed{}` в поле) |
  """

  @enforce_keys ~w(subject)a
  defstruct subject: nil, value: nil, destroyed: false

  @typedoc "Маркер ПДн-значения."
  @type t :: %__MODULE__{subject: String.t(), value: term(), destroyed: boolean()}
end

defimpl Inspect, for: Core.Es.Personal.Marker do
  @doc false
  @impl true
  def inspect(%Core.Es.Personal.Marker{subject: subject, destroyed: destroyed}, opts) do
    state = if destroyed, do: ", destroyed", else: ""

    Inspect.Algebra.concat(["#Core.Es.Personal.Marker<subject: ", Inspect.Algebra.to_doc(subject, opts), state, ">"])
  end
end

# Маркер в JSON — писатель wire-формы забыл шифрование: открытый текст не уходит ни в хранилище, ни
# в текст исключения.
defimpl Jason.Encoder, for: Core.Es.Personal.Marker do
  @doc false
  @impl true
  def encode(%Core.Es.Personal.Marker{subject: subject}, _opts) do
    raise Protocol.UndefinedError,
      protocol: Jason.Encoder,
      value: "#Core.Es.Personal.Marker<subject: #{inspect(subject)}>",
      description: "маркер ПДн-значения не сериализуется в JSON: его шифрует писатель wire-формы"
  end
end
