defmodule Factory.Tasks.StateMachine do
  @moduledoc """
  Which status transitions exist. Pure functions, no database and no side effects.

  The rule lives here and the write lives in `Factory.Tasks.Transition`, which always asks
  this module first, so no code path writes a status without the check.

  ## The map

      backlog     -> ready        (every dependency done)
      ready       -> in_progress  (dispatched to the builder)
      in_progress -> in_testing   (builder finished)
      in_testing  -> in_review    (verifier approved)
      in_testing  -> in_progress  (verifier rejected)
      in_review   -> done         (reviewer approved)
      in_review   -> in_progress  (reviewer rejected)
      any         -> blocked      (cycles exhausted)
      any         -> cancelled    (replanning)

  "Any" excludes the ends: `done` leads nowhere (undoing approved work requires a new task),
  `cancelled` is the end of a lineage, and `blocked -> cancelled` is legal because a blocked
  task is cancelled when the planner replaces it with new tasks.

  Entering `in_progress` hands the task to a builder and therefore spends an attempt
  (`hands_to_builder?/1`); `Factory.Tasks.Transition` increments `attempts` in the same
  transaction, never the agent.
  """

  alias Factory.Tasks.Task

  @type state :: atom()

  @transitions %{
    backlog: [:ready, :blocked, :cancelled],
    ready: [:in_progress, :blocked, :cancelled],
    in_progress: [:in_testing, :blocked, :cancelled],
    in_testing: [:in_review, :in_progress, :blocked, :cancelled],
    in_review: [:done, :in_progress, :blocked, :cancelled],
    done: [],
    blocked: [:cancelled],
    cancelled: []
  }

  @doc """
  The whole map, origin => legal targets. Public so tests can sweep every combination
  without copying the table.
  """
  @spec transitions() :: %{state() => [state()]}
  def transitions, do: @transitions

  @doc "Every state the machine knows: the six pipeline states plus the two terminal ones."
  @spec states() :: [state()]
  def states, do: Task.states() ++ Task.terminal_states()

  @doc "Where this state may go. An unknown state leads nowhere."
  @spec targets(state()) :: [state()]
  def targets(from), do: Map.get(@transitions, from, [])

  @doc """
  Is the transition legal?

  ## Examples

      iex> Factory.Tasks.StateMachine.can?(:in_testing, :in_progress)
      true

      iex> Factory.Tasks.StateMachine.can?(:backlog, :done)
      false
  """
  @spec can?(state(), state()) :: boolean()
  def can?(from, to), do: to in targets(from)

  @doc """
  Same question as `can?/2`, returning a named error instead of `false` (used inside an
  `Ecto.Multi`, where a bare `false` would not say what was attempted).
  """
  @spec check(state(), state()) :: :ok | {:error, {:invalid_transition, state(), state()}}
  def check(from, to) do
    if can?(from, to), do: :ok, else: {:error, {:invalid_transition, from, to}}
  end

  @doc "Is the state a dead end?"
  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: targets(state) == []

  @doc """
  Does this transition hand the task to a builder, spending an attempt? True for the first
  run and for every rework: what counts is entering `in_progress`.
  """
  @spec hands_to_builder?(state()) :: boolean()
  def hands_to_builder?(:in_progress), do: true
  def hands_to_builder?(_to), do: false
end
