# Milestone E3 probe: an agent solves a real task through `Agents.Loop` against the REAL
# `claude` (`Provider.ClaudeCLI`), and the result is persisted by `Tasks.Transition.apply/3`.
#
#     mix run priv/probes/milestone_e3_agent.exs
#
# CONSUMES SUBSCRIPTION QUOTA. No invoice.
#
# The agent starts with `vocabulary: ["write"]` instead of the builder role, which would bring
# `run` -> Bash -> the CLI sandbox. The task only writes a file (audited by confinement), so
# it must not depend on the sandbox being available on this machine.
#
# Three independent claims, each with its own evidence:
#   1. the agent REALLY solved the task (the file changed on disk as requested);
#   2. there is exactly ONE row in `usages`, in the DATABASE, PER loop turn;
#   3. the SUM of tokens in the stored rows matches the sum accumulated in the loop STATE.
#
# Under `:full_agent`, one loop turn is a whole CLI session with as many internal turns as the
# model needed; the report prints loop turns next to the session's tool calls so the
# difference is visible.

alias Factory.Agents.Loop
alias Factory.Projects.Project
alias Factory.Provider.ClaudeCLI
alias Factory.Repo
alias Factory.Tasks.Task
alias Factory.Tasks.Transition
alias Factory.Tools.Command

Application.put_env(:factory, :provider, ClaudeCLI)

# Do NOT use `System.tmp_dir!()` here: on Windows it may return the 8.3 short path, which the
# CLI refuses ("suspicious Windows path pattern") even with `acceptEdits`. The user home gives
# the long form.
root =
  Path.join([
    System.user_home!(),
    "AppData",
    "Local",
    "Temp",
    "milestone-e3-#{System.unique_integer([:positive])}"
  ])

File.mkdir_p!(root)

# The fake project: 3 files.
File.write!(Path.join(root, "README.md"), "# fake project for milestone E3\n")
File.write!(Path.join(root, "a.txt"), "one\n")
File.write!(Path.join(root, "b.txt"), "two\n")

secret = "MILESTONE-E3-#{System.unique_integer([:positive])}"
target = Path.join(root, "result.txt")

# A real, MULTI-LINE task prompt with double quotes and an `&`: it exercises the prompt
# travelling through stdin instead of the command line.
prompt = """
This is a real "cleanup" task in a fake project: do not touch "README.md" nor the
"a.txt" & "b.txt" that already exist here; they are only context and need not be read.

What you need to do, in a single step: create a file named "result.txt" in this
folder, containing only this line, exactly:

#{secret}

Then reply only with the word "done".
"""

