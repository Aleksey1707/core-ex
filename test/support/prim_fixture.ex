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

    use Core.Prim.Compose,
      name: "Ссылка на чувствительную строку",
      of: Sensitive
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

  # Персональные фикстуры — там же и по той же причине: `@derive Inspect` персонального
  # Prim обязан попасть в консолидацию протоколов.
  defmodule Personal do
    @moduledoc false

    use Core.Prim.String,
      name: "Телефон",
      min_len: 8,
      max_len: 32,
      personal: true
  end

  defmodule PersonalRef do
    @moduledoc false

    use Core.Prim.Compose,
      name: "Ссылка на телефон",
      of: Personal
  end

  # Композит объявлен персональным поверх обычного базового Prim: ошибку строит база,
  # и её `detail` с plaintext попадает во внешнюю ошибку как `parent`.
  defmodule PersonalOverPlain do
    @moduledoc false

    use Core.Prim.Compose,
      name: "Персональная ссылка на обычную строку",
      of: Plain,
      personal: true
  end

  # Субъект поля нагрузки — композит над UUID, как роль поверх идентификатора лица.
  defmodule SubjectRef do
    @moduledoc false

    use Core.Prim.Compose,
      name: "Ссылка на лицо",
      of: Core.EsFixture.UserID
  end

  defmodule SensitiveLabel do
    @moduledoc false

    use Core.Prim.UUID,
      name: "Чувствительная метка",
      version: 4,
      kind: :label,
      sensitive: true
  end

  defmodule PersonalSensitive do
    @moduledoc false

    use Core.Prim.String,
      name: "Номер документа",
      min_len: 8,
      max_len: 32,
      personal: true,
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
