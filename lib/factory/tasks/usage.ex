defmodule Factory.Tasks.Usage do
  @moduledoc """
  What a single turn consumed: one row per turn. Totals per task are sums; storing only the
  total would hide the split between fresh input, cache reads and cache writes.

  Two units are kept: `cost_usd` is an accounting estimate, `quota_units` is what the
  operation actually spends under a subscription (see `Factory.Cost.Pricing`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Tasks.Dispatch

  @type t :: %__MODULE__{}

  schema "usages" do
    field :turn, :integer
    field :input_tokens, :integer, default: 0
    field :cache_write_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_usd, :decimal, default: Decimal.new(0)
    field :quota_units, :decimal, default: Decimal.new(0)
    field :duration_ms, :integer

    belongs_to :dispatch, Dispatch

    timestamps(type: :utc_datetime_usec)
  end

  @tokens [:input_tokens, :cache_write_tokens, :cache_read_tokens, :output_tokens]
  @fields [:dispatch_id, :turn, :cost_usd, :quota_units, :duration_ms] ++ @tokens

  @doc "The four token fields, in accounting order."
  @spec token_fields() :: [atom()]
  def token_fields, do: @tokens

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(usage, attrs) do
    usage
    |> cast(attrs, @fields)
    |> validate_required([:dispatch_id, :turn])
    |> validate_number(:turn, greater_than_or_equal_to: 1)
    |> validate_tokens_non_negative()
    |> assoc_constraint(:dispatch)
    |> unique_constraint([:dispatch_id, :turn])
    |> check_constraint(:turn, name: :turn_positive)
  end

  defp validate_tokens_non_negative(changeset) do
    Enum.reduce(@tokens, changeset, fn field, acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end
end
