# Probe of the GOVERNANCE surface of the real `claude --print`, measured rather than deduced
# from the documentation. The flag spellings and event shapes used by `Provider.ClaudeCLI`
# come from here.
#
#     mix run priv/probes/cli_governance.exs
#     mix run priv/probes/cli_governance.exs --rerecord-sample   # rewrites the test fixture
#
# CONSUMES SUBSCRIPTION QUOTA (several short `haiku` calls). No invoice.
#
# Seven sections, each printing the EXACT command and the OBSERVED output. Every flag spelling
# comes from the installed version's `--help` (section 1). Rule of this file: no conclusion
# printed here may be a constant string. If the text says "X answers Y", the call that
# produced Y runs in this same pass, controls included, so the probe stays valid when rerun
# against future CLI versions.

alias Factory.Provider.ClaudeCLI
alias Factory.Tools.Command

defmodule ProbeCLIGovernance do
  @doc "Section separator."
  def section(number, title) do
    IO.puts("\n" <> String.duplicate("=", 78))
    IO.puts("SECTION #{number}: #{title}")
    IO.puts(String.duplicate("=", 78))
  end

  def subsection(title), do: IO.puts("\n--- #{title} ---")

  @doc "Turns double quotes into single quotes, so the prompt fits a quoted argument."
  def escape(text), do: String.replace(text, "\"", "'")

  @doc "Builds a command line in the provider's style, with extra flags injected."
  def line(flags, prompt, model \\ "haiku") do
    flags_txt = if flags == "", do: "", else: "#{flags} "

    ~s(#{ClaudeCLI.executable()} --print --verbose --output-format stream-json ) <>
      ~s(#{flags_txt}--model #{model} "#{escape(prompt)}")
  end

  @doc "Decodes stdout into JSON events, one per line (same as the provider's private parser)."
  def events(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = event} -> [event]
        _ -> []
      end
    end)
  end

  def tool_use_names(events) do
    events
    |> Enum.filter(&(&1["type"] == "assistant"))
    |> Enum.flat_map(fn ev -> get_in(ev, ["message", "content"]) || [] end)
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(& &1["name"])
  end

  def final_result(events), do: Enum.find(events, &(&1["type"] == "result"))

  def final_text(events) do
    case final_result(events) do
      %{"result" => text} -> text
      _ -> nil
    end
  end

  def tool_results_with_error(events) do
    events
    |> Enum.filter(&(&1["type"] == "user"))
    |> Enum.flat_map(fn ev -> get_in(ev, ["message", "content"]) || [] end)
    |> Enum.filter(&(&1["type"] == "tool_result" and &1["is_error"] == true))
  end

  @doc """
  Base directory for fake projects, in LONG form.

  On Windows `System.tmp_dir!/0` may return an 8.3 short path, which changes the CLI's denial
  reason from the normal permission prompt to a "suspicious Windows path pattern" check that
  no permission mode overrides. Real project roots come from configuration in long form.
  """
  def temp_base do
    case System.get_env("USERPROFILE") do
      path when is_binary(path) and path != "" ->
        Path.join([path, "AppData", "Local", "Temp"])

      _ ->
        System.tmp_dir!()
    end
  end

  @doc "Creates a fake project in a temp directory (LONG form) with the given files."
  def fake_project(prefix, files \\ %{"README.md" => "# fake project\n"}) do
    mark = System.unique_integer([:positive])
    root = Path.join(temp_base(), "#{prefix}-#{mark}")
    File.mkdir_p!(root)
    Enum.each(files, fn {name, content} -> File.write!(Path.join(root, name), content) end)
    {root, mark}
  end

  def remove(root), do: File.rm_rf(root)
end

alias ProbeCLIGovernance, as: P

# ============================================================================
P.section(1, "Version and flags, read from the installed version's --help")
# ============================================================================

# `System.cmd/2` cannot run npm's `.cmd` on Windows (`:eacces`); `Command.run_split_streams/3`
# goes through the shell.
root1 = File.cwd!()

{:ok, r_version} =
  Command.run_split_streams(root1, "#{ClaudeCLI.executable()} --version", timeout: 15_000)

version = r_version.stdout
IO.puts("command: #{ClaudeCLI.executable()} --version")
IO.puts("output ......... #{String.trim(version)}")

{:ok, r_help} =
  Command.run_split_streams(root1, "#{ClaudeCLI.executable()} --help", timeout: 15_000)

help = r_help.stdout
IO.puts("\ncommand: #{ClaudeCLI.executable()} --help")

extract = fn text, marker, size ->
  case :binary.match(text, marker) do
    {start, _} -> binary_part(text, start, min(size, byte_size(text) - start))
    :nomatch -> "(NOT FOUND IN --help)"
  end
end

P.subsection("permission mode")
IO.puts(extract.(help, "--permission-mode", 260))

P.subsection("tools: the `--allowedTools` flag (what it DOES is measured in section 3)")
IO.puts(extract.(help, "--allowedTools", 180))

P.subsection("tools: the `--disallowedTools` flag (what it DOES is measured in section 3)")
IO.puts(extract.(help, "--disallowedTools", 180))

P.subsection("tools: the `--tools` flag (what it DOES is measured in section 3)")
IO.puts(extract.(help, "--tools <tools", 260))

P.subsection("additional working directory")
IO.puts(extract.(help, "--add-dir", 130))

P.subsection("turn cap: searched in --help")
has_turns? = String.contains?(help, "max-turns") or String.contains?(help, "maxTurns")
IO.puts("appears in --help? #{has_turns?}")

if not has_turns? do
  IO.puts(
    "ABSENT from the --help of version #{String.trim(version)}. Neither `--max-turns` nor " <>
      "`--maxTurns` is documented. Section 5 measures, IN THIS RUN, whether the binary still " <>
      "recognises the flag (negative control with an invented flag) and what it does, and " <>
      "prints the verdict there."
  )
end

P.subsection("MCP configuration")
IO.puts(extract.(help, "--mcp-config", 160))

P.subsection("session resume")
IO.puts(extract.(help, "-r, --resume", 160))
IO.puts(extract.(help, "-c, --continue", 120))

# ============================================================================
P.section(2, "Headless file write: denial without a flag, and the least mode that passes")
# ============================================================================

{root2, mark2} = P.fake_project("factory-cli-governance-s2")
IO.puts("fake project root: #{root2}")

ask_write = fn file_name, secret ->
  "Create now a file named #{file_name} in this directory with the exact text #{secret}, " <>
    "nothing else. Then reply only with the word done."
end

P.subsection("WITHOUT any permission flag: reproduces the denial")
base_secret = "SECRET-#{mark2}-base"
base_command = P.line("", ask_write.("no_flag.txt", base_secret))
IO.puts("command: #{base_command}")
{:ok, base_result} = Command.run_split_streams(root2, base_command, timeout: 60_000)
base_events = P.events(base_result.stdout)
base_created? = File.exists?(Path.join(root2, "no_flag.txt"))
IO.puts("file created? #{base_created?}")

base_errors = P.tool_results_with_error(base_events)

Enum.each(base_errors, fn error ->
  IO.puts("tool_result is_error=true: #{inspect(error["content"])}")
end)

P.subsection(
  "--permission-mode candidates (from --help: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan)"
)

candidates = ~w(acceptEdits auto bypassPermissions manual dontAsk plan)

# IDENTICAL request for all six modes: putting the mode name in the file name or secret made
# the model refuse in text, so the CLI permission layer was never reached. Each mode runs in
# its own root so the file name can be identical.
neutral_name = "nota.txt"
neutral_secret = "SECRET-#{mark2}"

mode_results =
  Enum.map(candidates, fn mode ->
    {mode_root, _} = P.fake_project("factory-cli-governance-s2-mode")
    command = P.line("--permission-mode #{mode}", ask_write.(neutral_name, neutral_secret))
    IO.puts("\ncommand: #{command}")
    IO.puts("  root: #{mode_root}")
    {:ok, result} = Command.run_split_streams(mode_root, command, timeout: 60_000)
    path = Path.join(mode_root, neutral_name)
    passed? = File.exists?(path) and String.contains?(File.read!(path), neutral_secret)

    mode_events = P.events(result.stdout)

    reason =
      if passed? do
        "wrote"
      else
        case P.tool_results_with_error(mode_events) do
          [error | _] ->
            to_string(error["content"]) |> String.slice(0, 90)

          [] ->
            # No error tool_result: the model may have refused in text without trying a tool.
            "(no error tool_result; tool_use attempted=#{inspect(P.tool_use_names(mode_events))}; final text=#{inspect(P.final_text(mode_events)) |> String.slice(0, 90)})"
        end
      end

    IO.puts("  mode=#{String.pad_trailing(mode, 18)} wrote=#{passed?}  #{reason}")
    P.remove(mode_root)
    {mode, passed?}
  end)

passing_modes =
  mode_results
  |> Enum.filter(fn {_mode, passed?} -> passed? end)
  |> Enum.map(fn {mode, _} -> mode end)

IO.puts("\nModes that PASS: #{inspect(passing_modes)}")

IO.puts(
  "Modes that still deny: #{inspect(Enum.reject(mode_results, &elem(&1, 1)) |> Enum.map(&elem(&1, 0)))}"
)

P.remove(root2)

# ============================================================================
P.section(3, "Vocabulary restriction: what each of the three flags REALLY does")
# ============================================================================

{root3, mark3} = P.fake_project("factory-cli-governance-s3")
IO.puts("fake project root: #{root3}")

P.subsection("--allowedTools \"Read Glob Grep\" (WITHOUT an auto-approving permission mode)")
secret3a = "SECRET-#{mark3}-allowedtools"
command3a = P.line("--allowedTools \"Read Glob Grep\"", ask_write.("a.txt", secret3a))
IO.puts("command: #{command3a}")
{:ok, r3a} = Command.run_split_streams(root3, command3a, timeout: 60_000)
ev3a = P.events(r3a.stdout)

write_in_vocab_3a? =
  "Write" in (Enum.find(ev3a, &(&1["type"] == "system" and &1["subtype"] == "init"))["tools"] ||
                [])

created_3a? = File.exists?(Path.join(root3, "a.txt"))
IO.puts("tools announced in the system/init event include Write? #{write_in_vocab_3a?}")
IO.puts("file created? #{created_3a?}")

IO.puts(
  "=> did `--allowedTools` leave Write in the vocabulary? #{write_in_vocab_3a?}; wrote? #{created_3a?} " <>
    "so it is an APPROVAL allowlist, not a vocabulary one."
)

case P.tool_results_with_error(ev3a) do
  [error | _] -> IO.puts("tool_result: #{inspect(error["content"])}")
  [] -> :ok
end

# The deny-list runs ON TOP of `acceptEdits` on purpose: section 2 measured that `acceptEdits`
# alone WRITES, so any difference here comes from the deny-list. That separates "removes Write
# from the vocabulary" (`No such tool available`) from "only denies auto-approval" (the usual
# permission message, with Write still announced in `system/init`).
P.subsection(
  "--permission-mode acceptEdits --disallowedTools \"Write\" (deny-list over a mode that already auto-approves)"
)

secret3c = "SECRET-#{mark3}-disallowedtools"

command3c =
  P.line(
    "--permission-mode acceptEdits --disallowedTools \"Write\"",
    ask_write.("c.txt", secret3c)
  )

IO.puts("command: #{command3c}")
{:ok, r3c} = Command.run_split_streams(root3, command3c, timeout: 60_000)
ev3c = P.events(r3c.stdout)

announced_tools_3c =
  Enum.find(ev3c, &(&1["type"] == "system" and &1["subtype"] == "init"))["tools"] || []

write_in_vocab_3c? = "Write" in announced_tools_3c
created_3c? = File.exists?(Path.join(root3, "c.txt"))
used_3c = P.tool_use_names(ev3c)
IO.puts("tools announced in system/init include Write? #{write_in_vocab_3c?}")
IO.puts("file created? #{created_3c?}")
IO.puts("tool_use attempted: #{inspect(used_3c)}")

case P.tool_results_with_error(ev3c) do
  [error | _] -> IO.puts("tool_result: #{inspect(error["content"])}")
  [] -> IO.puts("model's final text: #{inspect(P.final_text(ev3c))}")
end

IO.puts(
  "=> did `--disallowedTools \"Write\"` remove Write from the announced vocabulary? #{not write_in_vocab_3c?}. " <>
    "BUT was the file written anyway? #{created_3c?}, via #{inspect(used_3c)}. " <>
    if created_3c? do
      "A deny-list of ONE tool does not prevent the RESULT: the model switches tools " <>
        "(substitution). Only the `--tools` allowlist closes the exits; see the next block."
    else
      "In this run the result was blocked too."
    end
)

P.subsection("--tools \"Read,Glob,Grep\" (REAL vocabulary restriction)")
secret3b = "SECRET-#{mark3}-tools"
command3b = P.line("--tools \"Read,Glob,Grep\"", ask_write.("b.txt", secret3b))
IO.puts("command: #{command3b}")
{:ok, r3b} = Command.run_split_streams(root3, command3b, timeout: 60_000)
ev3b = P.events(r3b.stdout)

announced_tools =
  Enum.find(ev3b, &(&1["type"] == "system" and &1["subtype"] == "init"))["tools"] || []

IO.puts("tools announced in the system/init event: #{inspect(announced_tools)}")
IO.puts("file created? #{File.exists?(Path.join(root3, "b.txt"))}")
IO.puts("tool_use attempted: #{inspect(P.tool_use_names(ev3b))}")

case P.tool_results_with_error(ev3b) do
  [error | _] -> IO.puts("how the stream shows the refusal: #{inspect(error["content"])}")
  [] -> IO.puts("model's final text: #{inspect(P.final_text(ev3b))}")
end

P.remove(root3)

# ============================================================================
P.section(4, "Confinement: absolute path and traversal, outside the project root")
# ============================================================================

{root4, mark4} = P.fake_project("factory-cli-governance-s4")

IO.puts(
  "fake project root: #{root4} (NO ancestor CLAUDE.md/AGENTS.md, so the model does not restrict itself by prompt instruction instead of CLI mechanism)"
)

# POSITIVE CONTROL, in the SAME root and run as the two denials below. The denial message
# outside the root is identical to the no-flag denial, so without this control "the CLI
# confines the root" and "acceptEdits had no effect" would be indistinguishable.
P.subsection("POSITIVE control: write INSIDE the root, same flag, same run")
secret4_inside = "SECRET-#{mark4}-inside"

command4_inside =
  P.line("--permission-mode acceptEdits", ask_write.("inside.txt", secret4_inside))

IO.puts("command (inside the root): #{command4_inside}")
{:ok, r4c} = Command.run_split_streams(root4, command4_inside, timeout: 60_000)
path4_inside = Path.join(root4, "inside.txt")

wrote_inside? =
  File.exists?(path4_inside) and String.contains?(File.read!(path4_inside), secret4_inside)

IO.puts("File.exists?(#{path4_inside}) with the secret inside = #{wrote_inside?}")

if not wrote_inside? do
  case P.tool_results_with_error(P.events(r4c.stdout)) do
    [error | _] -> IO.puts("tool_result: #{inspect(error["content"])}")
    [] -> IO.puts("final text: #{inspect(P.final_text(P.events(r4c.stdout)))}")
  end
end

absolute_target = Path.join(P.temp_base(), "outside-abs-#{mark4}.txt")
secret4a = "SECRET-#{mark4}-abs"

command4a =
  P.line(
    "--permission-mode acceptEdits",
    "Create a file at the absolute path #{absolute_target} with the text #{secret4a}, nothing else. " <>
      "Then reply only with the word done."
  )

IO.puts("\ncommand (absolute path): #{command4a}")
{:ok, r4a} = Command.run_split_streams(root4, command4a, timeout: 60_000)
abs_exists? = File.exists?(absolute_target)
IO.puts("File.exists?(#{absolute_target}) = #{abs_exists?}")

case P.tool_results_with_error(P.events(r4a.stdout)) do
  [error | _] -> IO.puts("tool_result: #{inspect(error["content"])}")
  [] -> IO.puts("final text: #{inspect(P.final_text(P.events(r4a.stdout)))}")
end

if abs_exists?, do: File.rm(absolute_target)

traversal_name = "..\\outside-trav-#{mark4}.txt"
traversal_real = Path.join(Path.dirname(root4), "outside-trav-#{mark4}.txt")
secret4b = "SECRET-#{mark4}-trav"

command4b =
  P.line(
    "--permission-mode acceptEdits",
    "Create a file at #{traversal_name} (one directory above this one) with the text #{secret4b}, " <>
      "nothing else. Then reply only with the word done."
  )

IO.puts("\ncommand (traversal): #{command4b}")
{:ok, r4b} = Command.run_split_streams(root4, command4b, timeout: 60_000)
trav_exists? = File.exists?(traversal_real)
IO.puts("File.exists?(#{traversal_real}) = #{trav_exists?}")

case P.tool_results_with_error(P.events(r4b.stdout)) do
  [error | _] -> IO.puts("tool_result: #{inspect(error["content"])}")
  [] -> IO.puts("final text: #{inspect(P.final_text(P.events(r4b.stdout)))}")
end

if trav_exists?, do: File.rm(traversal_real)

verdict4 =
  cond do
    not wrote_inside? ->
      "INCONCLUSIVE: the positive control did not write even INSIDE the root in this run. The " <>
        "two denials above do not prove confinement; they only show nothing was written."

    abs_exists? or trav_exists? ->
      "REFUTED: one of the OUTSIDE paths was created (absolute=#{abs_exists?}, " <>
        "traversal=#{trav_exists?}): the CLI did not confine the root in this run."

    true ->
      "CONFIRMED: with the SAME flag in the SAME run, writing INSIDE the root passed and both " <>
        "OUTSIDE writes (absolute and traversal) were denied. The only variable is the file's " <>
        "LOCATION, so the CLI confines on its own, in addition to `Factory.Tools.Confinement`."
  end

IO.puts("\nsection 4 verdict: #{verdict4}")
P.remove(root4)

# ============================================================================
P.section(5, "Turn cap: does the flag exist? negative and positive controls, both measured")
# ============================================================================

{root5, _mark5} =
  P.fake_project("factory-cli-governance-s5", %{
    "a.txt" => "content of a\n",
    "b.txt" => "content of b\n",
    "c.txt" => "content of c\n"
  })

IO.puts("fake project root: #{root5}")

# NEGATIVE CONTROL, measured: a binary that silently ignored unknown flags would otherwise
# look as if it accepted `--max-turns`. The invented flag is rejected before any model call,
# so it costs no quota.
P.subsection("measured NEGATIVE control: does this binary REJECT an unknown flag?")
invented_flag = "--totally-invented-xyz"
invented_command = P.line(invented_flag, "reply only ok")
IO.puts("command: #{invented_command}")
{:ok, r_invented} = Command.run_split_streams(root5, invented_command, timeout: 30_000)
invented_stderr = String.trim(r_invented.stderr)
IO.puts("code ......... #{inspect(r_invented.code)}")
IO.puts("stderr ....... #{inspect(String.slice(invented_stderr, 0, 200))}")
IO.puts("stdout ....... #{inspect(String.slice(String.trim(r_invented.stdout), 0, 200))}")
rejects_unknown? = String.contains?(invented_stderr, "unknown option")

IO.puts(
  "rejects `#{invented_flag}` with `unknown option`? #{rejects_unknown?} " <>
    "(if false, the control is worthless and the verdict below says INCONCLUSIVE)"
)

IO.puts(
  "\nnegative evidence (section 1): \"max-turns\"/\"maxTurns\" absent from this version's " <>
    "--help text."
)

multi_turn_task =
  "List the files in this directory, then read the content of a.txt, then read the " <>
    "content of b.txt, then read the content of c.txt, then create a file summary.txt " <>
    "with a summary of everything you read. Only then reply 'done'."

command5 = P.line("--permission-mode acceptEdits --max-turns 2", multi_turn_task)
IO.puts("\ncommand: #{command5}")
{:ok, r5} = Command.run_split_streams(root5, command5, timeout: 90_000)
ev5 = P.events(r5.stdout)
result5 = P.final_result(ev5)

# The other side of the control: THIS call's stderr, compared with the invented flag's.
stderr5 = String.trim(r5.stderr)
IO.puts("stderr of the call with --max-turns: #{inspect(String.slice(stderr5, 0, 200))}")
max_turns_rejected? = String.contains?(stderr5, "unknown option")
IO.puts("was `--max-turns` rejected as `unknown option`? #{max_turns_rejected?}")

IO.puts("num_turns ......... #{inspect(result5["num_turns"])}")
IO.puts("is_error .......... #{inspect(result5["is_error"])}")
IO.puts("subtype ........... #{inspect(result5["subtype"])}")
IO.puts("terminal_reason ... #{inspect(result5["terminal_reason"])}")
IO.puts("errors ............ #{inspect(result5["errors"])}")

verdict5 =
  cond do
    not rejects_unknown? ->
      "INCONCLUSIVE: the negative control failed; this binary did NOT answer `unknown option` " <>
        "to `#{invented_flag}`. Without it, silently accepting `--max-turns` does not prove " <>
        "the flag exists; this CLI may ignore every flag it does not know."

    max_turns_rejected? ->
      "REFUTED: `--max-turns` was rejected as `unknown option` by this binary; the flag no " <>
        "longer exists in this version. Anything relying on it needs another mechanism."

    result5["subtype"] == "error_max_turns" ->
      "CONFIRMED by TWO controls measured in this run: (negative) the invented flag was " <>
        "rejected with `unknown option` and `--max-turns` was NOT, so the binary recognises " <>
        "it; (positive) subtype == \"error_max_turns\"."

    true ->
      "PARTIAL: `--max-turns` is recognised (the negative control measured that), but the " <>
        "subtype came as #{inspect(result5["subtype"])}, not \"error_max_turns\"."
  end

IO.puts("\nverdict: #{verdict5}")
P.remove(root5)

# ============================================================================
P.section(6, "Stream shape of a session that USES a tool and finishes well")
# ============================================================================

{root6, _mark6} =
  P.fake_project("factory-cli-governance-s6", %{
    "nota.txt" => "This is a test note for the governance probe.\n"
  })

IO.puts("fake project root: #{root6}")

task6 =
  "List the files in this directory using a shell tool, then read the content " <>
    "of nota.txt, and then reply with a one-sentence summary of what you read."

command6 = P.line("--permission-mode acceptEdits", task6)
IO.puts("command: #{command6}")
{:ok, r6} = Command.run_split_streams(root6, command6, timeout: 90_000)

# This run's stdout always goes to `_scratch/` (git-ignored). The VERSIONED sample in
# `samples/`, used as a test fixture, is only (re)written when missing or on explicit request,
# so rerunning the probe never changes another test's fixed input.
samples_dir = Path.join(__DIR__, "samples")
File.mkdir_p!(samples_dir)
sample_path = Path.join(samples_dir, "session-with-tool.jsonl")

scratch_dir = Path.join(__DIR__, "_scratch")
File.mkdir_p!(scratch_dir)
run_path = Path.join(scratch_dir, "session-with-tool-#{System.os_time(:second)}.jsonl")
File.write!(run_path, r6.stdout)

IO.puts("raw stdout of THIS run: #{run_path} (#{byte_size(r6.stdout)} bytes, transient)")

rerecord? =
  "--rerecord-sample" in System.argv() or System.get_env("RERECORD_SAMPLE") not in [nil, ""]

cond do
  not File.exists?(sample_path) or rerecord? ->
    File.write!(sample_path, r6.stdout)

    IO.puts("raw stdout saved to: #{sample_path} (#{byte_size(r6.stdout)} bytes, WRITTEN now)")

  true ->
    IO.puts(
      "raw stdout saved to: #{sample_path} " <>
        "(#{File.stat!(sample_path).size} bytes, versioned sample KEPT; " <>
        "to rewrite: `mix run priv/probes/cli_governance.exs --rerecord-sample`)"
    )
end

ev6 = P.events(r6.stdout)
type_sequence = Enum.map(ev6, & &1["type"])
IO.puts("\ntype sequence, in order: #{inspect(type_sequence)}")

with_usage =
  ev6
  |> Enum.filter(&Map.has_key?(&1, "usage"))
  |> Enum.map(& &1["type"])
  |> Enum.frequencies()

IO.puts("`usage` appears in events of type (count): #{inspect(with_usage)}")

usage_per_assistant =
  ev6
  |> Enum.filter(&(&1["type"] == "assistant"))
  |> Enum.map(&get_in(&1, ["message", "usage"]))
  |> Enum.map(&(&1 != nil))

IO.puts("does each assistant event have usage? #{inspect(usage_per_assistant)}")

IO.puts(
  "does the `result` also have aggregated usage? #{Map.has_key?(P.final_result(ev6) || %{}, "usage")}"
)

P.subsection("telling an ALREADY RESOLVED tool_use (mid-session) from a PENDING one (last turn)")

tool_uses =
  ev6
  |> Enum.filter(&(&1["type"] == "assistant"))
  |> Enum.flat_map(fn ev -> get_in(ev, ["message", "content"]) || [] end)
  |> Enum.filter(&(&1["type"] == "tool_use"))
  |> Enum.map(&{&1["id"], &1["name"]})

resolved_ids =
  ev6
  |> Enum.filter(&(&1["type"] == "user"))
  |> Enum.flat_map(fn ev -> get_in(ev, ["message", "content"]) || [] end)
  |> Enum.filter(&(&1["type"] == "tool_result"))
  |> Enum.map(& &1["tool_use_id"])
  |> MapSet.new()

Enum.each(tool_uses, fn {id, name} ->
  resolved? = MapSet.member?(resolved_ids, id)

  IO.puts(
    "  tool_use #{name} (id=#{String.slice(id, 0, 12)}...) resolved in the stream? #{resolved?}"
  )
end)

pending = Enum.reject(tool_uses, fn {id, _} -> MapSet.member?(resolved_ids, id) end)

IO.puts(
  "\n#{length(tool_uses)} tool_use in total, #{length(pending)} WITHOUT a tool_result matching " <>
    "by tool_use_id in the stream. The distinction is: match the tool_use `id` with the " <>
    "`tool_use_id` of a LATER tool_result in the same stream. A tool_use without a pair is " <>
    "the \"last turn, still pending\" candidate, but `claude --print` resolves tool use " <>
    "entirely on its own before emitting `result`: in a session that finishes well, " <>
    "normally NONE is pending. So the stop reason must come from the terminal event, never " <>
    "from every block in the stream."
)

final_text6 = P.final_text(ev6)
IO.puts("\nmodel's final text: #{inspect(final_text6)}")
P.remove(root6)

# ============================================================================
P.section(7, "Prompt through stdin: it works, and survives what breaks a command-line argument")
# ============================================================================

{root7, mark7} = P.fake_project("factory-cli-governance-s7")
IO.puts("fake project root: #{root7}")

hard_prompt =
  "Reply with the following three lines, exactly:\n" <>
    "line \"with double quotes\" mark #{mark7}\n" <>
    "line with & ampersand\n"

prompt_file = Path.join(root7, "prompt.txt")
File.write!(prompt_file, hard_prompt)

P.subsection("path A: the same prompt EMBEDDED as a command-line argument")

command7_arg = P.line("", hard_prompt)
IO.puts("command (generates the .bat with the embedded prompt, newline included): #{inspect(command7_arg)}")
{:ok, r7_arg} = Command.run_split_streams(root7, command7_arg, timeout: 20_000)
IO.puts("code ........ #{inspect(r7_arg.code)}")
IO.puts("reason ...... #{inspect(r7_arg.reason)}")
IO.puts("stdout bytes  #{byte_size(r7_arg.stdout)}")
IO.puts("stderr bytes  #{byte_size(r7_arg.stderr)}")

P.subsection("path B: the SAME prompt through stdin redirected from a file (not an argument)")

command7_stdin =
  "#{ClaudeCLI.executable()} --print --verbose --output-format stream-json --model haiku"

# `type` is a cmd.exe builtin and needs "\" separators; `Path.join/2` always returns "/".
# `System.cmd("cmd", ["/c", ...])` breaks on Erlang's argument requoting, so this goes through
# `Command.run_split_streams/3`, which writes a `.bat` instead.
prompt_file_win = String.replace(prompt_file, "/", "\\")
cmd_line = "type \"#{prompt_file_win}\" | #{command7_stdin}"
IO.puts("command: #{cmd_line}")
{:ok, r7_stdin} = Command.run_split_streams(root7, cmd_line, timeout: 30_000)
IO.puts("code ........ #{inspect(r7_stdin.code)}")
IO.puts("reason ...... #{inspect(r7_stdin.reason)}")
IO.puts("stdout bytes  #{byte_size(r7_stdin.stdout)}")
IO.puts("stderr bytes  #{byte_size(r7_stdin.stderr)}")

if r7_stdin.stderr != "" do
  IO.puts("stderr (diagnostic): #{inspect(String.slice(r7_stdin.stderr, 0, 300))}")
end

ev7 = P.events(r7_stdin.stdout)
text7 = P.final_text(ev7)
IO.puts("final text .. #{inspect(text7)}")

arg_broke? = r7_arg.code not in [0] or r7_arg.stdout == ""
stdin_worked? = r7_stdin.code == 0 and text7 != nil

IO.puts(
  "\nverdict: the command-line argument #{if arg_broke?, do: "BROKE", else: "did not break this time"} " <>
    "(code=#{inspect(r7_arg.code)}, reason=#{r7_arg.reason}); redirected stdin " <>
    "#{if stdin_worked?, do: "WORKED", else: "failed too"} " <>
    "(code=#{inspect(r7_stdin.code)})."
)

P.remove(root7)

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))
IO.puts("PROBE FINISHED: seven sections printed above.")
IO.puts(String.duplicate("=", 78))
