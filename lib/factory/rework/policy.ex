defmodule Factory.Rework.Policy do
  @moduledoc """
  HOW to redo a task: which model, how many turns, what scope, with what focus.

  The ladder (`Factory.Rework.Ladder`) answers "what to do next time"; this struct carries the
  other half, the SIZE of the rework. Without it every failure would get the same dispatch —
  whole scope, 30 turns, the original request — so a one-line fix would cost as much as a
  reimplementation.

  | width | turns | when |
  |---|---|---|
  | `:narrow` | 8 | localized fix: file and line named, minor defect |
  | `:medium` | 18 | functional failure, or a severe defect at a named spot |
  | `:wide` | 30 | whole scope — the agent loop's default cap |
  """

  @typedoc "How much room the next dispatch gets."
  @type width :: :narrow | :medium | :wide

  @typedoc """
  What the builder may touch. `{:files, list}` also narrows the parallelism mutex, letting the
  task run beside another one the original would block.
  """
  @type scope :: {:files, [String.t()]} | :whole_task

  @typedoc "What kind of failure it was."
  @type nature :: :localized | :functional | :conformance | :blocker

  @type t :: %__MODULE__{
          nature: nature(),
          model: :base | :reinforced,
          width: width(),
          turns: pos_integer(),
          scope: scope(),
          focus: [String.t()]
        }

  defstruct [:nature, :model, :width, :turns, :scope, focus: []]

  @turns %{narrow: 8, medium: 18, wide: 30}

  @doc """
  How many turns each width is worth.

  ## Examples

      iex> Factory.Rework.Policy.turns(:narrow)
      8

      iex> Factory.Rework.Policy.turns(:wide)
      30
  """
  @spec turns(width()) :: pos_integer()
  def turns(width), do: Map.fetch!(@turns, width)

  @doc "The three widths, narrowest first."
  @spec widths() :: [width()]
  def widths, do: [:narrow, :medium, :wide]

  @doc """
  The policy as a text block for the dispatch. The focus is numbered in severity order, since
  whoever reads a long list fixes the first items.
  """
  @spec for_dispatch(t()) :: String.t()
  def for_dispatch(%__MODULE__{} = policy) do
    """
    <rework>
    Nature of the failure: #{policy.nature}
    Scope: #{describe_scope(policy.scope)}
    Cap for this round: #{policy.turns} model turns (#{policy.width})

    #{focus_text(policy.focus)}
    </rework>
    """
    |> String.trim()
  end

  defp describe_scope(:whole_task), do: "the whole task"

  defp describe_scope({:files, files}) do
    "ONLY these files: " <> Enum.join(files, ", ")
  end

  defp focus_text([]), do: "No named findings."

  defp focus_text(items) do
    numbered =
      items
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {item, position} -> "#{position}. #{item}" end)

    "Fix, in this order:\n" <> numbered
  end
end
