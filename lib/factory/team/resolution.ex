defmodule Factory.Team.Resolution do
  @moduledoc """
  WHO executes the task: the generic role, plus the specialist that is added to it. Pure.

  The planner synthesises 2–5 specialists from the request, and each task points to the one for
  the area it touches. The specialist ADDS to the role, never replaces it: the role carries the
  discipline (commit, state, confinement), and the specialist's prompt is pasted into its own
  `<specialist>` block. So there are exactly two outcomes: role alone, or role + specialist.

  The specialist prompt must be PURE DOMAIN — area files, invariants, the command that proves
  a criterion of the area, known pitfalls — never a repetition of the role's discipline. The
  block goes into the `:doctrine` band of `Factory.Prompt.Prefix`, which is cached, so bloated
  text there is paid as a cache write on every dispatch.

  A task referencing a specialist that does not exist runs on the generic role and the defect
  is recorded (in the result and in the log): in an unattended factory, an unwritten planning
  defect disappears.
  """

  require Logger

  alias Factory.Projects.Specialist

  @typedoc """
  How the executor was reached.

    * `:generic` — the task asks for no specialist, which is normal.
    * `:specialist` — the active specialist was found and its block is added.
    * `{:unknown_specialist, reference}` — the task points to a specialist that does not
      exist; it still runs on the generic role, with the defect recorded.
  """
  @type reason :: :generic | :specialist | {:unknown_specialist, term()}

  @type t :: %__MODULE__{
          role: atom(),
          specialist: Specialist.t() | nil,
          reason: reason()
        }

  defstruct [:role, :specialist, :reason]

  @doc """
  Resolves the executor from the role and the reference declared by the task.

  `reference` is the specialist's `identifier` (or `nil`). The lookup is always for the
  **active** version, so prompt improvements reach the next run; older versions remain in
  `Factory.Team.history/2`.
  """
  @spec resolve(atom(), String.t() | nil, [Specialist.t()]) :: t()
  def resolve(role, reference, active \\ [])

  def resolve(role, nil, _active) do
    %__MODULE__{role: role, specialist: nil, reason: :generic}
  end

  def resolve(role, reference, active) do
    case Enum.find(active, &(&1.identifier == reference and &1.active)) do
      nil -> unknown(role, {:identifier, reference})
      specialist -> %__MODULE__{role: role, specialist: specialist, reason: :specialist}
    end
  end

  @doc false
  @spec unknown(atom(), term()) :: t()
  def unknown(role, reference) do
    Logger.warning(
      "task points to an unknown specialist (#{inspect(reference)}); " <>
        "dispatching on the generic role #{role}. This is a planning defect."
    )

    %__MODULE__{role: role, specialist: nil, reason: {:unknown_specialist, reference}}
  end

  @doc """
  The `:doctrine` band text: the generic role and, when present, the specialist block.
  `role_text` is passed in so assembly stays testable without the tool catalog.
  """
  @spec doctrine(t(), String.t()) :: String.t()
  def doctrine(%__MODULE__{specialist: nil}, role_text) do
    block("your-role", role_text)
  end

  def doctrine(%__MODULE__{specialist: specialist}, role_text) do
    body = "You act as #{specialist.name} on this team.\n\n#{specialist.prompt}"

    block("your-role", role_text) <> "\n\n" <> block("specialist", body)
  end

  defp block(tag, content) do
    "<#{tag}>\n#{String.trim(content)}\n</#{tag}>"
  end

  @doc "Did this resolution hit a planning defect?"
  @spec defective?(t()) :: boolean()
  def defective?(%__MODULE__{reason: {:unknown_specialist, _}}), do: true
  def defective?(%__MODULE__{}), do: false
end
