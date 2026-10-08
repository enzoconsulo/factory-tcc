defmodule Factory.Criteria do
  @moduledoc """
  The MECHANICAL pass: runs, for free, every criterion that has a command, before spending a
  dispatch on the verifier.

  It answers "did the declared command pass?", never "is the delivery right?" — criteria
  without a command stay with the verifier. The mechanical pass never approves a task: it gets
  work done early and fails early.

  Two criteria running the same command execute ONCE; the second inherits the verdict and is
  marked as a mirror. The command key is conservative on purpose: when in doubt, run.

  The report labels each criterion and closes with a `Proof levels:` line. This pass produces
  `[executed]` (a command gave a verdict) and `[judged]` (no command, refused command, or
  inconclusive); `[inspected]` comes only from the verifier, and `report/1` accepts it so both
  halves add up on the same ladder. Inconclusive results get their own line below `Proof
  levels:`, because what they add is the action (who fixes what), not a level.

  The implicit suite criterion (`Factory.Criteria.Suite.append/2`) is marked `[implicit]` so a
  reader can tell "the factory ran this" from "someone asked for this".
  """

  alias Factory.Criteria.Allowlist
  alias Factory.Criteria.FailureClass
  alias Factory.Tools.Command

  @typedoc "A criterion read from the task file. `command` is `nil` for judgement criteria."
  @type criterion :: %{
          optional(:implicit) => boolean(),
          text: String.t(),
          command: String.t() | nil,
          checked: boolean()
        }

  @typedoc """
  A criterion's verdict after the pass. `:inconclusive` never fails and never approves: the
  command could not answer the question. With class `:broken_tool` the CRITERION needs fixing,
  not the delivery.
  """
  @type state :: :passed | :failed | :not_run | :inconclusive

  @type result :: %{
          text: String.t(),
          command: String.t() | nil,
          state: state(),
          refusal: Allowlist.reason() | nil,
          class: FailureClass.t() | nil,
          rerun: boolean(),
          implicit: boolean(),
          output: String.t(),
          mirror: boolean()
        }

  @output_limit 2_000

  @doc """
  Parses the criteria in the `## Acceptance criteria` section.

  Tolerant by design: a malformed line becomes a criterion without a command, which just hands
  the decision to the verifier. Indented continuation lines are joined to the criterion.
  """
  @spec parse(String.t() | nil) :: [criterion()]
  def parse(section) do
    lines = section |> to_string() |> String.split(~r/\r?\n/)

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _i} -> Regex.match?(~r/^\s*[-*]\s*\[( |x|X)\]/, line) end)
    |> Enum.map(fn {line, i} -> build_criterion(line, Enum.drop(lines, i + 1)) end)
  end

  defp build_criterion(line, following) do
    [_, mark, first] = Regex.run(~r/^\s*[-*]\s*\[( |x|X)\]\s*(.*?)\s*$/, line)
    whole = [first | continuation(following)] |> Enum.join(" ") |> String.trim()

    %{
      text: without_command(whole),
      command: declared_command(whole),
      checked: String.downcase(mark) == "x",
      implicit: false
    }
  end

  defp continuation(lines) do
    lines
    |> Enum.reduce_while([], fn line, acc ->
      cond do
        Regex.match?(~r/^\s*[-*]\s*\[/, line) -> {:halt, acc}
        String.trim(line) == "" -> {:cont, acc}
        not Regex.match?(~r/^\s+/, line) -> {:halt, acc}
        true -> {:cont, [String.trim(line) | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp declared_command(text) do
    case Regex.run(~r/`verify:\s*([^`]+)`/, text) do
      [_, command] -> String.trim(command)
      nil -> nil
    end
  end

  defp without_command(text) do
    text
    |> String.replace(~r/`verify:[^`]*`/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Runs the mechanical pass over the criteria inside `root`.

  Accepts `:timeout` (default: `Factory.Tools.Command.default_timeout/0`). Never raises.
  """
  @spec run([criterion()], Path.t(), keyword()) :: [result()]
  def run(criteria, root, opts \\ []) do
    {results, _memo} =
      Enum.map_reduce(criteria, %{}, fn criterion, memo ->
        check_and_run(criterion, root, opts, memo)
      end)

    results
  end

  defp check_and_run(criterion, root, opts, memo) do
    case Allowlist.check(criterion.command) do
      {:refused, reason} -> {not_run(criterion, reason), memo}
      {:ok, argv} -> maybe_run(criterion, argv, root, opts, memo)
    end
  end

  defp maybe_run(criterion, argv, root, opts, memo) do
    key = command_key(argv)

    case Map.fetch(memo, key) do
      {:ok, previous} ->
        # The mirror inherits the VERDICT; identity (text, command, implicit mark) stays the
        # current criterion's.
        mirrored = %{
          previous
          | text: criterion.text,
            command: criterion.command,
            implicit: Map.get(criterion, :implicit, false),
            mirror: true
        }

        {mirrored, memo}

      :error ->
        result = execute(criterion, argv, root, opts)
        {result, Map.put(memo, key, result)}
    end
  end

  # A single retry for environment failures: rerunning costs seconds of CPU, a false failure
  # costs a dispatch plus one of the task's cycles. A real regression fails both times.
  defp execute(criterion, argv, root, opts) do
    first = single_run(criterion, argv, root, opts)

    if first.state == :inconclusive and FailureClass.rerun?(first.class) do
      %{single_run(criterion, argv, root, opts) | rerun: true}
    else
      first
    end
  end

  defp single_run(criterion, [program | args] = argv, root, opts) do
    timeout = Keyword.get(opts, :timeout, Command.default_timeout())

    case Command.run(root, program, args, timeout: timeout) do
      {:ok, %{code: 0, reason: :normal} = output} ->
        result(criterion, :passed, output)

      {:ok, output} ->
        judge(criterion, argv, output, root)

      # Spawning itself failed: there was no run to judge, so this is a tool problem by definition.
      {:error, reason} ->
        %{
          base(criterion)
          | state: :inconclusive,
            class: :broken_tool,
            output: inspect(reason)
        }
    end
  end

  defp judge(criterion, argv, output, root) do
    class =
      FailureClass.classify(%{
        argv: argv,
        output: output.stdout <> "\n" <> output.stderr,
        code: output.code,
        timed_out: output.reason == :timeout,
        exists_on_disk: fn path -> File.exists?(Path.expand(path, root)) end
      })

    state = if class == :delivery, do: :failed, else: :inconclusive
    %{result(criterion, state, output) | class: class}
  end

  defp result(criterion, state, output) do
    %{base(criterion) | state: state, output: truncate(output.stdout <> output.stderr)}
  end

  defp base(criterion) do
    %{
      text: criterion.text,
      command: criterion.command,
      state: :not_run,
      refusal: nil,
      class: nil,
      rerun: false,
      implicit: Map.get(criterion, :implicit, false),
      output: "",
      mirror: false
    }
  end

  defp not_run(criterion, reason) do
    %{base(criterion) | refusal: reason}
  end

  defp truncate(text) when byte_size(text) <= @output_limit, do: text

  defp truncate(text) do
    String.slice(text, 0, @output_limit) <> "\n[... output truncated ...]"
  end

  @doc """
  The key that decides whether two criteria run the SAME command.

  Conservative on purpose: it normalises the binary extension and equivalent ways of calling a
  package manager's test script, nothing else. A key that wrongly says "same" would make one
  criterion inherit another's verdict.

  ## Examples

      iex> Factory.Criteria.command_key(["npm", "run", "test"])
      "npm test"

      iex> Factory.Criteria.command_key(["mix.bat", "test"])
      "mix test"
  """
  @spec command_key([String.t()]) :: String.t()
  def command_key(argv) do
    [program | rest] = Enum.reject(argv, &(&1 == ""))
    binary = program |> String.downcase() |> String.replace(~r/\.(exe|cmd|bat)$/, "")

    Enum.join([binary | normalize_script(binary, rest)], " ")
  end

  @package_managers ~w[npm pnpm yarn bun]

  defp normalize_script(binary, ["run", script]) when binary in @package_managers, do: [script]
  defp normalize_script(binary, ["t"]) when binary in @package_managers, do: ["test"]
  defp normalize_script(_binary, rest), do: rest

  @doc """
  The pass report, in proof-ladder format: every criterion labelled, closed by the
  `Proof levels:` line. Accepts results with state `:inspected` so the verifier can add its own.
  """
  @spec report([result()]) :: String.t()
  def report([]), do: ""

  def report(results) do
    lines = ["### Mechanical pass (no model)", "" | Enum.flat_map(results, &line_for/1)]

    Enum.join(lines ++ ["", levels(results) | inconclusive_warning(results)], "\n")
  end

  defp line_for(%{state: :not_run} = result) do
    why =
      case result.refusal do
        :no_command -> "no command declared"
        reason -> "command refused: #{reason}"
      end

    [
      "- [judged]#{implicit_mark(result)} #{result.text} — #{why}; " <>
        "left to the verifier."
    ]
  end

  # Inconclusive is also `[judged]`: there was no mechanical proof. The signal goes to its own
  # line below `Proof levels:`.
  defp line_for(%{state: :inconclusive} = result) do
    mirror = if result.mirror, do: " (same command already evaluated above)", else: ""

    [
      "- [judged]#{implicit_mark(result)} #{result.text} — `#{result.command}` → " <>
        "#{FailureClass.explain(result.class)}#{mirror}. **Does not fail the task.**"
    ] ++
      output_of(result)
  end

  defp line_for(%{state: :inspected} = result) do
    ["- [inspected] #{result.text} — #{result.output}"]
  end

  defp line_for(result) do
    mark = if result.state == :passed, do: "PASSED", else: "FAILED"

    [
      "- [executed]#{implicit_mark(result)} #{result.text} — " <>
        "`#{result.command}` → **#{mark}**#{notes(result)}"
    ] ++ output_of(result)
  end

  defp implicit_mark(%{implicit: true}), do: " [implicit]"
  defp implicit_mark(_result), do: ""

  # Both notes change how the result must be read: the rerun records a false failure that was
  # avoided, and the mirror says this criterion was not checked on its own.
  defp notes(result) do
    [
      {result.mirror, "same command already run above"},
      {result.rerun, "on the 2nd run; the 1st failed due to the environment"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map_join("; ", &elem(&1, 1))
    |> case do
      "" -> ""
      text -> " (#{text})"
    end
  end

  # Output appears only the first time a command appears, never repeated for mirrors.
  defp output_of(%{mirror: false, output: output, state: state})
       when output != "" and state in [:failed, :inconclusive] do
    ["", "```", output, "```", ""]
  end

  defp output_of(_result), do: []

  defp inconclusive_warning(results) do
    case inconclusive(results) do
      [] ->
        []

      list ->
        by_class =
          list
          |> Enum.frequencies_by(& &1.class)
          |> Enum.map_join(", ", fn {class, count} -> "#{count} by #{class}" end)

        [
          "",
          "**#{length(list)} INCONCLUSIVE criteria** (#{by_class}): the command did not " <>
            "answer the question. Does not fail the task" <>
            broken_criterion_note(list) <> "."
        ]
    end
  end

  defp broken_criterion_note(list) do
    if Enum.any?(list, &(&1.class == :broken_tool)) do
      ", and the CRITERION needs fixing — no builder may change it"
    else
      ""
    end
  end

  defp levels(results) do
    counts = Enum.frequencies_by(results, & &1.state)
    executed = Map.get(counts, :passed, 0) + Map.get(counts, :failed, 0)
    inspected = Map.get(counts, :inspected, 0)
    judged = length(results) - executed - inspected

    parts =
      [{executed, "executed"}, {inspected, "inspected"}, {judged, "judged"}]
      |> Enum.reject(fn {count, _label} -> count == 0 end)
      |> Enum.map(fn {count, label} -> "#{count} #{label}" end)

    # Zero counts are left out so the line stays worth reading.
    "Proof levels: #{Enum.join(parts, ", ")} (of #{length(results)})."
  end

  @doc """
  Did any criterion with a command really fail? A mechanical failure sends the task back to the
  builder without spending a verifier; passing here approves nothing.
  """
  @spec failed?([result()]) :: boolean()
  def failed?(results), do: Enum.any?(results, &(&1.state == :failed))

  @doc "Criteria whose command was refused — a PLANNING defect, not a delivery one."
  @spec refused([result()]) :: [result()]
  def refused(results) do
    Enum.filter(results, &(&1.refusal != nil and &1.refusal != :no_command))
  end

  @doc """
  Criteria the command could not answer. They never fail the task; with class `:broken_tool`
  they must be surfaced, since no builder dispatch can fix a criterion.
  """
  @spec inconclusive([result()]) :: [result()]
  def inconclusive(results), do: Enum.filter(results, &(&1.state == :inconclusive))

  @doc "Criteria whose COMMAND needs fixing, not the delivery."
  @spec broken_criteria([result()]) :: [result()]
  def broken_criteria(results) do
    Enum.filter(results, &(&1.class == :broken_tool))
  end

  @doc "How many criteria needed a second run because of the machine."
  @spec reruns([result()]) :: non_neg_integer()
  def reruns(results), do: Enum.count(results, & &1.rerun)

  @doc """
  How many of the task's cycles this pass spent: 1 only if some criterion failed by DELIVERY,
  otherwise 0.
  """
  @spec cycles_spent([result()]) :: 0 | 1
  def cycles_spent(results), do: if(failed?(results), do: 1, else: 0)
end
