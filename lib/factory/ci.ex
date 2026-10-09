defmodule Factory.CI do
  @moduledoc """
  The project's verification battery, read from `_management/ci.json`. The file is the
  source of truth, so criteria are never written from memory.

  Execution is split in two: `run/2` is pure with respect to the outside world (it receives
  the function that runs a stage) and holds the rule "the first failure stops the rest", so
  the rule is testable without running real commands; `run_stage/1` talks to the OS.
  """

  @default_path "_management/ci.json"

  @type stage :: %{
          name: String.t(),
          command: String.t(),
          fast: boolean(),
          description: String.t()
        }

  @type result :: %{
          stage: stage(),
          outcome: :ok | :error | :skipped,
          code: integer() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @doc """
  Reads the declared stages. Stages that are not part of the fast mode stay in the list, so
  the output can report them as SKIPPED instead of silently omitting them.
  """
  @spec stages(keyword()) :: {:ok, [stage()]} | {:error, term()}
  def stages(opts \\ []) do
    path = Keyword.get(opts, :path, @default_path)

    with {:ok, raw} <- File.read(path),
         {:ok, %{"stages" => list}} <- Jason.decode(raw) do
      {:ok, Enum.map(list, &normalize/1)}
    else
      {:error, :enoent} -> {:error, {:ci_json_missing, path}}
      {:ok, _without_stages} -> {:error, :ci_json_without_stages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(raw) do
    %{
      name: Map.fetch!(raw, "name"),
      command: Map.fetch!(raw, "command"),
      fast: Map.get(raw, "fast", true),
      description: Map.get(raw, "description", "")
    }
  end

  @doc """
  Runs the stages in order and STOPS at the first failure.

  `:runner` receives a stage and returns `{:ok | :error, code, output}`. With `fast: true`,
  stages with `fast: false` come back with outcome `:skipped`, in their position.

  Returns `{:ok | :error, results}`; results cover only the stages reached.
  """
  @spec run([stage()], keyword()) :: {:ok | :error, [result()]}
  def run(stages, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_stage/1)
    fast? = Keyword.get(opts, :fast, false)

    {results, outcome} =
      Enum.reduce_while(stages, {[], :ok}, fn stage, {acc, _} ->
        step(stage, acc, skip?(stage, fast?), runner)
      end)

    {outcome, Enum.reverse(results)}
  end

  defp skip?(stage, fast?), do: fast? and not stage.fast

  defp step(stage, acc, true, _runner) do
    {:cont, {[skipped(stage) | acc], :ok}}
  end

  defp step(stage, acc, false, runner) do
    result = measure(stage, runner)
    continuation = if result.outcome == :ok, do: :cont, else: :halt

    {continuation, {[result | acc], result.outcome}}
  end

  defp skipped(stage) do
    %{stage: stage, outcome: :skipped, code: nil, duration_ms: nil}
  end

  defp measure(stage, runner) do
    start = System.monotonic_time(:millisecond)
    {outcome, code, _output} = runner.(stage)
    finish = System.monotonic_time(:millisecond)

    %{stage: stage, outcome: outcome, code: code, duration_ms: finish - start}
  end

  @doc """
  Runs ONE stage as a subprocess. On Windows `mix` is a `.bat` that `System.cmd/3` cannot
  find, so the call goes through `cmd /c`.
  """
  @spec run_stage(stage()) :: {:ok | :error, integer(), String.t()}
  def run_stage(%{command: command}) do
    [executable | args] = String.split(command, " ", trim: true)
    {program, prefix} = invocation(executable)

    {output, code} =
      System.cmd(program, prefix ++ args,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", nil}]
      )

    {if(code == 0, do: :ok, else: :error), code, output}
  end

  defp invocation(executable) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", executable]}
      _ -> {executable, []}
    end
  end
end
