defmodule Factory.Rework.Diagnosis do
  @moduledoc """
  Reads a failure and decides HOW to redo the task, not just that it must be redone. Pure.

  The ladder decides *whether* and *with whom*; this module decides *with how much*.

  | nature | what happened | scope | width |
  |---|---|---|---|
  | `:blocker` | the builder declared it cannot proceed | whole | medium |
  | `:conformance` | delivered something else | **whole** | wide |
  | `:functional` | an executable criterion failed | whole | medium |
  | `:localized` | finding with a named file and line | **only those files** | by severity |

  The table order is the precedence: no number of turns solves a blocker; making the criteria
  of the wrong task pass is useless, so conformance comes before functional; and a failed
  executable criterion is stronger evidence than a reviewer's reading.

  Scope comes from the nature alone (only `:localized` narrows, since only it names files);
  width comes from nature *and* severity — a `:critical` at a named spot is still a narrow fix,
  but gets the medium cap. The focus is ordered by severity, because whoever reads a long list
  fixes the first items.
  """

  alias Factory.Gates.Reviewer
  alias Factory.Rework.Policy

  @typedoc """
  What is known about the failure. Every field is optional: the verifier emits no findings and
  the reviewer does not fail executable criteria.
  """
  @type failure :: %{
          optional(:gate) => :verifier | :reviewer,
          optional(:conformance) => Reviewer.conformance() | nil,
          optional(:findings) => [Reviewer.finding()],
          optional(:failed_criteria) => [String.t()],
          optional(:blocker) => String.t() | nil,
          optional(:goal) => String.t()
        }

  @doc """
  The nature of the failure, by the precedence above. A failure with no signal at all is
  `:functional`: calling it `:localized` would promise a narrow scope with no file to narrow to.
  """
  @spec nature(failure()) :: Policy.nature()
  def nature(failure) do
    cond do
      blocked?(failure) -> :blocker
      nonconforming?(failure) -> :conformance
      failed_criterion?(failure) -> :functional
      localized?(failure) -> :localized
      true -> :functional
    end
  end

  defp blocked?(failure) do
    case Map.get(failure, :blocker) do
      nil -> false
      text -> String.trim(text) != ""
    end
  end

  defp nonconforming?(failure) do
    match?({:nonconforming, _reason}, Map.get(failure, :conformance))
  end

  defp failed_criterion?(failure) do
    Map.get(failure, :failed_criteria, []) != []
  end

  # Localized requires a NAMED file.
  defp localized?(failure) do
    failure |> findings() |> Enum.any?(&(&1.file not in [nil, ""]))
  end

  defp findings(failure), do: Map.get(failure, :findings, [])

  @doc """
  The policy for the next dispatch.

  `:attempts` is the system counter, read BEFORE the increment: `0` means there has been no run
  yet, so the next one uses the base model; `>= 1` means a run already failed, and repeating
  the same bet would spend another cycle.
  """
  @spec diagnose(failure(), keyword()) :: Policy.t()
  def diagnose(failure, opts \\ []) do
    nature = nature(failure)
    sorted = sort(findings(failure))
    width = width(nature, sorted)

    %Policy{
      nature: nature,
      model: model(Keyword.get(opts, :attempts, 0)),
      width: width,
      turns: Policy.turns(width),
      scope: scope(nature, sorted),
      focus: focus(nature, sorted, failure)
    }
  end

  defp model(attempts) when attempts >= 1, do: :reinforced
  defp model(_attempts), do: :base

  defp width(:conformance, _findings), do: :wide
  defp width(:blocker, _findings), do: :medium
  defp width(:functional, _findings), do: :medium

  defp width(:localized, findings) do
    if Reviewer.worst(findings) in [:critical, :high], do: :medium, else: :narrow
  end

  defp scope(:localized, findings) do
    files =
      findings
      |> Enum.map(& &1.file)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    {:files, files}
  end

  defp scope(_nature, _findings), do: :whole_task

  # On conformance the focus is the GOAL restated, not the defects: fixing bugs in a delivery
  # that is not the task is wasted work.
  defp focus(:conformance, findings, failure) do
    reason =
      case Map.get(failure, :conformance) do
        {:nonconforming, text} -> text
        _other -> "the delivery does not match the request"
      end

    ["WHAT WAS ASKED: #{Map.get(failure, :goal, "(goal not provided)")}"] ++
      ["WHY IT FAILED: #{reason}"] ++ Enum.map(findings, &Reviewer.format/1)
  end

  defp focus(:blocker, findings, failure) do
    ["DECLARED BLOCKER: #{Map.get(failure, :blocker)}"] ++
      Enum.map(findings, &Reviewer.format/1)
  end

  defp focus(_nature, findings, failure) do
    Enum.map(Map.get(failure, :failed_criteria, []), &"FAILED CRITERION: #{&1}") ++
      Enum.map(findings, &Reviewer.format/1)
  end

  # By severity; `sort_by` is stable, so equal severities keep the reviewer's order.
  defp sort(findings) do
    position = Reviewer.severities() |> Enum.with_index() |> Map.new()

    Enum.sort_by(findings, &Map.get(position, &1.severity, 99))
  end
end
