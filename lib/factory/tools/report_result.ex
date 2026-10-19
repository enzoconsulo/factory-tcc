defmodule Factory.Tools.ReportResult do
  @moduledoc """
  The ONLY way an agent reports what it did.

  The database is the truth. The agent does not write state: it calls this tool, and the
  system changes status and counts attempts. A tool to change status does not exist for any
  agent — it is an impossibility in code, not a request in the prompt. A structured call also
  costs a single turn, instead of turns spent rewriting task files.

  Fields outside the allowlist are dropped WITH A WARNING returned in the same response;
  dropping them silently would leave the agent believing it changed state.

  The `cycles` row only exists at the END of a dispatch, when the dispatch is recorded,
  but agents report DURING the loop. So reports go to an in-memory collector
  (`start_collector/0`, `append/2`); the caller reads them with `reports/1` after the loop,
  merges them with `format_reports/1` and passes the text as the report of the same
  transaction that records the cycle. If the agent dies mid-loop, nothing is persisted.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Factory.Repo
  alias Factory.Tasks.Cycle

  # An explicit allowlist: it refuses what nobody foresaw.
  @accepted_fields ~w[summary files commands commit blocker]a

  # Fields that belong to the system, named so the warning can say which one was dropped.
  @system_fields ~w[status attempts outcome cycle number approved done]a

  @typedoc "What goes back to the agent in the same tool response."
  @type reply :: %{recorded: boolean(), warnings: [String.t()]}

  @doc "The fields the agent may report."
  @spec accepted_fields() :: [atom()]
  def accepted_fields, do: @accepted_fields

  @doc "The fields that belong to the SYSTEM, never to the agent."
  @spec system_fields() :: [atom()]
  def system_fields, do: @system_fields

  @doc "Stores the agent report on an existing cycle, inside a transaction."
  @spec record(pos_integer(), map()) :: {:ok, reply()} | {:error, term()}
  def record(cycle_id, reported) when is_map(reported) do
    {accepted, warnings} = split(reported)

    Multi.new()
    |> Multi.run(:cycle, fn repo, _ -> fetch_cycle(repo, cycle_id) end)
    |> Multi.update(:write, fn %{cycle: cycle} ->
      Cycle.changeset(cycle, %{report: format(accepted)})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, %{recorded: true, warnings: warnings}}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Starts an in-memory collector for reports made DURING the loop, before a `cycle_id`
  exists. Does not touch the database.
  """
  @spec start_collector() :: {:ok, pid()}
  def start_collector, do: Agent.start_link(fn -> [] end)

  @doc """
  Accepts a report made during the loop, accumulating it in call order. Returns the same
  `reply()` shape as `record/2`.
  """
  @spec append(pid(), map()) :: reply()
  def append(collector, reported) when is_map(reported) do
    {accepted, warnings} = split(reported)
    Agent.update(collector, &(&1 ++ [accepted]))
    %{recorded: true, warnings: warnings}
  end

  @doc "The accepted reports in the collector, in call order."
  @spec reports(pid()) :: [map()]
  def reports(collector), do: Agent.get(collector, & &1)

  @doc "Stops the collector. Call it after reading `reports/1`."
  @spec stop_collector(pid()) :: :ok
  def stop_collector(collector), do: Agent.stop(collector)

  @doc """
  Merges the reports accumulated by `append/2` into one text, in call order.

  Each call is a separate full section, not a field-by-field merge: the agent may report
  different aspects on each call.
  """
  @spec format_reports([map()]) :: String.t()
  def format_reports([]), do: ""

  def format_reports(reports) do
    reports
    |> Enum.map(&format/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  @doc """
  Splits what the agent may report from what it may not, with one warning per dropped field.

  Pure, so the rule is testable without a database.
  """
  @spec split(map()) :: {map(), [String.t()]}
  def split(reported) do
    normalized = Map.new(reported, fn {key, value} -> {to_atom(key), value} end)

    accepted = Map.take(normalized, @accepted_fields)

    warnings =
      normalized
      |> Map.keys()
      |> Enum.filter(&(&1 in @system_fields))
      |> Enum.sort()
      |> Enum.map(&warning/1)

    {accepted, warnings}
  end

  defp warning(field) do
    "the field `#{field}` was IGNORED: it belongs to the system, not to the agent. " <>
      "The factory changes status and counts attempts, based on what the gates decide. " <>
      "Report what you did; the state follows from it, it is not yours to declare."
  end

  defp to_atom(key) when is_atom(key), do: key

  defp to_atom(key) when is_binary(key) do
    # `to_existing_atom`: arbitrary keys from an agent would exhaust the atom table.
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end

  defp fetch_cycle(repo, cycle_id) do
    case repo.one(from(c in Cycle, where: c.id == ^cycle_id)) do
      nil -> {:error, {:cycle_missing, cycle_id}}
      cycle -> {:ok, cycle}
    end
  end

  # Human-readable text, published in the committed markdown; keys come out in a fixed order
  # so an unchanged report produces no diff.
  defp format(accepted) do
    @accepted_fields
    |> Enum.filter(&Map.has_key?(accepted, &1))
    |> Enum.map_join("\n\n", fn field -> "## #{field}\n#{text(Map.get(accepted, field))}" end)
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_list(value), do: Enum.map_join(value, "\n", &"- #{text(&1)}")
  defp text(value), do: inspect(value)
end
