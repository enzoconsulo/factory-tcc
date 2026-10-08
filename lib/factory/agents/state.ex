defmodule Factory.Agents.State do
  @moduledoc """
  State of an agent loop.

  The turn cap and the spend cap live here, in the process state, and are checked by the
  loop — never in the prompt. A cap requested in the prompt is one the model can ignore; a
  cap in the process state cannot be ignored, because the agent is not the one deciding
  whether to continue.
  """

  alias Factory.Provider.Usage

  @typedoc "Why the loop ended."
  @type outcome :: :end_turn | :max_turns | :spend_cap | :refusal | :error | nil

  @type t :: %__MODULE__{
          root: Path.t(),
          model: String.t(),
          role: String.t(),
          provider: module() | nil,
          messages: [map()],
          turns: non_neg_integer(),
          max_turns: pos_integer(),
          spent_usd: float(),
          max_spend_usd: float() | nil,
          usages: [Usage.t()],
          outcome: outcome(),
          error_reason: term(),
          needle: pid() | nil,
          tools: map(),
          tool_calls: non_neg_integer()
        }

  defstruct root: ".",
            model: "haiku-4.5",
            role: "builder",
            provider: nil,
            messages: [],
            turns: 0,
            max_turns: 30,
            spent_usd: 0.0,
            max_spend_usd: nil,
            usages: [],
            outcome: nil,
            error_reason: nil,
            needle: nil,
            tools: %{},
            tool_calls: 0

  @doc "Builds the initial state from the dispatch options."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Appends a full turn: what the model said and ALL tool results together.

  Results go in a single turn, not one per message: splitting them teaches the model to stop
  requesting tools in parallel.
  """
  @spec append_turn(t(), [map()], [map()]) :: t()
  def append_turn(state, model_blocks, results) do
    turns = [
      %{role: :assistant, content: model_blocks},
      %{role: :user, content: results}
    ]

    %{state | messages: state.messages ++ turns}
  end

  @doc """
  Records one turn: stores the usage, adds the spend and the tool calls.

  This happens BEFORE deciding whether to continue, so a loop cut short still leaves a record
  of what it spent. `tool_calls` counts `:tool_use` blocks, not executed tools: under the
  `:full_agent` family the loop never executes anything itself.
  """
  @spec record_usage(t(), Usage.t(), float(), non_neg_integer()) :: t()
  def record_usage(state, %Usage{} = usage, cost_usd, tool_calls \\ 0) do
    %{
      state
      | turns: state.turns + 1,
        usages: state.usages ++ [usage],
        spent_usd: state.spent_usd + cost_usd,
        tool_calls: state.tool_calls + tool_calls
    }
  end

  @doc "Tells whether the loop may take another turn, and why not when it may not."
  @spec check_continue(t()) :: :ok | {:stop, outcome()}
  def check_continue(state) do
    cond do
      state.turns >= state.max_turns -> {:stop, :max_turns}
      spend_exceeded?(state) -> {:stop, :spend_cap}
      true -> :ok
    end
  end

  defp spend_exceeded?(%{max_spend_usd: nil}), do: false
  defp spend_exceeded?(state), do: state.spent_usd >= state.max_spend_usd

  @doc """
  Loop summary for the caller.

  `error_reason` is set only when `outcome == :error`: the raw term the provider returned
  (`{:quota, reopens_at}`, `:sandbox_unavailable`, `:timeout`, ...), so callers can tell a
  wall (quota, sandbox) from an error caused by the work itself.
  """
  @spec summary(t()) :: map()
  def summary(state) do
    %{
      outcome: state.outcome,
      error_reason: state.error_reason,
      turns: state.turns,
      spent_usd: Float.round(state.spent_usd, 6),
      usages: state.usages,
      messages: state.messages,
      tool_calls: state.tool_calls
    }
  end
end
