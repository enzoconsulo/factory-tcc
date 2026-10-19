defmodule Factory.Tools.Catalog do
  @moduledoc """
  Which tools each role receives: governance as a data structure.

  The central rule is an absence. No role gets a tool able to write `tasks.status` or
  `tasks.attempts`: it does not exist in the catalog nor in the code. Agents report through
  `report_result`; the system changes state and counts attempts. A test scans the catalog
  and fails if any tool appears with the power to write state.

  The second absence: `verifier` and `reviewer` get neither `write` nor `edit`. A gate that
  can fix what it rejects is no longer a gate.
  """

  @typedoc "What a tool can do. There is deliberately no `:state` power."
  @type power :: :read | :write | :execute | :report

  @tools %{
    "read" => %{power: :read, description: "reads a project file"},
    "list" => %{power: :read, description: "lists the project files"},
    "search" => %{power: :read, description: "searches for text in the project files"},
    "write" => %{power: :write, description: "writes a project file"},
    "edit" => %{power: :write, description: "replaces one exact occurrence in a file"},
    "run" => %{power: :execute, description: "runs a command in the project directory"},
    "report_result" => %{
      power: :report,
      description: "reports what was done. Does NOT change state: the system does"
    }
  }

  @by_role %{
    "builder" => ~w[read list search write edit run report_result],
    "verifier" => ~w[read list search run report_result],
    "reviewer" => ~w[read list search report_result],
    "planner" => ~w[read list search report_result],
    "documenter" => ~w[read list search write edit report_result],
    "researcher" => ~w[read list search report_result]
  }

  @doc "The roles the factory dispatches."
  @spec roles() :: [String.t()]
  def roles, do: Map.keys(@by_role) |> Enum.sort()

  @doc "Every existing tool, with its power."
  @spec tools() :: %{String.t() => map()}
  def tools, do: @tools

  @doc """
  The tools of a role, with their descriptions.

  An unknown role returns `{:error, :unknown_role}` instead of an empty list: an agent with no
  tools would run silently until the turn cap, at the cost of a useful dispatch.
  """
  @spec for_role(String.t()) :: {:ok, %{String.t() => map()}} | {:error, :unknown_role}
  def for_role(role) do
    case Map.fetch(@by_role, role) do
      {:ok, names} -> {:ok, Map.take(@tools, names)}
      :error -> {:error, :unknown_role}
    end
  end

  @doc "Tells whether a role may write files. Verifier and reviewer may not."
  @spec can_write?(String.t()) :: boolean()
  def can_write?(role) do
    case for_role(role) do
      {:ok, tools} -> Enum.any?(tools, fn {_, t} -> t.power == :write end)
      {:error, _} -> false
    end
  end

  @doc """
  The powers present in the whole catalog.

  Used by the negative test: a tool with the power to write state would show up here.
  """
  @spec powers() :: [power()]
  def powers do
    @tools |> Map.values() |> Enum.map(& &1.power) |> Enum.uniq() |> Enum.sort()
  end
end
