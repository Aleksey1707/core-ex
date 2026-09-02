defmodule Core.PrimFixture do
  @moduledoc false

  defmodule Purgeable do
    @moduledoc false

    use Core.Prim.UUID, name: "Фикстура"
  end

  defmodule PurgeableDump do
    @moduledoc false

    use Core.Prim.UUID, name: "Фикстура dump"
  end

  # Чувствительные фикстуры живут здесь, а не в тесте: `@derive Inspect`
  # обязан попасть в консолидацию протоколов до старта тестов.
  defmodule Sensitive do
    @moduledoc false

    use Core.Prim.String,
      name: "Чувствительная строка",
      min_len: 8,
      max_len: 32,
      sensitive: true
  end

  defmodule Plain do
    @moduledoc false

    use Core.Prim.String,
      name: "Обычная строка",
      min_len: 3,
      max_len: 32
  end

  defmodule SensitiveRef do
    @moduledoc false

    use Core.Prim.Compose, name: "Ссылка на чувствительную строку", of: Sensitive
  end

  # Композит объявлен чувствительным поверх обычного базового Prim: ошибку строит база,
  # и её `detail` с plaintext попадает во внешнюю ошибку как `parent`.
  defmodule SensitiveOverPlain do
    @moduledoc false

    use Core.Prim.Compose,
      name: "Чувствительная ссылка на обычную строку",
      of: Plain,
      sensitive: true
  end

  # Аналоги доменных чувствительных Prim приложения-потребителя: строка-пароль
  # и UUID идентификатора сессии. Нужны, чтобы проверить `@derive Inspect`
  # на обоих базовых типах, а не только на строке.
  defmodule Password do
    @moduledoc false

    use Core.Prim.String,
      name: "Пароль",
      min_len: 8,
      max_len: 256,
      sensitive: true
  end

  defmodule Session do
    @moduledoc false

    defmodule ID do
      @moduledoc false

      use Core.Prim.UUID,
        name: "Идентификатор",
        version: 7,
        sensitive: true
    end
  end
end
