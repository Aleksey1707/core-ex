import Config

# Библиотека не навязывает потребителю никаких настроек: контракт описан
# в `Core.Config` и README, значения задаёт приложение-хост.
#
# Здесь — только конфигурация окружений самой библиотеки (тесты, dev).

# `tzdata` (dev/test-зависимость) по умолчанию поднимает `Tzdata.ReleaseUpdater`: тот
# ходит на data.iana.org и пишет в `_build/*/lib/tzdata/priv`. Сборке и тестам библиотеки
# хватает базы из пакета, а сеть в тестах — внешняя зависимость без тега (`19-testing.md`).
config :tzdata, :autoupdate, :disabled

import_config "#{config_env()}.exs"
