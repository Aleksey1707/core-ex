defmodule Core.Security.PwdTest do
  use ExUnit.Case, async: true

  alias Core.Security.Pwd

  @alphabet Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c"!@#$%^&*()-_=+[]{}|;:,.<>?"])
            |> List.to_string()

  test "generate/1 отдаёт пароль запрошенной длины из объявленного алфавита" do
    password = Pwd.generate(64)

    assert String.length(password) == 64
    graphemes = String.graphemes(password)

    assert Enum.all?(graphemes, &String.contains?(@alphabet, &1))
  end

  test "generate/1 работает на границе длины 1" do
    assert String.length(Pwd.generate(1)) == 1
  end

  # Не доказательство криптостойкости, а страховка от вырождения генератора
  # (например, возврата к сидируемому `:rand` или к одному повторяющемуся символу).
  test "generate/1 не повторяется и покрывает алфавит" do
    passwords = for _ <- 1..50, do: Pwd.generate(32)

    assert length(Enum.uniq(passwords)) == 50

    distinct =
      passwords
      |> Enum.join()
      |> String.graphemes()
      |> Enum.uniq()

    assert length(distinct) > 40
  end

  test "hash/1 и verify/2" do
    hashed = Pwd.hash("sup3r-secret")

    assert Pwd.verify("sup3r-secret", hashed)
    refute Pwd.verify("другой", hashed)
  end

  test "no_user_verify/0 всегда false и тратит время" do
    refute Pwd.no_user_verify()
  end

  test "needs_rehash?/1 сравнивает параметры хеша с настроенными" do
    refute Pwd.needs_rehash?(Pwd.hash("pwd"))
    assert Pwd.needs_rehash?("не-argon2-хеш")
  end
end
