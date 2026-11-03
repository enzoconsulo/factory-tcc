defmodule Factory.Gates.Reviewer do
  @moduledoc """
  The second gate, asking **two separate questions**:

  1. **Conformance** — "is it what was asked?"
  2. **Review** — "is it correct?"

  They are independent. A delivery that passes every criterion and has no defect may still not
  be the task, so failing on conformance needs no finding: "nonconforming, zero findings" is a
  valid verdict.

  The reviewer reads the committed DIFF, never whole sources; this module cannot read the disk
  at all (a test scans its source to keep it that way). Like the verifier, the role has no
  `write` or `edit` tool.

  Findings use the canonical line `[severity] file:line — problem`; the severity drives the
  rework policy, so free-prose findings would not be classifiable.
  """

  alias Factory.Tools.Catalog

  @role "reviewer"

  @typedoc "Finding severity, from most to least severe."
  @type severity :: :critical | :high | :medium | :low

  @type finding :: %{
          severity: severity(),
          file: String.t(),
          line: pos_integer() | nil,
          problem: String.t()
        }

  @typedoc "The conformance verdict: is it what was asked?"
  @type conformance :: :conforming | {:nonconforming, String.t()}

  @type verdict :: %{
          approved: boolean(),
          conformance: conformance(),
          findings: [finding()],
          reason: :approved | :nonconforming | :defects
        }

  @severities [:critical, :high, :medium, :low]

  @doc "The severities, from most to least severe."
  @spec severities() :: [severity()]
  def severities, do: @severities

  @doc "This gate's role in the tool catalog."
  @spec role() :: String.t()
  def role, do: @role

  @doc "This role's tools. Never includes writing."
  @spec tools() :: {:ok, map()} | {:error, :unknown_role}
  def tools, do: Catalog.for_role(@role)

  @doc """
  What the reviewer needs to see: the goal, the criteria and the **diff**. There is no path for
  whole source files, not even by argument.
  """
  @spec context(keyword()) :: %{role: String.t(), blocks: [{atom(), String.t()}]}
  def context(parts) do
    %{
      role: @role,
      blocks: [
        {:goal, Keyword.get(parts, :goal, "")},
        {:criteria, Keyword.get(parts, :criteria, "")},
        {:diff, Keyword.get(parts, :diff, "")}
      ]
    }
  end

  @doc """
  Combines both answers into a verdict. Nonconforming fails even with zero findings; conforming
  still fails if there are defects.

  ## Examples

      iex> Factory.Gates.Reviewer.judge({:nonconforming, "delivered something else"}, [])
      %{
        approved: false,
        conformance: {:nonconforming, "delivered something else"},
        findings: [],
        reason: :nonconforming
      }
  """
  @spec judge(conformance(), [finding()]) :: verdict()
  def judge(conformance, findings \\ []) do
    reason =
      cond do
        match?({:nonconforming, _}, conformance) -> :nonconforming
        findings != [] -> :defects
        true -> :approved
      end

    %{
      approved: reason == :approved,
      conformance: conformance,
      findings: findings,
      reason: reason
    }
  end

  @doc """
  Formats a finding as the canonical line. A finding without a line omits `:line` (a defect of
  the whole file).

  ## Examples

      iex> Factory.Gates.Reviewer.format(%{
      ...>   severity: :high,
      ...>   file: "lib/a.ex",
      ...>   line: 42,
      ...>   problem: "division without a zero guard"
      ...> })
      "[high] lib/a.ex:42 — division without a zero guard"
  """
  @spec format(finding()) :: String.t()
  def format(%{line: nil} = finding) do
    "[#{finding.severity}] #{finding.file} — #{finding.problem}"
  end

  def format(finding) do
    "[#{finding.severity}] #{finding.file}:#{finding.line} — #{finding.problem}"
  end

  @doc """
  Parses findings from text, one per line. Tolerant: non-matching lines are ignored. Both the
  em dash and the hyphen are accepted as separator.
  """
  @spec parse_findings(String.t() | nil) :: [finding()]
  def parse_findings(text) do
    text
    |> to_string()
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&finding_from_line/1)
  end

  @pattern ~r/^\s*[-*]?\s*\[(critical|high|medium|low)\]\s+([^\s:]+?)(?::(\d+))?\s+[—-]\s+(.+?)\s*$/iu

  defp finding_from_line(line) do
    case Regex.run(@pattern, line) do
      [_whole, severity, file, "", problem] ->
        [build(severity, file, nil, problem)]

      [_whole, severity, file, file_line, problem] ->
        [build(severity, file, String.to_integer(file_line), problem)]

      _not_a_finding ->
        []
    end
  end

  defp build(severity, file, line, problem) do
    %{
      severity: String.to_existing_atom(String.downcase(severity)),
      file: file,
      line: line,
      problem: problem
    }
  end

  @doc """
  Parses the CONFORMANCE verdict from the agent's structured report. One line, anywhere:

      [conformance] conforming
      [conformance] nonconforming — reason here

  A missing or malformed line (e.g. `nonconforming` without `— reason`) yields `:conforming`:
  only an explicit nonconformance declaration fails. With several matching lines, the LAST wins.
  """
  @spec parse_conformance(String.t() | nil) :: conformance()
  def parse_conformance(text) do
    text
    |> to_string()
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(:conforming, fn line, current ->
      case conformance_from_line(line) do
        nil -> current
        found -> found
      end
    end)
  end

  @nonconforming_pattern ~r/^\s*[-*]?\s*\[conformance\]\s*:?\s*non[-_]?conforming\s*[—-]\s*(.+?)\s*$/iu
  @conforming_pattern ~r/^\s*[-*]?\s*\[conformance\]\s*:?\s*conforming\s*$/iu

  defp conformance_from_line(line) do
    case Regex.run(@nonconforming_pattern, line) do
      [_whole, reason] ->
        {:nonconforming, reason}

      nil ->
        case Regex.run(@conforming_pattern, line) do
          [_whole] -> :conforming
          nil -> nil
        end
    end
  end

  @doc "The most severe finding's severity, or `nil`."
  @spec worst([finding()]) :: severity() | nil
  def worst([]), do: nil

  def worst(findings) do
    Enum.find(@severities, fn severity ->
      Enum.any?(findings, &(&1.severity == severity))
    end)
  end
end
