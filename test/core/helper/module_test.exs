defmodule Core.Helper.ModuleTest do
  use ExUnit.Case, async: false

  alias Core.Helper

  @moduletag :tmp_dir

  test "модуль на диске, но ещё не загружен — функция находится", %{tmp_dir: dir} do
    mod = unloaded_module!(dir)

    refute :erlang.module_loaded(mod)
    assert Helper.Module.exports?(mod, :ping, 0)
  end

  test "загруженный модуль без функции такой арности — false" do
    refute Helper.Module.exports?(Core.Helper.String, :first_line, 2)
  end

  test "загруженный модуль с функцией — true" do
    assert Helper.Module.exports?(Core.Helper.String, :first_line, 1)
  end

  test "модуля нет — false" do
    refute Helper.Module.exports?(Core.Helper.ModuleTest.Missing, :ping, 0)
  end

  defp unloaded_module!(dir) do
    mod = Module.concat(__MODULE__, "Unloaded#{System.unique_integer([:positive])}")
    [{^mod, binary}] = Code.compile_quoted(quote(do: defmodule(unquote(mod), do: def(ping, do: :pong))))
    File.write!(Path.join(dir, "#{mod}.beam"), binary)
    true = Code.prepend_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)
    :code.purge(mod)
    true = :code.delete(mod)
    mod
  end
end
