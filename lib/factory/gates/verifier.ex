defmodule Factory.Gates.Verifier do
  @moduledoc """
  The first gate: **"does it work?"**, answered by executing the acceptance criteria.

  It receives the mechanical pass (`Factory.Criteria.run/3`) already done and handles what is
  left: the judgement criteria no command answers.

  The tool catalog gives this role no `write` or `edit` tool: a gate that can fix what it fails
  is no longer a gate. It runs on the cheap model on purpose, since verifying is mechanical; the
  reviewer reads the diff afterwards on the base model.

  Approval requires that NO criterion failed, and an `:inconclusive` criterion blocks approval:
  "I don't know" must never become "yes".
  """

  alias Factory.Criteria
  alias Factory.Tools.Catalog

  @role "verifier"

  @typedoc "The gate's verdict."
  @type verdict :: %{
          approved: boolean(),
          reason: :approved | :criterion_failed | :no_proof,
          results: [Criteria.result()],
          report: String.t()
        }

  @doc "This gate's role in the tool catalog."
  @spec role() :: String.t()
  def role, do: @role

  @doc "This role's tools. Never includes writing."
  @spec tools() :: {:ok, map()} | {:error, :unknown_role}
  def tools, do: Catalog.for_role(@role)

  @doc """
  Judges the task from the mechanical-pass results.

  Fails when some criterion failed by DELIVERY; does not approve while an `:inconclusive`
  criterion is pending. Criteria without a command (`:not_run`) do not block approval here —
  the verifier judges them itself and reports them as `:inspected`.
  """
  @spec judge([Criteria.result()]) :: verdict()
  def judge(results) do
    reason =
      cond do
        Criteria.failed?(results) -> :criterion_failed
        Criteria.inconclusive(results) != [] -> :no_proof
        true -> :approved
      end

    %{
      approved: reason == :approved,
      reason: reason,
      results: results,
      report: Criteria.report(results)
    }
  end

  @doc """
  What the verifier needs to see: the task text and the ready mechanical-pass report. The diff,
  history and sources are deliberately left out — reading code is the other gate's question.
  """
  @spec context(String.t(), String.t()) :: %{role: String.t(), blocks: [{atom(), String.t()}]}
  def context(task_text, mechanical_report) do
    %{
      role: @role,
      blocks: [
        {:task, task_text},
        {:mechanical_pass, mechanical_report}
      ]
    }
  end
end
