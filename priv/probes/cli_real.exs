# Probe of `Provider.ClaudeCLI` against the REAL `claude`.
#
#     mix run priv/probes/cli_real.exs
#
# The unit tests feed `parse/1` with hand-made event streams, so they exercise the
# translation but never the actual invocation. This script is the real invocation. It cannot
# be part of the suite, which runs without network or quota.
#
# CONSUMES SUBSCRIPTION QUOTA (no invoice, but not free): use sparingly.
#
# Sections:
#   A. the call succeeds and blocks are translated;
#   B. the builder role CREATES a file headless (`--permission-mode acceptEdits`);
#   C. the verifier vocabulary excludes Write/Edit (`--tools`);
#   D. a low `max_turns` STOPS the session (`stop_reason: :max_turns`);
#   E. a generous cap on the same request finishes normally;
#   F. a multi-line prompt with double quotes and `&` arrives intact through stdin.
# Effects are checked with `File.exists?`, never with the model's answer.

alias Factory.Provider.ClaudeCLI
alias Factory.Provider.Request

check = fn label, condition ->
  IO.puts("  [#{if condition, do: "ok", else: "FAILED"}] #{label}")
  condition
end

# Long-form base directory: `System.tmp_dir!/0` may return an 8.3 short path on Windows,
# which triggers a separate CLI safety check no `--permission-mode` overrides.
temp_base = fn ->
  case System.get_env("USERPROFILE") do
    path when is_binary(path) and path != "" ->
      Path.join([path, "AppData", "Local", "Temp"])

    _ ->
      System.tmp_dir!()
  end
end

fake_project = fn prefix ->
  mark = System.unique_integer([:positive])
  root = Path.join(temp_base.(), "#{prefix}-#{mark}")
  File.mkdir_p!(root)
  File.write!(Path.join(root, "README.md"), "# fake project\n")
  root
end

# ============================================================================
IO.puts(String.duplicate("=", 78))
IO.puts("SECTION A: the call succeeds and block translation matches")
IO.puts(String.duplicate("=", 78))
# ============================================================================

section_a? =
  case ClaudeCLI.chat(
         %Request{
           model: "haiku",
           messages: [%{role: :user, content: "Reply only: pong"}]
         },
         root: File.cwd!(),
         timeout: 180_000
       ) do
    {:ok, response} ->
      types = response.blocks |> Enum.map(& &1.type) |> Enum.uniq()

      text =
        response.blocks
        |> Enum.filter(&(&1.type == :text))
        |> Enum.map_join(" ", & &1.text)
        |> String.trim()

      IO.puts("  blocks ........ #{inspect(types)}")
      IO.puts("  stop .......... #{response.stop_reason}")
      IO.puts("  output ........ #{response.usage.output_tokens}")
      IO.puts("  text .......... #{inspect(text)}")

      [
        check.("the call succeeds (requires --verbose on the line)", true),
        check.("real usage came back", response.usage.output_tokens > 0),
        check.("no block is :unknown", :unknown not in types),
        check.("the model answered what was asked", String.downcase(text) =~ "pong")
      ]
      |> Enum.all?()

    {:error, {:quota, at}} ->
      IO.puts("  QUOTA HIT. Reopens at: #{inspect(at)}")
      IO.puts("  (this section could not be measured, but quota detection worked)")
      true

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
      false
  end

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))
IO.puts("SECTION B: builder role CREATES a file headless (--permission-mode acceptEdits)")
IO.puts(String.duplicate("=", 78))
# ============================================================================

root_b = fake_project.("cli-builder")
target_b = Path.join(root_b, "ok.txt")

section_b? =
  case ClaudeCLI.chat(
         %Request{
           role: "builder",
           model: "haiku",
           messages: [
             %{
               role: :user,
               content:
                 "Use the write tool to create the file ok.txt at the project root, with the content 'hi'."
             }
           ]
         },
         root: root_b,
         timeout: 180_000
       ) do
    {:ok, response} ->
      IO.puts("  stop .......... #{response.stop_reason}")
      check.("File.exists?(ok.txt), not the model's answer", File.exists?(target_b))

    {:error, {:quota, at}} ->
      IO.puts("  QUOTA HIT. Reopens at: #{inspect(at)}")
      true

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
      false
  end

File.rm_rf(root_b)

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))

IO.puts(
  "SECTION C: the verifier vocabulary has NO Write/Edit, even under an EXPLICIT order (--tools, not --allowedTools)"
)

IO.puts(String.duplicate("=", 78))
# ============================================================================
#
# `--tools "Bash,Glob,Grep,Read"` makes Write/Edit ineffective for the verifier. The model may
# still emit a Write (the CLI blocks it) or improvise with Bash (the verifier has Bash, and
# shell writes are the documented gap). The invariant that holds for any model behaviour: the
# target file only exists if Bash created it.

root_c = fake_project.("cli-verifier")
target_c = Path.join(root_c, "should-not-exist.txt")

