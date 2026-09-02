defmodule Core.Helper.StringTest do
  use ExUnit.Case, async: true

  alias Core.Helper

  test "first_line/1 returns the only line" do
    assert Helper.String.first_line("Логин") == "Логин"
  end

  test "first_line/1 trims and takes first line" do
    text = """

    Идентификатор пользователя

    Дополнительное описание.
    """

    assert Helper.String.first_line(text) == "Идентификатор пользователя"
  end
end
