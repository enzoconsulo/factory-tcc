defmodule Factory.Cost.Pricing do
  @moduledoc """
  The price table and the cost arithmetic of one turn.

  ## Prices checked on 2026-08-28

  An undated old price is worse than no price, so the date is exposed by `checked_on/0`.

  | model | input (USD/Mtok) | output (USD/Mtok) |
  |---|---|---|
  | `opus-5` | 5 | 25 |
  | `sonnet-5` | 2 | 10 |
  | `haiku-4.5` | 1 | 5 |

  Cache reads cost 0.1x the input price; cache writes cost 1.25x with a 5-minute TTL and
  2.0x with a 1-hour TTL. The TTL is stored per turn so the right multiplier can be applied.

  ## Two units

  Dollar values are an accounting estimate, not an invoice: under `Factory.Provider.ClaudeCLI`
  the limit is the subscription quota, under `Factory.Provider.MessagesAPI` it is money.
  `quota_units/2` gives the quota measure.
  """

  @checked_on ~D[2026-08-28]

  # USD per million tokens.
  @table %{
    "opus-5" => %{input: 5.0, output: 25.0},
    "sonnet-5" => %{input: 2.0, output: 10.0},
    "haiku-4.5" => %{input: 1.0, output: 5.0}
  }

  # Long ids returned by the CLI, and its short aliases, map to the same rows, so
  # "unpriced model" means a model nobody priced rather than one spelled differently. The
  # long ids must match `Factory.Provider.ClaudeCLI.cli_models/0` (a test checks both ends).
  # Short aliases resolve to the newest model of the family; the factory never generates
  # them (only probes do), because an unpriced model would count as zero cost.
  @aliases %{
    "claude-opus-5" => "opus-5",
    "claude-opus-5-5" => "opus-5",
    "claude-sonnet-5" => "sonnet-5",
    "claude-sonnet-5-5" => "sonnet-5",
    "claude-haiku-4-5-20251001" => "haiku-4.5",
    "haiku-4-5" => "haiku-4.5",
    "sonnet" => "sonnet-5",
    "opus" => "opus-5",
    "haiku" => "haiku-4.5"
  }

  @read_multiplier 0.1
  @write_multipliers %{no_cache: 0.0, five_minutes: 1.25, one_hour: 2.0}

  # Quota weights: a convention of this system (not a vendor figure) so that quota usage is
  # comparable across rounds. One unit = one thousand Haiku input tokens.
  @quota_weight %{"opus-5" => 5.0, "sonnet-5" => 2.0, "haiku-4.5" => 1.0}

  alias Factory.Provider.Usage

  @typedoc "A cost breakdown (what a single total would hide)."
  @type breakdown :: %{
          full_input_usd: float(),
          cache_read_usd: float(),
          cache_write_usd: float(),
          output_usd: float(),
          total_usd: float(),
          quota_units: float()
        }

  @doc "The date this table was checked. Cite it whenever citing a value."
  @spec checked_on() :: Date.t()
  def checked_on, do: @checked_on

  @doc "The models with a declared price."
  @spec models() :: [String.t()]
  def models, do: Map.keys(@table)

  @doc """
  Estimates the cost of ONE turn, with the breakdown. Returns `{:error, :unpriced_model}`
  for an unknown model instead of silently counting zero.
  """
  @spec estimate(String.t(), Usage.t()) :: {:ok, breakdown()} | {:error, :unpriced_model}
  def estimate(model, %Usage{} = usage) do
    case price(model) do
      nil ->
        {:error, :unpriced_model}

      %{input: input, output: output} ->
        full_input = per_million(usage.input_tokens, input)
        read = per_million(usage.cache_read_tokens, input * @read_multiplier)
        write = per_million(usage.cache_write_tokens, input * write_multiplier(usage))
        output_usd = per_million(usage.output_tokens, output)

        {:ok,
         %{
           full_input_usd: round_value(full_input),
           cache_read_usd: round_value(read),
           cache_write_usd: round_value(write),
           output_usd: round_value(output_usd),
           total_usd: round_value(full_input + read + write + output_usd),
           quota_units: quota_units(model, usage)
         }}
    end
  end

  @doc """
  Summarizes a set of turns, returning the breakdown rather than only the total, plus the
  share of the input bill that cache writes represent.
  """
  @spec summarize([{String.t(), Usage.t()}]) ::
          {:ok, map()} | {:error, {:unpriced_model, [String.t()]}}
  def summarize(turns) do
    unknown =
      turns
      |> Enum.map(fn {model, _} -> model end)
      |> Enum.uniq()
      |> Enum.reject(&price/1)

    if unknown == [] do
      {:ok, sum(turns)}
    else
      {:error, {:unpriced_model, Enum.sort(unknown)}}
    end
  end

  defp sum(turns) do
    zero = %{
      full_input_usd: 0.0,
      cache_read_usd: 0.0,
      cache_write_usd: 0.0,
      output_usd: 0.0,
      total_usd: 0.0,
      quota_units: 0.0
    }

    summed =
      Enum.reduce(turns, zero, fn {model, usage}, acc ->
        {:ok, part} = estimate(model, usage)
        Map.new(acc, fn {key, value} -> {key, value + part[key]} end)
      end)

    total_input = summed.full_input_usd + summed.cache_read_usd + summed.cache_write_usd

    summed
    |> Map.new(fn {key, value} -> {key, round_value(value)} end)
    |> Map.merge(%{
      turns: length(turns),
      total_input_usd: round_value(total_input),
      cache_write_share_of_input: share(summed.cache_write_usd, total_input)
    })
  end

  @doc """
  The quota one turn consumed, in this system's unit (one thousand Haiku input tokens; other
  models weigh proportionally to their input price; cache reads weigh 0.1x).
  """
  @spec quota_units(String.t(), Usage.t()) :: float()
  def quota_units(model, %Usage{} = usage) do
    weight = Map.get(@quota_weight, canonical(model), 1.0)

    tokens =
      usage.input_tokens +
        usage.cache_write_tokens +
        usage.cache_read_tokens * @read_multiplier +
        usage.output_tokens

    round_value(tokens / 1_000 * weight)
  end

  @doc "The cache write multiplier for this turn's TTL."
  @spec write_multiplier(Usage.t()) :: float()
  def write_multiplier(%Usage{cache_ttl: ttl}), do: Map.get(@write_multipliers, ttl, 1.25)

  @doc "A model's price, accepting the CLI's long ids and short aliases. `nil` if unpriced."
  @spec price(String.t()) :: %{input: float(), output: float()} | nil
  def price(model) when is_binary(model), do: Map.get(@table, canonical(model))
  def price(_), do: nil

  defp canonical(model), do: Map.get(@aliases, model, model)

  defp per_million(tokens, price), do: tokens / 1_000_000 * price

  defp share(_part, whole) when whole == 0.0, do: 0.0
  defp share(part, whole), do: Float.round(part / whole, 4)

  defp round_value(value), do: Float.round(value * 1.0, 8)
end
