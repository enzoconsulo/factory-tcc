defmodule Factory.Cost.Usage do
  @moduledoc """
  Bridges the usage a provider reports and the row the database stores.

  Three things are called "usage" and they differ on purpose: `Factory.Provider.Usage` is
  what an adapter returns for one turn and knows nothing about the database;
  `Factory.Tasks.Usage` is the Ecto schema, one row per turn; this module converts between
  them and sums. Prices are computed here (via `Factory.Cost.Pricing`) and nowhere else.
  """

  alias Factory.Cost.Pricing
  alias Factory.Provider.Usage, as: Reported

  @doc """
  Converts the usage reported for one turn into the attributes of a `usages` row.
  `turn` and `dispatch_id` come from the system, never from the agent.
  """
  @spec to_record(String.t(), Reported.t(), keyword()) ::
          {:ok, map()} | {:error, :unpriced_model}
  def to_record(model, %Reported{} = reported, opts) do
    with {:ok, breakdown} <- Pricing.estimate(model, reported) do
      {:ok,
       %{
         dispatch_id: Keyword.fetch!(opts, :dispatch_id),
         turn: Keyword.fetch!(opts, :turn),
         input_tokens: reported.input_tokens,
         cache_write_tokens: reported.cache_write_tokens,
         cache_read_tokens: reported.cache_read_tokens,
         output_tokens: reported.output_tokens,
         cost_usd: Decimal.from_float(breakdown.total_usd),
         quota_units: Decimal.from_float(breakdown.quota_units),
         duration_ms: reported.duration_ms
       }}
    end
  end

  @doc "Sums the tokens of a set of turns, independently of prices."
  @spec sum_tokens([Reported.t()]) :: %{
          input_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          turns: non_neg_integer()
        }
  def sum_tokens(reported) do
    zero = %{
      input_tokens: 0,
      cache_write_tokens: 0,
      cache_read_tokens: 0,
      output_tokens: 0,
      turns: 0
    }

    Enum.reduce(reported, zero, fn %Reported{} = r, acc ->
      %{
        input_tokens: acc.input_tokens + r.input_tokens,
        cache_write_tokens: acc.cache_write_tokens + r.cache_write_tokens,
        cache_read_tokens: acc.cache_read_tokens + r.cache_read_tokens,
        output_tokens: acc.output_tokens + r.output_tokens,
        turns: acc.turns + 1
      }
    end)
  end

  @doc """
  Cache read : cache write ratio, which summarizes whether the cache is working. A drop
  means the prompt prefix stopped being stable somewhere. `nil` when nothing was written.
  """
  @spec cache_ratio([Reported.t()]) :: float() | nil
  def cache_ratio(reported) do
    sum = sum_tokens(reported)

    case sum.cache_write_tokens do
      0 -> nil
      written -> Float.round(sum.cache_read_tokens / written, 2)
    end
  end
end
