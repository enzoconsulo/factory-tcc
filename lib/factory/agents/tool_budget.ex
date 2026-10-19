defmodule Factory.Agents.ToolBudget do
  @moduledoc """
  How many tool calls a role should spend, and from how many on it has stopped working and
  started thrashing.

  There are two numbers, and they must not be confused:

    * **target** — the cap the prompt tells the agent, so it economizes. It is advice and is
      expected to be exceeded now and then.
    * **thrashing threshold** — the p90 of tool calls measured over 135 real dispatch steps.
      It is an anomaly sensor: it fires on about one dispatch in ten.

  | role | target | threshold |
  |---|---|---|
  | verifier | 25 | 37 |
  | builder | 30–60 | 65 |
  | reviewer | 20 | 28 |

  The number of `areas` does not predict the number of calls, so the threshold is flat for
  the builder; the target still scales with areas because it is sizing advice.

  This module MEASURES AND NEVER CUTS: interrupting a dispatch mid-way costs the same and
  delivers nothing. The tally is stored on the dispatch row so the rework diagnosis and the
  next estimate can use it.
  """

  @default_target 60

  # Not measured: derived from the rule that the threshold must sit above the role's largest
  # target, with the same margin the builder got.
  @default_threshold 65

  @typedoc "A dispatch tally: what was budgeted, what was spent and what it means."
  @type tally :: %{
          role: String.t(),
          target: pos_integer(),
          threshold: pos_integer(),
          calls: non_neg_integer(),
          over_target: boolean(),
          thrashing: boolean()
        }

  @doc """
  The call TARGET for the role — the number the prompt tells the agent.

  Scales with `areas` for the builder as sizing advice, not as a prediction.
  """
  @spec target(String.t(), non_neg_integer()) :: pos_integer()
  def target("builder", areas) when areas <= 2, do: 30
  def target("builder", 3), do: 45
  def target("builder", _areas), do: 60
  def target("verifier", _areas), do: 25
  def target("reviewer", _areas), do: 20
  def target(_role, _areas), do: @default_target

  @doc "The role's THRASHING THRESHOLD — the measured p90, flat for the builder."
  @spec threshold(String.t()) :: pos_integer()
  def threshold("builder"), do: 65
  def threshold("verifier"), do: 37
  def threshold("reviewer"), do: 28
  def threshold(_role), do: @default_threshold

  @doc "Tallies a dispatch. It does not interrupt anything — it only measures and names."
  @spec tally(String.t(), non_neg_integer(), keyword()) :: tally()
  def tally(role, calls, opts \\ []) do
    areas = Keyword.get(opts, :areas, 1)
    target = target(role, areas)
    threshold = threshold(role)

    %{
      role: role,
      target: target,
      threshold: threshold,
      calls: calls,
      over_target: calls > target,
      thrashing: calls > threshold
    }
  end

  @doc "The attributes stored on the `dispatches` row."
  @spec for_dispatch(tally()) :: map()
  def for_dispatch(tally) do
    %{
      outcome:
        cond do
          tally.thrashing -> "thrashing"
          tally.over_target -> "over_target"
          true -> "within_target"
        end
    }
  end

  @doc """
  The report sentence when the dispatch went over the threshold; `nil` otherwise, since a
  message on every round would be noise.
  """
  @spec warning(tally()) :: String.t() | nil
  def warning(%{thrashing: false}), do: nil

  def warning(tally) do
    "the #{tally.role} made #{tally.calls} tool calls, above the thrashing " <>
      "threshold (#{tally.threshold}). The threshold is the measured p90: exceeding it happens " <>
      "in ~1 dispatch in 10 and usually signals a badly sized task, not an inefficient agent."
  end

  @doc "The invariant the test locks: the threshold is always ABOVE the role's largest target."
  @spec consistent?(String.t()) :: boolean()
  def consistent?(role) do
    largest_target = Enum.max(Enum.map(0..8, &target(role, &1)))
    threshold(role) > largest_target
  end
end
