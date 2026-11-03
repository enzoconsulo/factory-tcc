defmodule Factory.Criteria.FailureClass do
  @moduledoc """
  When a criterion does not pass, is the problem the COMMAND or the DELIVERY? Pure.

  Without this distinction everything that fails goes back to the builder, treating "the test
  failed" and "the command does not exist" alike — and the builder, who may not change
  criteria, gets dispatched again and again to fix something that was already right.

  | class | what happened | consequence |
  |---|---|---|
  | `:broken_tool` | the command evaluated nothing | no cycle spent; the criterion must be fixed |
  | `:environment` | the machine got in the way | rerun ONCE; no cycle spent |
  | `:delivery` | it ran and the result is wrong | spends a cycle; back to the builder |

  The hard case is "target not found", which looks identical in both directions. The
  discriminator is the disk, not the message: a target that exists and does not load is a tool
  problem; a target that does not exist is a real failure (the task should have created it).
  The target only counts when it is an argument of the command itself.

  When in doubt, `:delivery`: erring towards failing costs at most one cycle; erring the other
  way lets defects through.
  """

  @typedoc "Why the command did not pass."
  @type t :: :broken_tool | :environment | :delivery

  @typedoc """
  What is known about the failed run. `exists_on_disk` is a function so that this module stays
  pure; the caller resolves paths against the project root.
  """
  @type context :: %{
          optional(:signal) => String.t() | nil,
          optional(:exists_on_disk) => (String.t() -> boolean()),
          argv: [String.t()],
          output: String.t(),
          code: integer() | String.t() | nil,
          timed_out: boolean()
        }

  # Exit codes meaning "could not even start", always tied to a binary. 127 and 9009 come from
  # the command interpreter, so they apply to any binary.
  @misuse %{
    "*" => [127, 9009],
    "node" => [9],
    "git" => [129]
  }

  # A native crash on Windows arrives as an error NTSTATUS exit code (>= 0xC0000000), e.g.
  # 0xC0000409 (stack buffer overrun) and 0xC0000005 (access violation).
  @ntstatus_floor 0xC0000000

  # The machine got in the way. EBUSY and EPERM cover files locked by cloud sync.
  @environment_signals [
    ~r/\bENOMEM\b/,
    ~r/\bEMFILE\b/,
    ~r/\bENFILE\b/,
    ~r/\bEAGAIN\b/,
    ~r/\bEADDRINUSE\b/,
    ~r/\bECONNRESET\b/,
    ~r/\bETIMEDOUT\b/,
    ~r/\bEBUSY\b/,
    ~r/\bEPERM\b/,
    ~r/JavaScript heap out of memory/i,
    ~r/runtime: out of memory/i,
    ~r/\bMemoryError\b/,
    ~r/\berlang.*out of memory\b/i
  ]

  # The binary does not exist. These are SHELL messages (English and Portuguese Windows).
  @missing_binary_signals [
    ~r/\bcommand not found\b/i,
    ~r/is not recognized as an internal or external command/i,
    ~r/n[aã]o [eé] reconhecido como um comando/i,
    ~r/\bspawn\b[^\n]*\bENOENT\b/i
  ]

  # The binary exists but did not understand the request. `argument` sits next to `option`
  # because real `git` says `fatal: unrecognized argument: --x`. A missing signal here does not
  # fail loudly: it misclassifies a broken criterion as `:delivery`.
  @invalid_option_signals [
    ~r/\bbad option\b/i,
    ~r/\bunknown option\b/i,
    ~r/\bunrecognized option\b/i,
    ~r/\binvalid option\b/i,
    ~r/\bunknown argument\b/i,
    ~r/\bunrecognized argument\b/i,
    ~r/\bunknown switch\b/i,
    ~r/\bMissing script\b/i,
    ~r/\bThe task .* could not be found\b/i,
    ~r/\bunknown flag\b/i
  ]

  # The TARGET the command could not open, when the error names one; one pattern per ecosystem.
  @target_patterns [
    ~r/Cannot find module ['"]([^'"]+)['"]/,
    ~r/Cannot find package ['"]([^'"]+)['"]/,
    ~r/can't open file ['"]([^'"]+)['"]/i,
    ~r/No such file or directory: ['"]([^'"]+)['"]/i,
    ~r/no Go files in (\S+)/,
    ~r/Could not find file ['"]([^'"]+)['"]/i,
    ~r/MSB1009[^\n]*?([^\s"']+\.(?:sln|csproj|fsproj|vbproj))/i
  ]

  @doc """
  Classifies why the command did not pass.

  The order of the checks is part of the rule: unambiguous environment signals come first, and
  resource exhaustion comes last, because its message can appear inside the output of a suite
  that ran fully and failed for another reason.
  """
  @spec classify(context()) :: t()
  def classify(context) do
    context = Map.put_new(context, :exists_on_disk, fn _path -> false end)

    cond do
      unambiguous_environment?(context) -> :environment
      missing_binary?(context) -> :broken_tool
      misuse?(context) -> :broken_tool
      invalid_option?(context) -> :broken_tool
      target_exists_but_fails_to_load?(context) -> :broken_tool
      resource_exhausted?(context) -> :environment
      true -> :delivery
    end
  end

  # Our own timeout, a killing signal, or an error NTSTATUS: none of these is a matter of opinion.
  defp unambiguous_environment?(context) do
    context.timed_out or
      (Map.get(context, :signal) || "") != "" or
      (is_integer(context.code) and context.code >= @ntstatus_floor)
  end

  defp missing_binary?(context) do
    context.code == "ENOENT" or matches_any?(context.output, @missing_binary_signals)
  end

  defp misuse?(%{code: code} = context) when is_integer(code) do
    binary = binary_of(context.argv)

    code in Map.get(@misuse, "*", []) or
      (code in Map.get(@misuse, binary, []) and
         matches_any?(context.output, @invalid_option_signals))
  end

  defp misuse?(_context), do: false

  defp invalid_option?(context), do: matches_any?(context.output, @invalid_option_signals)

  defp resource_exhausted?(context), do: matches_any?(context.output, @environment_signals)

  defp target_exists_but_fails_to_load?(context) do
    case first_target(context.output) do
      nil -> false
      target -> argument?(target, context.argv) and context.exists_on_disk.(target)
    end
  end

  defp first_target(output) do
    Enum.find_value(@target_patterns, fn pattern ->
      case Regex.run(pattern, output || "") do
        [_whole, target] -> empty_to_nil(String.trim(target))
        _no_capture -> nil
      end
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(text), do: text

  defp argument?(target, argv) do
    normalized = normalize_path(target)

    argv
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> Enum.map(&normalize_path/1)
    |> Enum.any?(fn arg ->
      arg != "" and (normalized == arg or String.ends_with?(normalized, "/" <> arg))
    end)
  end

  defp normalize_path(raw) do
    raw |> String.replace("\\", "/") |> String.replace(~r{/+$}, "")
  end

  defp binary_of([program | _]) do
    program |> String.downcase() |> String.replace(~r/\.(exe|cmd|bat)$/, "")
  end

  defp binary_of([]), do: ""

  defp matches_any?(output, patterns) do
    text = output || ""
    Enum.any?(patterns, &Regex.match?(&1, text))
  end

  @doc """
  Does this class spend one of the task's three cycles? Only `:delivery`.

  ## Examples

      iex> Factory.Criteria.FailureClass.counts_cycle?(:delivery)
      true

      iex> Factory.Criteria.FailureClass.counts_cycle?(:broken_tool)
      false
  """
  @spec counts_cycle?(t()) :: boolean()
  def counts_cycle?(:delivery), do: true
  def counts_cycle?(_class), do: false

  @doc """
  Is it worth rerunning the command once? Only for `:environment`: a rerun costs seconds of CPU
  and no tokens, while a false failure costs a whole dispatch plus a cycle. A real regression
  fails both times.
  """
  @spec rerun?(t()) :: boolean()
  def rerun?(:environment), do: true
  def rerun?(_class), do: false

  @doc "Who has to act, as an atom."
  @spec fixer(t()) :: :orchestrator_fixes_criterion | :machine | :builder
  def fixer(:broken_tool), do: :orchestrator_fixes_criterion
  def fixer(:environment), do: :machine
  def fixer(:delivery), do: :builder

  @doc "One line explaining the class, for the report."
  @spec explain(t()) :: String.t()
  def explain(:broken_tool) do
    "the criterion's command did not run — **the criterion itself needs fixing**"
  end

  def explain(:environment) do
    "the machine got in the way (killed process, native crash, timeout or exhausted resource)"
  end

  def explain(:delivery), do: "the command ran and the result is wrong"
end
