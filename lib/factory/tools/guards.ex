defmodule Factory.Tools.Guards do
  @moduledoc """
  Two guards that judge a command BEFORE it runs.

  | guard | outcome | why |
  |---|---|---|
  | process | **refuses** | killing the factory is irreversible: the agent dies with it and nobody writes the report |
  | tooling | **warns** | reinventing a wheel is costly but recoverable, and a wrong refusal would block legitimate work |

  The asymmetry is the rule: a tooling guard that refused would turn a guess about intent
  into a wall.

  Both are PURE — no disk, network or clock — so they can be tested exhaustively. If one ever
  needs to query the system, the query becomes a parameter and the judgement stays here.
  """

  @typedoc "The process guard verdict."
  @type verdict :: :allowed | {:refused, reason :: atom(), explanation :: String.t()}

  # Names whose death brings down the runtime itself.
  @runtime_processes ~w[beam beam.smp erl erl.exe werl epmd elixir iex mix]

  @doc """
  Judges a process-killing command.

  It requires proof of ownership: only processes the factory launched may be killed, and only
  by PID — never by image name, which reaches processes nobody here created.

  `launched` is the list of PIDs the factory launched; it is a parameter so the function
  stays pure.
  """
  @spec check_process(String.t(), [pos_integer()]) :: verdict()
  def check_process(command, launched \\ []) when is_binary(command) do
    normalized = String.downcase(command)

    cond do
      not kills_process?(normalized) ->
        :allowed

      reaches_runtime_by_name?(normalized) ->
        {:refused, :would_kill_runtime,
         "this command kills processes by NAME and reaches the factory's own runtime. " <>
           "If it runs, the agent dies with it and nobody writes the report."}

      kills_everything?(normalized) ->
        {:refused, :indiscriminate_kill,
         "this command kills processes without a defined target. The factory may only kill " <>
           "what it launched itself."}

      true ->
        check_ownership(normalized, launched)
    end
  end

  defp check_ownership(command, launched) do
    requested = pids_in_command(command)

    cond do
      requested == [] ->
        {:refused, :no_target,
         "could not identify the target PID. Killing a process requires an explicit PID: " <>
           "without it there is no way to prove the factory launched the process."}

      Enum.all?(requested, &(&1 in launched)) ->
        :allowed

      true ->
        foreign = Enum.reject(requested, &(&1 in launched))

        {:refused, :no_ownership_proof,
         "PID(s) #{Enum.join(foreign, ", ")} were not launched by this factory. " <>
           "Only what was launched may be killed."}
    end
  end

  defp kills_process?(command) do
    String.contains?(command, ["taskkill", "kill ", "kill-", "stop-process", "pkill", "killall"])
  end

  # Killing by NAME is the dangerous case: `taskkill /IM beam.exe` does not ask whose process
  # it is, and the factory runs inside one.
  defp reaches_runtime_by_name?(command) do
    names_runtime? = Enum.any?(@runtime_processes, &name_present?(command, &1))
    by_name? = String.contains?(command, ["/im", "-name", "pkill", "killall"])

    names_runtime? and by_name?
  end

  # Whole word: `beam` must not match inside `beamer.exe`, nor `erl` inside `superlative`.
  defp name_present?(command, name) do
    Regex.match?(~r/(?<![a-z0-9_.-])#{Regex.escape(name)}(?![a-z0-9_-])/, command)
  end

  defp kills_everything?(command) do
    String.contains?(command, [
      "taskkill /f /im *",
      "kill -9 -1",
      "kill -9 1",
      "killall -9",
      "stop-process -name *",
      "get-process | stop-process"
    ])
  end

  defp pids_in_command(command) do
    ~r/(?:\/pid\s+|-p\s+|--pid\s+|\bkill\s+(?:-\w+\s+)?)(\d+)/
    |> Regex.scan(command)
    |> Enum.map(fn [_, digits] -> String.to_integer(digits) end)
    |> Enum.uniq()
  end

  @typedoc "The tooling guard warning. It never refuses."
  @type warning :: %{tool: String.t(), use: String.t(), text: String.t()}

  # What the factory ALREADY HAS: what the command suggests the agent is about to reinvent,
  # and what it should use instead.
  @catalog [
    %{
      hints: ["curl ", "wget ", "invoke-webrequest"],
      tool: "a hand-made HTTP client",
      # The HTTP library name is deliberately not written here: a milestone test scans `lib/`
      # for HTTP client names as whole words, code and text alike.
      use: "the provider adapter (Factory.Provider)",
      reason: "downloading from the command line escapes cost accounting and the timeout"
    },
    %{
      hints: ["mix format --check", "mix credo", "mix dialyzer", "mix test"],
      tool: "a loose battery stage",
      use: "mix factory.ci, or the command declared in _management/ci.json",
      reason:
        "ci.json is the SOURCE of the verification command; writing it from memory is costly"
    },
    %{
      hints: ["taskkill", "pkill", "kill "],
      tool: "killing processes by hand",
      use: "Factory.Tools.ProcessTree.kill/1",
      reason: "killing only the launched process leaves its children orphaned"
    },
    %{
      hints: ["git add", "git commit"],
      tool: "a hand-made commit",
      use:
        "the task publishing step, which generates the markdown from the database and commits it",
      reason: "a commit outside the flow leaves the generated markdown and the database diverging"
    }
  ]

  @doc """
  Judges whether the command reinvents something the factory already has.

  It WARNS and never refuses: the command runs, and the warning is attached to the tool
  result for the agent to read on the next turn.
  """
  @spec check_tooling(String.t()) :: [warning()]
  def check_tooling(command) when is_binary(command) do
    normalized = String.downcase(command)

    @catalog
    |> Enum.filter(fn entry ->
      Enum.any?(entry.hints, &String.contains?(normalized, &1))
    end)
    |> Enum.map(fn entry ->
      %{
        tool: entry.tool,
        use: entry.use,
        text:
          "WARNING: this command seems to reinvent #{entry.tool}. " <>
            "Use #{entry.use} — #{entry.reason}. The command RAN anyway."
      }
    end)
  end

  @doc "The catalog of tools the factory already has."
  @spec catalog() :: [map()]
  def catalog, do: @catalog
end
