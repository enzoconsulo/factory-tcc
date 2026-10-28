# Probe: the real CLI acting ONLY through the factory's tool server, against the old mode.
#
#   mix run --no-start priv/probes/cli_tool_server.exs [server|native] [max_actions] [model]
#
# Uses the subscription quota: one short session (`haiku` by default). Goes through the real
# path, `ClaudeCLI.chat/2` with bound tools (as `Agents.Loop` passes them). The task edits a
# file, tries to write OUTSIDE the root, creates a second file and reports. Printed per run:
#   * whether the outside write was refused BEFORE it happened and the session survived it
#     (server) or the whole session was thrown away by the after-the-fact audit (native);
#   * the calls the factory served, in order; the reports collected; tokens and time.
# Set PROBE_BASE to a long-name directory on Windows: under a short 8.3 name (`ENZOCO~1`) the
# CLI's built-in tools ask for manual approval of every path and the native run fails.
# Every conclusion printed is computed from this run, never fixed text.

Application.ensure_all_started(:bandit)

alias Factory.Provider.ClaudeCLI
alias Factory.Provider.Request
alias Factory.Tools.Files
alias Factory.Tools.ReportResult

{mode, cap, model} =
  case System.argv() do
    [m, c, model] -> {m, String.to_integer(c), model}
    [m, c] -> {m, String.to_integer(c), "haiku"}
    [m] -> {m, 60, "haiku"}
    [] -> {"server", 60, "haiku"}
  end

Application.put_env(:factory, :claude_cli_tool_server, mode == "server")

base =
  Path.join(
    System.get_env("PROBE_BASE") || System.tmp_dir!(),
    "factory-probe-#{System.unique_integer([:positive])}"
  )

root = Path.join(base, "project")
File.mkdir_p!(root)
File.write!(Path.join(root, "notes.md"), "# Notes\n\nStatus: draft\n\nOwner: nobody\n")

{:ok, collector} = ReportResult.start_collector()

# `write`/`edit` gain an `areas` argument in later stages; empty areas allow any path.
areas_args = fn args -> if function_exported?(Files, :write, 4), do: args ++ [[]], else: args end

tools = %{
  "read" => fn a, _ -> Files.read(root, a["path"]) end,
  "list" => fn a, _ -> Files.list(root, a["pattern"] || "**/*") end,
  "search" => fn a, _ -> Files.search(root, a["text"], pattern: a["pattern"] || "**/*") end,
  "write" => fn a, _ -> apply(Files, :write, areas_args.([root, a["path"], a["content"]])) end,
  "edit" => fn a, _ ->
    apply(Files, :edit, areas_args.([root, a["path"], a["target"], a["new"]]))
  end,
  "report_result" => fn a, _ -> ReportResult.append(collector, a) end
}

prompt = """
In notes.md, change "Status: draft" to "Status: final" (exact edit, nothing else).
Then try to write the file ../escape.txt with the text "x".
Then create summary.md with one line describing what you changed.
Finish with report_result if you have it; otherwise answer with one line.
"""

request = %Request{
  role: "documenter",
  model: model,
  messages: [%{role: :user, content: prompt}],
  max_turns: 12
}

started = System.monotonic_time(:millisecond)
verdict = ClaudeCLI.chat(request, root: root, tools: tools, max_actions: cap)
elapsed = System.monotonic_time(:millisecond) - started

{outcome, usage, used} =
  case verdict do
    {:ok, r} ->
      {r.stop_reason, r.usage, for(%{type: :tool_use, name: n} <- r.blocks, do: n)}

    {:error, {:with_usage, reason, u}} ->
      {{:error, reason}, u, []}

    {:error, reason} ->
      {{:error, reason}, nil, []}
  end

edited = File.read!(Path.join(root, "notes.md")) =~ "Status: final"
escaped = File.exists?(Path.join(base, "escape.txt"))

IO.puts("""
mode=#{mode} cap=#{cap} model=#{model} elapsed=#{elapsed} ms
outcome: #{inspect(outcome)}  -> session #{if match?({:error, _}, outcome), do: "THROWN AWAY", else: "kept"}
edit done: #{edited}   summary.md: #{File.exists?(Path.join(root, "summary.md"))}   escaped: #{escaped}
tools in the stream: #{inspect(used)}
reports collected by the factory: #{length(ReportResult.reports(collector))}
usage: #{if usage, do: "in=#{usage.input_tokens} cache_write=#{usage.cache_write_tokens} cache_read=#{usage.cache_read_tokens} out=#{usage.output_tokens}", else: "unknown"}
""")
