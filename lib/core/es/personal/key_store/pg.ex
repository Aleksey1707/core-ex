defmodule Core.Es.Personal.KeyStore.Pg do
  @moduledoc """
  Встроенное хранилище ключей субъектов (ADR-0075) — рабочая реализация порта
  `Core.Es.Personal.KeyStore` по умолчанию.

  - Таблица `es_subject_keys` в базе `Core.Config.dao()`, DDL — `Core.Es.Personal.KeyStore.Migration`.
  - Ключ субъекта — 32 случайных байта, обёрнут AES-256-GCM под KEK из конфигурации; AAD обёртки —
    идентификатор ключа и версия KEK.
  - Кеша нет: запрос — на пачку, развёртка ключа — на каждое обращение. Запросы идут с
    `log: false`.

  ## Конфигурация

      config :core, Core.Es.Personal.KeyStore.Pg,
        keks: %{1 => "<base64 32 байт>"},
        current_kek: 1,
        index_secret: "<base64 32 байт>"

  - `keks` — набор версий KEK (map или список пар `{версия, base64}`): уникальные положительные
    целые до 2³¹ − 1, ключи по 32 байта;
  - `current_kek` — текущая версия: новые ключи оборачивает она, остальные только разворачивают;
  - `index_secret` — секрет индекса, 32 байта, отдельно от KEK и без версии.

  Сборка конфигурацию не требует. `ensure_configured!/0` проверяет её форму на старте
  приложения с ПДн; без конфигурации первая операция поднимает `ArgumentError`.

  ## Схема `1`

  Шифротекст — `1 ‖ идентификатор ключа (16 байт) ‖ nonce (12 байт) ‖ ct ‖ tag (16 байт)`,
  AES-256-GCM; AAD — заголовок (`1 ‖ идентификатор ключа`) и адрес. Индекс — HMAC-SHA256 секретом
  индекса над `Core.Es.Personal.Port.address([область | части])`, hex. Схема неизменяема.

  ## Исходы

  | Операция | Исход |
  |---|---|
  | `seal/1` | строки ключей пачки читаются `FOR SHARE` в порядке субъектов (`COLLATE "C"`, как `Enum.sort/1`); недостающие ключи вставляются пачкой в порядке субъектов с `on_conflict: :nothing`, затем перечитывание и один повтор; не вышло — `:key_unresolved`; след ключа — `:subject_destroyed` |
  | `open/1` | один запрос на пачку; след — `:destroyed` при любой версии KEK; неизвестный ключ, несошедшийся тег, неизвестная версия схемы — `:unreadable`; версии KEK строки нет в конфигурации — `:kek_unknown` на всю пачку |
  | `destroy/1` | `INSERT … ON CONFLICT (subject) DO UPDATE`: обёрнутый ключ стирается, первая дата уничтожения сохраняется, субъект без ключа получает след |

  ## Ротация KEK

  `rewrap/1` перевёртывает обёртки живых ключей под нетекущими версиями на `current_kek:` пачками
  в своих транзакциях, `status/0` считает живые ключи по версиям KEK; версию удаляют из `keks:`,
  когда под ней ноль. Оператор зовёт обе через `mix es.personal.rewrap`. Это не операция порта:
  KEK — дело встроенной реализации (ADR-0075).

  Ошибки — `%Core.Error{ns: :key_store}`: `:subject_destroyed` (`:domain`,
  `Core.Es.Personal.KeyStore.subject_destroyed/1`); `:app` — `:kek_unknown` (версии KEK строки нет в
  конфигурации), `:key_unresolved` (ключ субъекта не получен) и `:unavailable` (запрос к базе не
  выполнен).
  """

  @behaviour Core.Es.Personal.KeyStore

  alias Core.Config
  alias Core.Error
  alias Core.Es.Personal.KeyStore
  alias Core.Es.Personal.Port
  alias Core.Helper.Transact
  alias Core.Result

  require Error

  use Core.Options

  @schema 1
  @key_size 32
  @nonce_size 12
  @tag_size 16
  @aead :aes_256_gcm
  # Версия KEK — колонка `integer` и 32 бита AAD обёртки.
  @max_version 2_147_483_647

  @select_by_subject """
  SELECT id, subject, wrapped_key, kek_version FROM es_subject_keys
  WHERE subject = ANY($1) ORDER BY subject COLLATE "C" FOR SHARE
  """

  @insert """
  INSERT INTO es_subject_keys (id, subject, wrapped_key, kek_version, created_at)
  SELECT k.id, k.subject, k.wrapped_key, $4, $5
  FROM unnest($1::uuid[], $2::text[], $3::bytea[]) AS k(id, subject, wrapped_key)
  ON CONFLICT (subject) DO NOTHING
  """

  @rewrap_batch_size 500

  @select_stale """
  SELECT id, subject, wrapped_key, kek_version FROM es_subject_keys
  WHERE wrapped_key IS NOT NULL AND kek_version <> $1
  ORDER BY id LIMIT $2 FOR UPDATE
  """

  @rewrap """
  UPDATE es_subject_keys AS s SET wrapped_key = k.wrapped_key, kek_version = $3
  FROM unnest($1::uuid[], $2::bytea[]) AS k(id, wrapped_key)
  WHERE s.id = k.id
  """

  @status "SELECT kek_version, count(*) FROM es_subject_keys WHERE wrapped_key IS NOT NULL GROUP BY kek_version"

  @select_by_id "SELECT id, wrapped_key, kek_version FROM es_subject_keys WHERE id = ANY($1)"

  @destroy """
  INSERT INTO es_subject_keys (id, subject, wrapped_key, kek_version, created_at, destroyed_at)
  VALUES ($1, $2, NULL, NULL, $3, $3)
  ON CONFLICT (subject) DO UPDATE
  SET wrapped_key = NULL, destroyed_at = COALESCE(es_subject_keys.destroyed_at, EXCLUDED.destroyed_at)
  """

  # ===== конфигурация =====

  @doc """
  Проверить форму конфигурации — на старте приложения с ПДн (`start/2`), до первой операции.

  Проверяет наличие ключей, `current_kek` в наборе, версии — уникальные положительные целые,
  KEK и секрет индекса — base64 по 32 байта. К базе не обращается. Отказ — `ArgumentError`.
  """
  @spec ensure_configured!() :: :ok

  def ensure_configured! do
    _config = config!()
    :ok
  end

  # ===== seal =====

  @doc "Зашифровать пачку; недостающие ключи субъектов создаются в транзакции вызывающего."
  @spec seal([{KeyStore.subject(), binary(), binary()}]) :: Result.t([binary()])

  @impl true
  def seal([]), do: {:ok, []}

  def seal([_ | _] = items) do
    config = config!()
    subjects = Enum.sort(Enum.uniq(Enum.map(items, &elem(&1, 0))))

    with {:ok, keys} <- resolve_keys(subjects, config, 1) do
      {:ok, Enum.map(items, fn {subject, aad, plaintext} -> encrypt(Map.fetch!(keys, subject), aad, plaintext) end)}
    end
  end

  # ---

  defp resolve_keys(subjects, config, retries) do
    with {:ok, rows} <- query(@select_by_subject, [subjects]) do
      found = Map.new(rows, fn [id, subject, wrapped, version] -> {subject, {id, wrapped, version}} end)

      case {destroyed_subject(subjects, found), subjects -- Map.keys(found)} do
        {subject, _missing} when is_binary(subject) -> {:error, KeyStore.subject_destroyed(subject)}
        {nil, []} -> unwrap_keys(found, config)
        {nil, missing} when retries < 0 -> {:error, key_unresolved(missing)}
        {nil, missing} -> create_keys(subjects, missing, config, retries)
      end
    end
  end

  defp create_keys(subjects, missing, config, retries) do
    with :ok <- insert(missing, config), do: resolve_keys(subjects, config, retries - 1)
  end

  defp destroyed_subject(subjects, found) do
    Enum.find(subjects, &match?({:ok, {_id, nil, _version}}, Map.fetch(found, &1)))
  end

  defp unwrap_keys(found, config) do
    Enum.reduce_while(found, {:ok, %{}}, fn {subject, {id, wrapped, version}}, {:ok, acc} ->
      case unwrap(id, wrapped, version, config) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, subject, {id, key})}}
        :error -> {:halt, {:error, key_unresolved([subject])}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp insert(subjects, config) do
    kek = Map.fetch!(config.keks, config.current)
    ids = Enum.map(subjects, fn _subject -> Ecto.UUID.bingenerate() end)
    wrapped = Enum.map(ids, &wrap(&1, :crypto.strong_rand_bytes(@key_size), kek, config.current))

    with {:ok, _rows} <- query(@insert, [ids, subjects, wrapped, config.current, NaiveDateTime.utc_now()]), do: :ok
  end

  defp encrypt({id, key}, aad, plaintext) do
    header = <<@schema, id::binary-16>>
    nonce = :crypto.strong_rand_bytes(@nonce_size)
    {ct, tag} = :crypto.crypto_one_time_aead(@aead, key, nonce, plaintext, header <> aad, @tag_size, true)

    header <> nonce <> ct <> tag
  end

  # ===== open =====

  @doc "Расшифровать пачку одним запросом в таблицу ключей."
  @spec open([{binary(), binary()}]) :: Result.t([KeyStore.opened()])

  @impl true
  def open([]), do: {:ok, []}

  def open([_ | _] = items) do
    config = config!()
    parsed = Enum.map(items, &parse/1)
    ids = for({:sealed, id, _header, _nonce, _ct, _tag, _aad} <- parsed, uniq: true, do: id)

    with {:ok, rows} <- query(@select_by_id, [ids]),
         {:ok, keys} <- open_keys(rows, config) do
      {:ok, Enum.map(parsed, &decrypt(&1, keys))}
    end
  end

  # ---

  defp parse({<<@schema, id::binary-16, nonce::binary-size(@nonce_size), rest::binary>> = ciphertext, aad})
       when byte_size(rest) >= @tag_size and is_binary(aad) do
    size = byte_size(rest) - @tag_size
    <<ct::binary-size(^size), tag::binary-size(@tag_size)>> = rest

    {:sealed, id, binary_part(ciphertext, 0, 17), nonce, ct, tag, aad}
  end

  defp parse({ciphertext, aad}) when is_binary(ciphertext) and is_binary(aad), do: :unreadable

  defp open_keys(rows, config) do
    Enum.reduce_while(rows, {:ok, %{}}, fn [id, wrapped, version], {:ok, acc} ->
      case open_key(id, wrapped, version, config) do
        {:error, _reason} = error -> {:halt, error}
        key -> {:cont, {:ok, Map.put(acc, id, key)}}
      end
    end)
  end

  defp open_key(_id, nil, _version, _config), do: :destroyed

  defp open_key(id, wrapped, version, config) do
    case unwrap(id, wrapped, version, config) do
      {:ok, key} -> {:key, key}
      :error -> :unreadable
      {:error, _reason} = error -> error
    end
  end

  defp decrypt(:unreadable, _keys), do: :unreadable

  defp decrypt({:sealed, id, header, nonce, ct, tag, aad}, keys) do
    case Map.get(keys, id, :unreadable) do
      {:key, key} -> decrypt_value(key, header, nonce, ct, tag, aad)
      outcome -> outcome
    end
  end

  defp decrypt_value(key, header, nonce, ct, tag, aad) do
    case :crypto.crypto_one_time_aead(@aead, key, nonce, ct, header <> aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :unreadable
    end
  end

  # ===== index =====

  @doc "Индекс пачки: HMAC-SHA256 секретом индекса, hex."
  @spec index([{String.t(), [String.t()]}]) :: Result.t([String.t()])

  @impl true
  def index(items) when is_list(items) do
    secret = config!().index_secret

    {:ok,
     Enum.map(items, fn {scope, parts} when is_binary(scope) and is_list(parts) ->
       Base.encode16(:crypto.mac(:hmac, :sha256, secret, Port.address([scope | parts])), case: :lower)
     end)}
  end

  # ===== destroy =====

  @doc "Уничтожить ключ субъекта: обёрнутый ключ стирается, строка остаётся следом."
  @spec destroy(KeyStore.subject()) :: Result.unit()

  @impl true
  def destroy(subject) when is_binary(subject) do
    _config = config!()
    now = NaiveDateTime.utc_now()

    with {:ok, _rows} <- query(@destroy, [Ecto.UUID.bingenerate(), subject, now]), do: :ok
  end

  # ===== перевёртка =====

  @opts_schema [
    batch_size: [type: :pos_integer, default: @rewrap_batch_size, doc: "Сколько живых ключей берёт пачка."],
    on_batch: [
      type: {:fun, 1},
      default: &Function.identity/1,
      doc:
        "Функция от числа ключей, перевёрнутых с начала прогона; зовётся после commit каждой " <>
          "непустой пачки (прогресс оператору)."
    ]
  ]
  @doc """
  Перевернуть обёртки живых ключей под нетекущими версиями KEK на `current_kek:` — шаг ротации KEK.

  Пачка — до `batch_size:` живых ключей под нетекущей версией, в своей транзакции, `FOR UPDATE` в
  порядке идентификатора, без `SKIP LOCKED`: запись и уничтожение субъектов пачки ждут её commit.
  Каждый ключ оборачивается текущим KEK с новым nonce, AAD — идентификатор ключа и новая версия.
  Цикл идёт до пустой пачки, повторный запуск продолжает с места остановки.

  Возвращает число перевёрнутых ключей. Обрыв пачки — `{:error, _}` без повтора: пачка
  откатывается, закоммиченные остаются; ключ под версией вне `keks:` — `:kek_unknown`, обёртка,
  которая не разворачивается, — `:key_unresolved`. Внутри транзакции — `ArgumentError`: пачки
  стали бы точками сохранения, и блокировки держались бы до чужого commit.

  ## Опции

  #{Core.Options.docs(@opts_schema)}
  """
  @spec rewrap(keyword()) :: Result.t(non_neg_integer())

  def rewrap(opts) when is_list(opts) do
    ensure_outside_transaction!(Config.dao().in_transaction?())

    rewrap_batches(config!(), Keyword.fetch!(opts, :batch_size), Keyword.fetch!(opts, :on_batch), 0)
  end

  # ---

  defp ensure_outside_transaction!(false), do: :ok

  defp ensure_outside_transaction!(true) do
    raise ArgumentError,
          "Core.Es.Personal.KeyStore.Pg.rewrap/1 вызван внутри транзакции — блокировки всех пачек " <>
            "держались бы до её commit"
  end

  defp rewrap_batches(config, batch_size, on_batch, total) do
    case Transact.run(Config.dao(), fn -> rewrap_batch(config, batch_size) end) do
      {:ok, 0} ->
        {:ok, total}

      {:ok, count} ->
        on_batch.(total + count)
        rewrap_batches(config, batch_size, on_batch, total + count)

      {:error, _reason} = error ->
        error
    end
  end

  defp rewrap_batch(config, batch_size) do
    kek = Map.fetch!(config.keks, config.current)

    with {:ok, rows} <- query(@select_stale, [config.current, batch_size]),
         {:ok, rewrapped} <- Result.traverse(rows, &rewrap_key(&1, kek, config)),
         :ok <- update_wrapped(rewrapped, config.current) do
      {:ok, length(rewrapped)}
    end
  end

  defp rewrap_key([id, subject, wrapped, version], kek, config) do
    case unwrap(id, wrapped, version, config) do
      {:ok, key} -> {:ok, {id, wrap(id, key, kek, config.current)}}
      :error -> {:error, key_unresolved([subject])}
      {:error, _reason} = error -> error
    end
  end

  defp update_wrapped([], _version), do: :ok

  defp update_wrapped(rewrapped, version) do
    {ids, wrapped} = Enum.unzip(rewrapped)

    with {:ok, _rows} <- query(@rewrap, [ids, wrapped, version]), do: :ok
  end

  # ===== статус =====

  @doc """
  Число живых ключей по версиям KEK: версия из `keks:` без ключей — `0`, строки-следы не в счёт.

  Старую версию удаляют из `keks:`, когда под ней ноль (`rewrap/1`).
  """
  @spec status() :: Result.t(%{pos_integer() => non_neg_integer()})

  def status do
    config = config!()

    with {:ok, rows} <- query(@status, []) do
      configured = Map.new(config.keks, fn {version, _kek} -> {version, 0} end)

      {:ok, Map.merge(configured, Map.new(rows, fn [version, count] -> {version, count} end))}
    end
  end

  # ===== общее =====

  defp config! do
    env = Application.get_env(:core, __MODULE__) || config_error!("не задан")
    keks = keks!(Keyword.get(env, :keks))
    current = Keyword.get(env, :current_kek)

    if not is_map_key(keks, current), do: config_error!("current_kek: #{inspect(current)} нет в keks:")

    %{keks: keks, current: current, index_secret: secret!(Keyword.get(env, :index_secret), "index_secret:")}
  end

  defp keks!(keks) when (is_map(keks) or is_list(keks)) and keks != [] and keks != %{} do
    versions = Enum.map(keks, &kek_version!/1)

    if versions != Enum.uniq(versions), do: config_error!("keks: версии повторяются")

    Map.new(keks, fn {version, kek} -> {version, secret!(kek, "keks: версия #{version}")} end)
  end

  defp keks!(_keks), do: config_error!("keks: непустой набор %{версия => base64}")

  defp kek_version!({version, _kek}) when is_integer(version) and version > 0 and version <= @max_version,
    do: version

  defp kek_version!({version, _kek}),
    do: config_error!("keks: версия — положительное целое, задано #{inspect(version)}")

  defp kek_version!(other), do: config_error!("keks: пара {версия, base64}, задано #{inspect(other)}")

  defp secret!(encoded, where) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(@key_size)>> = secret} -> secret
      _other -> config_error!("#{where} — base64 #{@key_size} байт")
    end
  end

  defp secret!(_encoded, where), do: config_error!("#{where} — base64 #{@key_size} байт")

  defp config_error!(reason) do
    raise ArgumentError,
          "Core.Es.Personal.KeyStore.Pg: config :core, Core.Es.Personal.KeyStore.Pg — #{reason} " <>
            "(форма — moduledoc Core.Es.Personal.KeyStore.Pg)"
  end

  defp wrap(id, key, kek, version) do
    nonce = :crypto.strong_rand_bytes(@nonce_size)
    {ct, tag} = :crypto.crypto_one_time_aead(@aead, kek, nonce, key, wrap_aad(id, version), @tag_size, true)

    nonce <> ct <> tag
  end

  defp key_unresolved(subjects) do
    Error.app(code: :key_unresolved, ns: :key_store, message: "Ключ субъекта не получен", detail: %{subjects: subjects})
  end

  defp unwrap(id, wrapped, version, config) do
    case {Map.fetch(config.keks, version), wrapped} do
      {:error, _wrapped} ->
        {:error,
         Error.app(
           code: :kek_unknown,
           ns: :key_store,
           message: "Версии KEK нет в конфигурации",
           detail: %{kek_version: version}
         )}

      {{:ok, kek}, <<nonce::binary-size(@nonce_size), key::binary-size(@key_size), tag::binary-size(@tag_size)>>} ->
        case :crypto.crypto_one_time_aead(@aead, kek, nonce, key, wrap_aad(id, version), tag, false) do
          plain when is_binary(plain) -> {:ok, plain}
          :error -> :error
        end

      {{:ok, _kek}, _malformed} ->
        :error
    end
  end

  defp wrap_aad(id, version), do: <<id::binary-16, version::32>>

  # Запросы несут обёрнутый ключ: в лог Ecto они не уходят.
  defp query(sql, params) do
    case Ecto.Adapters.SQL.query(Config.dao(), sql, params, log: false) do
      {:ok, %{rows: rows}} ->
        {:ok, rows}

      {:error, exception} ->
        {:error,
         Error.app(
           code: :unavailable,
           ns: :key_store,
           message: "Хранилище ключей не ответило",
           detail: %{exception: exception.__struct__}
         )}
    end
  end
end
