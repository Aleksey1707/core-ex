defmodule E18.Row do
  use Ecto.Schema

  schema "rows" do
    field :amount, :integer
    field :payload, :map
  end
end

defmodule E18.Repo do
  use Ecto.Repo, otp_app: :e18, adapter: Ecto.Adapters.Postgres
end

defmodule E18 do
  alias E18.{Repo, Row}

  def schema_typo(%Row{} = r), do: r.amout
  def schema_field_type(%Row{} = r), do: byte_size(r.amount)
  def repo_get_typo(id), do: Repo.get!(Row, id).amout
  def repo_get_field_type(id), do: byte_size(Repo.get!(Row, id).amount)
  def jsonb_payload(%Row{payload: payload}), do: payload.name
  def repo_get_matched_typo(id) do
    %Row{} = row = Repo.get!(Row, id)
    row.amout
  end

  def literal_struct_field_type, do: byte_size(%Row{amount: 1}.amount)
end
