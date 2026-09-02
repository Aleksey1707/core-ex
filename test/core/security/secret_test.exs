defmodule Core.Security.SecretTest do
  use ExUnit.Case, async: false

  alias Core.Error
  alias Core.Security.Secret

  test "new/1 → reveal/1 roundtrip" do
    assert {:ok, %Secret{} = secret} = Secret.new("mts-password")
    assert is_binary(Secret.cipher(secret))
    assert Secret.cipher(secret) != "mts-password"
    assert {:ok, "mts-password"} = Secret.reveal(secret)
  end

  test "from_cipher/1 восстанавливает секрет без повторного шифрования" do
    assert {:ok, original} = Secret.new("plain-secret")
    cipher = Secret.cipher(original)

    assert {:ok, loaded} = Secret.from_cipher(cipher)
    assert Secret.cipher(loaded) == cipher
    assert {:ok, "plain-secret"} = Secret.reveal(loaded)
  end

  test "Inspect не раскрывает plaintext и cipher" do
    assert {:ok, secret} = Secret.new("super-secret-value")
    rendered = inspect(secret)

    assert rendered == "#Secret<...>"
    refute String.contains?(rendered, "super-secret-value")
    refute String.contains?(rendered, Secret.cipher(secret))
  end

  test "reveal/1 с чужим ключом → decrypt_failed" do
    assert {:ok, secret} = Secret.new("value")

    Application.put_env(:core, Secret, secret_key: "n3vusSg321IrfhL4DkKm-wdmTAyrX0sLmfsFZtREXps=")

    try do
      assert {:error, %Error{kind: :app, ns: :secret, code: :decrypt_failed}} =
               Secret.reveal(secret)
    after
      Application.put_env(:core, Secret,
        secret_key: "l6UwrPjFASzAVdJ7C_RbSZENSg4hztiWjOUM_RoZMkg="
      )
    end
  end

  test "ensure_configured!/0 проходит при валидном ключе" do
    assert :ok = Secret.ensure_configured!()
  end

  test "ensure_configured!/0 падает при пустом ключе" do
    Application.put_env(:core, Secret, secret_key: nil)

    try do
      assert_raise ArgumentError,
                   "не задан `config :core, Core.Security.Secret, secret_key: ...`",
                   fn ->
                     Secret.ensure_configured!()
                   end
    after
      Application.put_env(:core, Secret,
        secret_key: "l6UwrPjFASzAVdJ7C_RbSZENSg4hztiWjOUM_RoZMkg="
      )
    end
  end

  test "ensure_configured! отвергает ключ неверного формата" do
    configured = Application.fetch_env!(:core, Secret)
    on_exit(fn -> Application.put_env(:core, Secret, configured) end)

    Application.put_env(:core, Secret, secret_key: "not-base64!!!")
    assert_raise ArgumentError, ~r/base64/, &Secret.ensure_configured!/0

    # валидный base64, но 16 байт вместо 32
    Application.put_env(:core, Secret, secret_key: Base.encode64(:crypto.strong_rand_bytes(16)))

    assert_raise ArgumentError, ~r/32 байта/, &Secret.ensure_configured!/0
  end

  test "equal?/2 сравнивает с plaintext" do
    assert {:ok, secret} = Secret.new("s3cret")

    assert Secret.equal?(secret, "s3cret")
    refute Secret.equal?(secret, "other")
  end

  test "new!/1 и reveal!/1" do
    assert secret = Secret.new!("bang")
    assert Secret.reveal!(secret) == "bang"
  end

  test "секрет не сериализуется в JSON" do
    assert {:ok, secret} = Secret.new("s3cret")

    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(secret) end
  end
end
