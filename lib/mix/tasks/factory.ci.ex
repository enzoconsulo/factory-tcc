defmodule Mix.Tasks.Factory.Ci do
  @shortdoc "Runs the verification battery declared in _management/ci.json"

  @moduledoc """
  Runs the stages of `_management/ci.json` in order, printing each result.

      mix factory.ci          # every stage, including `types`
      mix factory.ci --fast   # skips stages marked `"fast": false` (Dialyzer)

  The first failing stage stops the rest and the command exits non-zero. Skipped stages are
  printed as SKIPPED. The rules live in `Factory.CI`; this task is only the shell.
  """

  use Mix.Task

  alias Factory.CI

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [fast: :boolean])
    fast? = Keyword.get(opts, :fast, false)

    case CI.stages() do
      {:ok, stages} -> run_stages(stages, fast?)
      {:error, reason} -> Mix.raise("could not read _management/ci.json: #{inspect(reason)}")
    end
  end

  defp run_stages(stages, fast?) do
    Mix.shell().info("verification battery — #{length(stages)} stages declared")
    if fast?, do: Mix.shell().info("fast mode: stages marked as slow will be skipped")
    Mix.shell().info("")

    {outcome, results} = CI.run(stages, fast: fast?, runner: &run_stage/1)

    Mix.shell().info("")
    Enum.each(results, &print/1)
    summarize(outcome, stages, results)
  end

  # Prints a failing stage's output right away, instead of at the end.
  defp run_stage(stage) do
    Mix.shell().info("  ... #{stage.name}: #{stage.command}")
    {outcome, code, output} = CI.run_stage(stage)

    if outcome == :error do
      Mix.shell().info("")
      Mix.shell().error(output)
    end

    {outcome, code, output}
  end

  defp print(%{stage: stage, outcome: outcome} = result) do
    mark =
      case outcome do
        :ok -> "ok     "
        :error -> "FAILED "
        :skipped -> "SKIPPED"
      end

    time =
      case result.duration_ms do
        nil -> "     —"
        ms -> String.pad_leading("#{Float.round(ms / 1000, 1)}s", 6)
      end

    Mix.shell().info("  #{String.pad_trailing(stage.name, 10)} #{mark}  #{time}")
  end

  defp summarize(:ok, stages, results) do
    skipped = Enum.count(results, &(&1.outcome == :skipped))
    ran = length(stages) - skipped

    Mix.shell().info("")
    Mix.shell().info("battery passed: #{ran} stage(s) ok, #{skipped} skipped")
  end

  defp summarize(:error, stages, results) do
    broken = Enum.find(results, &(&1.outcome == :error))
    not_reached = length(stages) - length(results)

    Mix.shell().info("")

    Mix.shell().error(
      "battery FAILED at stage `#{broken.stage.name}` " <>
        "(code #{broken.code}); #{not_reached} stage(s) did not run"
    )

    exit({:shutdown, 1})
  end
end
