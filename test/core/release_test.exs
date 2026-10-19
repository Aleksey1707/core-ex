defmodule Core.ReleaseTest do
  # Подменяет `priv` и `migration_lock` у `Core.TestRepo`: каталог с одной тестовой миграцией вместо
  # `priv/repo`, без блокировки — она держит соединение sandbox, которого ждёт процесс миграции.
  use Core.DataCase, async: false

  import ExUnit.CaptureIO

  alias Core.Release

  @version 20_261_231_235_900

  setup do
    config = Application.fetch_env!(:core, TestRepo)
    priv = Path.relative_to(Path.expand("test/support/release"), Application.app_dir(:core), force: true)

    Application.put_env(:core, TestRepo, Keyword.merge(config, priv: priv, migration_lock: false))
    on_exit(fn -> Application.put_env(:core, TestRepo, config) end)

    # Ecto компилирует файл миграции на каждом прогоне: повтор в одной VM переопределяет модуль.
    conflict = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, conflict) end)
  end

  test "migrate накатывает миграции репозиториев приложения и сообщает их число" do
    assert capture_io(fn -> assert :ok = Release.migrate(:core) end) ==
             "Применено миграций в Core.TestRepo: 1\n"

    assert table?()

    assert capture_io(fn -> assert :ok = Release.migrate(:core) end) ==
             "Применено миграций в Core.TestRepo: 0\n"
  end

  test "rollback откатывает миграции репозитория до версии включительно" do
    capture_io(fn -> Release.migrate(:core) end)

    assert capture_io(fn -> assert :ok = Release.rollback(:core, TestRepo, @version) end) ==
             "Откачено миграций в Core.TestRepo: 1\n"

    refute table?()
  end

  defp table?, do: TestRepo.query!("SELECT to_regclass('release_fixture')").rows != [[nil]]
end
