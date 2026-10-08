defmodule Factory.Rework.Ladder do
  @moduledoc """
  The four steps of the response to failure. Each step is used only after the previous one
  really failed.

      1. escalate model       <- 1st failure
      2. switch specialist    <- 2nd failure UNDER THE SAME specialist
      3. replan               <- 3 cycles exhausted
      4. block                <- exhausted again (already the result of a replan)

  The trigger is always a recorded fact — the `attempts` counter, incremented by the system —
  never a guess about difficulty.

  1. **Escalate model**: repeating the same model pays builder, verifier and reviewer again and
     burns one of the three cycles.
  2. **Switch specialist**: the specialist was chosen at planning time, before anyone knew where
     the task would fail; two failures under the same domain prompt suggest it biases the
     attack, so the third attempt goes to the generic reinforced builder. The reason is recorded.
  3. **Replan**: three exhausted cycles suggest a SIZING problem, not an execution one. The
     planner splits the task; the original becomes `cancelled` with a reference.
  4. **Block**: self-correction happens ONCE per lineage, otherwise an impossible task would
     spawn replacements forever.

  On top of that, a per-round dispatch cap (12) is defence in depth: it trusts neither the
  ladder nor the counter and cuts by raw dispatch count. Worst legitimate case is 3 cycles x 3
  roles = 9 dispatches. Hitting the cap removes the task from the round without blocking it;
  the next round starts counting again.
  """

  @typedoc "Which step of the ladder."
  @type step :: :escalate_model | :switch_specialist | :replan | :block

  @typedoc """
  What is known about the task when deciding. `specialists_used` is in run ORDER: it answers
  "were both failures under the same specialist?".
  """
  @type situation :: %{
          optional(:specialists_used) => [String.t() | nil],
          optional(:replanned_from) => term() | nil,
          optional(:dispatches_in_round) => non_neg_integer(),
          attempts: non_neg_integer()
        }

  @type decision :: %{
          step: step(),
          model: :base | :reinforced,
          specialist: :keep | :generic_reinforced,
          reason: String.t()
        }

  @max_attempts 3
  @max_dispatches 12

  @doc "Maximum cycles before exhaustion."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "Maximum dispatches of one task in one round (defence in depth)."
  @spec max_dispatches() :: pos_integer()
  def max_dispatches, do: @max_dispatches

  @doc """
  What to do with this task now.

  Returns `{:ok, decision}` to dispatch again, or `{:stop, reason}` when there is no next
  dispatch — because of the round cap (the task comes back next round) or a block (the task
  waits for the user).

  ## Examples

      iex> Factory.Rework.Ladder.next_step(%{attempts: 1})
      {:ok,
       %{
         step: :escalate_model,
         model: :reinforced,
         specialist: :keep,
         reason: "1st failure: repeating the same model pays the whole cycle again"
       }}
  """
  @spec next_step(situation()) :: {:ok, decision()} | {:stop, term()}
  def next_step(situation) do
    cond do
      round_cap_hit?(situation) -> {:stop, :max_dispatches}
      cycles_exhausted?(situation) -> end_of_line(situation)
      true -> {:ok, rework_step(situation)}
    end
  end

  # Checked FIRST on purpose: the cap trusts nothing that comes after it.
  defp round_cap_hit?(situation) do
    Map.get(situation, :dispatches_in_round, 0) >= @max_dispatches
  end

  defp cycles_exhausted?(situation), do: situation.attempts >= @max_attempts

  defp end_of_line(situation) do
    if replanned?(situation) do
      {:stop,
       {:blocked,
        "exhausted the #{@max_attempts} cycles and is ALREADY the result of a replan: " <>
          "self-correction happens once per lineage"}}
    else
      {:ok,
       %{
         step: :replan,
         model: :reinforced,
         specialist: :keep,
         reason:
           "exhausted the #{@max_attempts} cycles: the problem may be one of SIZING, " <>
             "not execution"
       }}
    end
  end

  defp replanned?(situation), do: Map.get(situation, :replanned_from) not in [nil, ""]

  defp rework_step(situation) do
    if situation.attempts >= 2 and same_specialist?(situation) do
      switch_specialist(situation)
    else
      escalate_model(situation)
    end
  end

  defp escalate_model(situation) do
    %{
      step: :escalate_model,
      model: model(situation.attempts),
      specialist: :keep,
      reason: model_reason(situation.attempts)
    }
  end

  defp switch_specialist(situation) do
    used = situation |> Map.get(:specialists_used, []) |> List.first()

    %{
      step: :switch_specialist,
      model: :reinforced,
      specialist: :generic_reinforced,
      reason:
        "2nd failure under the same specialist (#{used}): it was chosen at planning time, " <>
          "before anyone knew where the task would fail, and two failures under the same " <>
          "domain prompt are evidence of a biased attack"
    }
  end

  defp model(0), do: :base
  defp model(_attempts), do: :reinforced

  defp model_reason(0), do: "first run: uses the base model"

  defp model_reason(1) do
    "1st failure: repeating the same model pays the whole cycle again"
  end

  defp model_reason(_attempts) do
    "rework: the previous bet already failed, and repeating it burns one of the " <>
      "#{@max_attempts} cycles"
  end

  # Two or more runs, all with the SAME named specialist. A task without a specialist already
  # runs on the generic builder, so there is nothing to switch.
  defp same_specialist?(situation) do
    case situation |> Map.get(:specialists_used, []) |> Enum.uniq() do
      [single] when single not in [nil, ""] ->
        length(Map.get(situation, :specialists_used, [])) >= 2

      _many_or_none ->
        false
    end
  end
end