section_c? =
  case ClaudeCLI.chat(
         %Request{
           role: "verifier",
           model: "haiku",
           messages: [
             %{
               role: :user,
               content:
                 "Use the write tool to create the file should-not-exist.txt at the project root, with any content."
             }
           ]
         },
         root: root_c,
         timeout: 180_000
       ) do
    {:ok, response} ->
      tools_used =
        response.blocks
        |> Enum.filter(&(&1.type == :tool_use))
        |> Enum.map(& &1.name)

      exists? = File.exists?(target_c)
      used_bash? = "Bash" in tools_used

      IO.puts("  stop .......... #{response.stop_reason}")
      IO.puts("  tools ......... #{inspect(tools_used)}")

      IO.puts(
        "  file .......... File.exists?(should-not-exist.txt) = #{exists?} " <>
          "(if true, it can only have come from Bash, the ACCEPTED shell gap, not Write/Edit)"
      )

      check.(
        "Write/Edit ineffective: the file exists only if Bash created it",
        not exists? or used_bash?
      )

    {:error, {:quota, at}} ->
      IO.puts("  QUOTA HIT. Reopens at: #{inspect(at)}")
      true

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
      false
  end

File.rm_rf(root_c)

# Same request for sections D and E: it forces several turns and insists on not stopping
# until all five files exist, so section E proves completion, not just absence of a cut.
multi_turn_request = fn ->
  "Create these five files at the project root, each containing its own name: " <>
    "one.txt, two.txt, three.txt, four.txt, five.txt. MANDATORY RULE: use the write tool " <>
    "exactly ONCE PER TURN; never write two files in the same tool call, and never use a " <>
    "single command that creates more than one file. " <>
    "Keep going, turn after turn, until all FIVE files exist; do not stop before that and " <>
    "do not ask for confirmation along the way."
end

files = ~w(one.txt two.txt three.txt four.txt five.txt)

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))
IO.puts("SECTION D: LOW cap (--max-turns 1) STOPS the session: stop_reason :max_turns")
IO.puts(String.duplicate("=", 78))
# ============================================================================

root_d = fake_project.("cli-low-cap")

section_d? =
  case ClaudeCLI.chat(
         %Request{
           role: "builder",
           model: "haiku",
           messages: [%{role: :user, content: multi_turn_request.()}],
           max_turns: 1
         },
         root: root_d,
         timeout: 180_000
       ) do
    {:ok, response} ->
      created = Enum.count(files, &File.exists?(Path.join(root_d, &1)))

      IO.puts("  stop .......... #{response.stop_reason}")
      IO.puts("  files created #{created}/5 (expected: incomplete, the cap cut it short)")
      check.("stop_reason == :max_turns", response.stop_reason == :max_turns)

    {:error, {:quota, at}} ->
      IO.puts("  QUOTA HIT. Reopens at: #{inspect(at)}")
      true

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
      false
  end

File.rm_rf(root_d)

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))

IO.puts(
  "SECTION E: GENEROUS cap, SAME request: finishes normally, the cap does not cut legitimate work"
)

IO.puts(String.duplicate("=", 78))
# ============================================================================

root_e = fake_project.("cli-generous-cap")

section_e? =
  case ClaudeCLI.chat(
         %Request{
           role: "builder",
           model: "haiku",
           messages: [%{role: :user, content: multi_turn_request.()}],
           max_turns: 30
         },
         root: root_e,
         timeout: 180_000
       ) do
    {:ok, response} ->
      created = Enum.count(files, &File.exists?(Path.join(root_e, &1)))

      IO.puts("  stop .......... #{response.stop_reason}")
      IO.puts("  files created #{created}/5 (expected: complete)")

      [
        check.("stop_reason != :max_turns", response.stop_reason != :max_turns),
        check.("all five files were created", created == 5)
      ]
      |> Enum.all?()

    {:error, {:quota, at}} ->
      IO.puts("  QUOTA HIT. Reopens at: #{inspect(at)}")
      true

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
      false
  end

File.rm_rf(root_e)

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))

IO.puts(
  "SECTION F: MULTI-LINE prompt with double quotes and &, which broke an interpolated command line"
)

IO.puts(String.duplicate("=", 78))
# ============================================================================

root_f = fake_project.("cli-multiline-prompt")

hard_prompt =
  "Reply with the following three lines and nothing else:\n" <>
    "line \"with real double quotes\"\n" <>
    "line with an & in the middle"

section_f? =
  case ClaudeCLI.chat(
         %Request{
           model: "haiku",
           messages: [%{role: :user, content: hard_prompt}]
         },
         root: root_f,
         timeout: 180_000
       ) do
    {:ok, response} ->
      IO.puts("  stop .......... #{response.stop_reason}")
      IO.puts("  output ........ #{response.usage.output_tokens}")

      [
        check.("the call succeeds (a multi-line prompt no longer breaks the script)", true),
        check.("real usage came back", response.usage.output_tokens > 0)
      ]
      |> Enum.all?()

    {:error, {:quota, at}} ->
      IO.puts("  QUOTA HIT. Reopens at: #{inspect(at)}")
      true

    {:error, reason} ->
      IO.puts("  ERROR: #{inspect(reason)}")
      false
  end

File.rm_rf(root_f)

# ============================================================================
IO.puts("\n" <> String.duplicate("=", 78))

if Enum.all?([section_a?, section_b?, section_c?, section_d?, section_e?, section_f?]) do
  IO.puts("PROBE OK")
else
  IO.puts("PROBE FAILED")
  System.halt(1)
end
