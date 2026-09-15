defmodule Core.EsFixture.Account.Event do
  @moduledoc """
  События счёта: с нагрузкой (`Opened`, `Renamed`), без неё (`Frozen`, `Closed`) и удалённый тип
  `Verified` — его больше не пишут, но записанные читаются.
  """

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  defmodule Opened do
    @moduledoc "Счёт открыт."

    defmodule Payload do
      @moduledoc "Нагрузка `Opened`."

      @enforce_keys ~w(name)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{name: Account.Name.t()}

      @doc "Собрать нагрузку."
      @spec new(Account.Name.t()) :: t()

      def new(%Account.Name{} = name), do: %__MODULE__{name: name}
    end

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Renamed do
    @moduledoc "Счёт переименован."

    defmodule Payload do
      @moduledoc "Нагрузка `Renamed`."

      @enforce_keys ~w(name)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{name: Account.Name.t()}

      @doc "Собрать нагрузку."
      @spec new(Account.Name.t()) :: t()

      def new(%Account.Name{} = name), do: %__MODULE__{name: name}
    end

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Frozen do
    @moduledoc "Счёт заморожен."

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: nil
  end

  defmodule Closed do
    @moduledoc "Счёт закрыт."

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: nil
  end

  defmodule Verified do
    @moduledoc "Счёт проверен. Тип удалён: событие больше не пишется."

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Opened.t() | Renamed.t() | Frozen.t() | Closed.t() | Verified.t()

  @doc "Wire-имя события."
  @spec name(t()) :: String.t()

  def name(event), do: Account.Event.Codec.type(event)

  @doc "Множество wire-имён событий счёта."
  @spec names() :: MapSet.t(String.t())

  def names, do: Account.Event.Codec.types()
end
