defmodule Core.Security.Pwd do
  @moduledoc """
  Хеширование и генерация паролей (Argon2).
  """

  @alphabet Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c"!@#$%^&*()-_=+[]{}|;:,.<>?"])
            |> List.to_string()
  @alphabet_size byte_size(@alphabet)

  # Наибольшее кратное размеру алфавита, помещающееся в байт: байты от лимита и выше
  # отбраковываются, иначе `rem/2` сместил бы распределение в пользу первых символов.
  @sampling_limit @alphabet_size * div(256, @alphabet_size)

  @doc "Хешировать пароль (Argon2)."
  @spec hash(String.t()) :: String.t()

  def hash(plain) when is_binary(plain), do: Argon2.hash_pwd_salt(plain)

  @doc "Проверить пароль против хеша."
  @spec verify(String.t(), String.t()) :: boolean()

  def verify(plain, hashed) when is_binary(plain) and is_binary(hashed) do
    Argon2.verify_pass(plain, hashed)
  end

  @doc """
  Выполнить фиктивную проверку пароля.

  Вызывается на ветке «пользователь не найден»: без неё ответ приходит мгновенно,
  и существующие учётки перебираются по таймингу.
  """
  @spec no_user_verify() :: false

  def no_user_verify, do: Argon2.no_user_verify()

  @doc """
  Требует ли хеш пересчёта под текущие параметры Argon2.

  `true` — хеш посчитан с параметрами, отличными от настроенных (например подняли
  `t_cost`): пароль стоит перехешировать при следующем успешном входе.
  """
  @spec needs_rehash?(String.t()) :: boolean()

  def needs_rehash?(hashed) when is_binary(hashed) do
    case parse_params(hashed) do
      {:ok, params} -> params != configured_params()
      :error -> true
    end
  end

  @doc "Сгенерировать случайный пароль заданной длины (CSPRNG)."
  @spec generate(pos_integer()) :: String.t()

  def generate(length) when is_integer(length) and length > 0 do
    length
    |> pick([], <<>>)
    |> List.to_string()
  end

  # ---

  # Формат Argon2: $argon2id$v=19$m=<mem>,t=<time>,p=<par>$salt$hash
  defp parse_params(hashed) do
    case String.split(hashed, "$", trim: true) do
      [_type, _version, params | _rest] -> parse_param_list(params)
      _ -> :error
    end
  end

  defp parse_param_list(params) do
    parsed =
      params
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))

    if Enum.all?(parsed, &match?([_key, _value], &1)),
      do: {:ok, Map.new(parsed, fn [key, value] -> {key, value} end)},
      else: :error
  end

  defp configured_params do
    %{
      "m" => argon2_env(:m_cost, 16) |> then(&Integer.to_string(Bitwise.bsl(1, &1))),
      "t" => argon2_env(:t_cost, 3) |> Integer.to_string(),
      "p" => argon2_env(:parallelism, 4) |> Integer.to_string()
    }
  end

  defp argon2_env(key, default), do: Application.get_env(:argon2_elixir, key, default)

  defp pick(0, acc, _buffer), do: acc

  defp pick(remaining, acc, <<>>) do
    pick(remaining, acc, :crypto.strong_rand_bytes(remaining * 2))
  end

  defp pick(remaining, acc, <<byte, rest::binary>>) when byte < @sampling_limit do
    pick(remaining - 1, [:binary.at(@alphabet, rem(byte, @alphabet_size)) | acc], rest)
  end

  defp pick(remaining, acc, <<_byte, rest::binary>>), do: pick(remaining, acc, rest)
end