measure_quota = fn label ->
  line =
    ~s(#{ClaudeCLI.executable()} --print --verbose --output-format stream-json --model haiku "reply only: ping")

  case Command.run_split_streams(root, line, timeout: 60_000) do
    {:ok, %{stdout: stdout}} ->
      windows = ClaudeCLI.quota_windows(stdout)
      IO.puts("  quota windows (#{label}): #{inspect(windows)}")
      windows

    other ->
      IO.puts("  could not measure quota (#{label}): #{inspect(other)}")
      nil
  end
end

IO.puts("=== fake project root: #{root} ===")
IO.puts("=== quota window BEFORE ===")
measure_quota.("before")

IO.puts("\n=== calling the real claude through the Loop (consumes quota) ===\n")

{:ok, summary} =
  Loop.run(
    root: root,
    model: "haiku",
    vocabulary: ["write"],
    max_turns: 10,
    messages: [%{role: :user, content: prompt}],
    tools: %{}
  )

IO.puts("outcome ....... #{inspect(summary.outcome)}")
IO.puts("spent_usd ..... #{summary.spent_usd}")
IO.puts("usages ........ #{length(summary.usages)} row(s) in the loop STATE")

IO.puts("\n=== LOOP turns x internal turns of the CLI SESSION (do not confuse them) ===")

IO.puts("  Agents.Loop turns .................... #{summary.turns}")

IO.puts(
  "  session tool_calls: #{summary.tool_calls} " <>
    "(:tool_use blocks of the whole CLI SESSION; under :full_agent the loop does " <>
    "1 turn = 1 session, and this number shows how many internal turns it had; " <>
    "\"one usage row per turn\" is not \"one row per internal turn\")"
)

Enum.each(Enum.with_index(summary.usages, 1), fn {usage, index} ->
  IO.puts(
    "  turn #{index}: input=#{usage.input_tokens} " <>
      "cache_read=#{usage.cache_read_tokens} " <>
      "cache_write=#{usage.cache_write_tokens} output=#{usage.output_tokens}"
  )
end)

IO.puts("\n=== quota window AFTER ===")
measure_quota.("after")

# CLAIM 1: the task was REALLY solved: the file changed on disk as requested.
file_content =
  case File.read(target) do
    {:ok, text} -> String.trim(text)
    {:error, reason} -> {:error, reason}
  end

claim_1 =
  case file_content do
    text when is_binary(text) -> String.contains?(text, secret)
    _ -> false
  end

IO.puts("\n=== CLAIM 1: the task was really solved (file on disk) ===")
IO.puts("  expected file ...... #{target}")
IO.puts("  content read ....... #{inspect(file_content)}")
IO.puts("  expected secret .... #{secret}")
IO.puts("  [#{if claim_1, do: "ok", else: "FAILED"}] the file contains the secret")

# Explicit Loop -> Transition link: persists dispatch + usages as the engine would.
{:ok, project} =
  %Project{}
  |> Project.changeset(%{
    name: "milestone-e3-probe-#{System.unique_integer([:positive])}",
    path: root
  })
  |> Repo.insert()

{:ok, task} =
  %Task{}
  |> Task.changeset(%{
    project_id: project.id,
    code: "T-999",
    title: "write result.txt with the secret (milestone E3 probe)",
    status: :backlog
  })
  |> Repo.insert()

{:ok, task} = Transition.apply(task, :ready)
{:ok, task} = Transition.apply(task, :in_progress)

usages_to_store =
  Enum.map(summary.usages, fn usage ->
    %{
      input_tokens: usage.input_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      output_tokens: usage.output_tokens,
      duration_ms: usage.duration_ms
    }
  end)

persistence_result =
  Transition.apply(task, :in_testing,
    role: "builder",
    outcome: to_string(summary.outcome),
    report: "milestone E3 probe: #{summary.turns} turn(s)",
    dispatch: %{provider: "ClaudeCLI", model: "haiku", turns: summary.turns},
    usages: usages_to_store
  )

case persistence_result do
  {:ok, final_task} ->
    task_with_data =
      Factory.Tasks.Task
      |> Repo.get!(final_task.id)
      |> Repo.preload(cycles: [dispatches: :usages])

    [cycle] = task_with_data.cycles
    [dispatch] = cycle.dispatches
    stored_usages = dispatch.usages

    IO.puts("\n=== CLAIM 2: one row in `usages`, in the DATABASE, PER turn ===")
    IO.puts("  loop turns ............. #{summary.turns}")
    IO.puts("  stored rows ............ #{length(stored_usages)}")

    IO.puts(
      "  stored turns (:turn) ... #{inspect(Enum.map(stored_usages, & &1.turn) |> Enum.sort())}"
    )

    claim_2 =
      length(stored_usages) == summary.turns and
        Enum.map(stored_usages, & &1.turn) |> Enum.sort() == Enum.to_list(1..summary.turns)

    IO.puts(
      "  [#{if claim_2, do: "ok", else: "FAILED"}] one row per turn, numbered 1..#{summary.turns}"
    )

    total = fn u ->
      u.input_tokens + u.cache_read_tokens + u.cache_write_tokens + u.output_tokens
    end

    state_sum = summary.usages |> Enum.map(total) |> Enum.sum()
    database_sum = stored_usages |> Enum.map(total) |> Enum.sum()

    IO.puts("\n=== CLAIM 3: the sum of the stored rows matches the loop STATE total ===")

    IO.puts("  token sum in the STATE (summary.usages) ....... #{state_sum}")
    IO.puts("  token sum in the DATABASE (stored usages) ..... #{database_sum}")

    claim_3 = state_sum == database_sum and state_sum > 0

    IO.puts("  [#{if claim_3, do: "ok", else: "FAILED"}] sums match and are greater than zero")

    IO.puts("\n=== SUMMARY ===")
    IO.puts("  [#{if claim_1, do: "ok", else: "FAILED"}] claim 1: task really solved")
    IO.puts("  [#{if claim_2, do: "ok", else: "FAILED"}] claim 2: one row per turn in the database")
    IO.puts("  [#{if claim_3, do: "ok", else: "FAILED"}] claim 3: sum matches the state total")

    if claim_1 and claim_2 and claim_3 do
      IO.puts("\nPROBE OK: milestone E3 confirmed against the real claude")
    else
      IO.puts("\nPROBE FAILED")
      System.halt(1)
    end

  {:error, reason} ->
    IO.puts("\nERROR persisting through Transition.apply/3: #{inspect(reason)}")
    IO.puts("[FAILED] claims 2 and 3 could not be proven: persistence failed")
    System.halt(1)
end
