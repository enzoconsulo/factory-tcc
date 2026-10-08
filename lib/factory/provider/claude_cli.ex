defmodule Factory.Provider.ClaudeCLI do
  @moduledoc """
  Provider that drives the Claude Code CLI (`claude --print`). It is the factory's default
  provider: it runs on the subscription (OAuth, no `ANTHROPIC_API_KEY`), so it consumes quota
  rather than money and every dollar figure the factory records for it is an estimate.

  It belongs to the `:full_agent` family: the CLI runs its own tool loop, so the factory sends
  one request per dispatch and governance has to be enforced on the command line and by
  auditing the output stream. The governance facts it relies on, all measured against the
  real binary:

    * **No cache control.** It does not place cache breakpoints: the CLI manages the cache and
      exposes neither `cache_control` nor a TTL choice. It does *report* the TTL it used
      (`usage.cache_creation`), which sets the cache-write multiplier. Explicit cache control
      is the reason `MessagesAPI` exists.
    * **Quota hit.** Structural under a subscription: a quota hit becomes
      `{:error, {:quota, reopens_at}}`. The verdict comes from the `result` event, not from the
      warning: a `rate_limit_event` that is not `allowed` only counts as a hit when the call
      was not served (no `result`, an error `result` caused by the limit, an error `result`
      with an unknown subtype, or a `result` with no answer). A served call logs a warning.
      One regex (`limit_message?/1`) recognises the CLI's limit messages on both paths.
    * **Headless permission.** `--permission-mode acceptEdits`: the least privileged mode that
      can write; `bypassPermissions` would also disable the CLI's own path confinement.
    * **Tool vocabulary.** `--tools "<list>"` closes the vocabulary (tools outside it are not
      even announced); `--disallowedTools` is never used because the model can route around
      it. `cli_tools/1` translates the factory catalogue into this list; an explicit
      `Request.vocabulary` replaces the role's vocabulary, never adds to it.
    * **Shell approval.** `--allowedTools "Bash"` is added only when `--tools` already contains
      `Bash`: in `--print` nobody can answer a permission prompt and `acceptEdits` approves
      only edits. It approves; it does NOT confine anything.
    * **Shell sandbox.** Every role with `Bash` gets `--settings` with
      `{"sandbox": {"enabled": true, "failIfUnavailable": true, "autoAllowBashIfSandboxed":
      true, "allowUnsandboxedCommands": false}}`, with no configuration key to turn it off.
      Shell writes outside the root fail with `Read-only file system` (the OS denies them).
      It does not confine reading, and it restricts the shell's network access by default.
      Where the sandbox is unavailable (no `bwrap`/`socat`, or native Windows) the CLI refuses
      to start and this module returns `{:error, :sandbox_unavailable}`.
    * **Path confinement, two halves.** (1) Prevention: `acceptEdits` with the working
      directory set to the request root makes the CLI refuse writes outside it
      (`priv/probes/confinement_cli.exs` proves it). (2) Audit: `parse/2` passes every path
      argument (`file_path`, `path`, `notebook_path`) of every `tool_use` through
      `Confinement.resolve(root, path)` and returns
      `{:error, {:outside_confinement, paths}}`, wrapped with the measured usage by
      `build_response/2`, because the session already ran and was paid for.
    * **The remaining gap.** Shell commands cannot be audited by path. The options were:
      (a) do not allow the shell tool under `:full_agent`; (b) serve the factory's tools over
      MCP; (c) accept the gap and declare it; (d) confine the shell in the CLI's
      OS-level sandbox. The factory uses (d); the shell can still read outside the root.
    * **Stop reason from the terminal event.** Blocks accumulate every turn of the CLI
      session, so a `tool_use` in them is a record, not a pending request. This provider
      never returns `:tool_use`: only `:end_turn`, `:max_turns` or `:refusal`.

  Tests point `config :factory, :claude_cli` at a fake script, so the suite runs without
  network or quota.
  """

  @behaviour Factory.Provider

  require Logger

  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage
  alias Factory.Tools.Catalog
  alias Factory.Tools.Command
  alias Factory.Tools.Confinement

  @default_timeout :timer.minutes(10)

  # Catalogue tool -> CLI tool. The CLI vocabulary stops here: no other module in lib/ may
  # name these tools (a test enforces it). `report_result` has no CLI equivalent.
  @cli_vocabulary %{
    "read" => "Read",
    "list" => "Glob",
    "search" => "Grep",
    "write" => "Write",
    "edit" => "Edit",
    "run" => "Bash"
  }

  # Internal model name -> full CLI model ID. Full IDs on purpose: the short aliases follow
  # the newest model silently. `Factory.Cost.Pricing` must price exactly these IDs.
  @cli_models %{
    "sonnet-5" => "claude-sonnet-5-5",
    "opus-5" => "claude-opus-5-5",
    "haiku-4.5" => "claude-haiku-4-5-20251001"
  }

  # The CLI's own short aliases pass through untranslated (the probes use them).
  @cli_aliases ~w(sonnet opus haiku)

  @doc """
  The CLI's own short model aliases that `cli_model/1` lets through. Public so the pricing
  table can be checked against it (an unpriced alias would cost 0.0 per turn).
  """
  @spec cli_aliases() :: [String.t()]
  def cli_aliases, do: @cli_aliases

  @path_keys ~w(file_path path notebook_path)

  @doc "The CLI executable, from configuration (never resolved from PATH directly)."
  @spec executable() :: String.t()
  def executable, do: Application.get_env(:factory, :claude_cli, "claude")

  @doc """
  This provider's family: `:full_agent`. The CLI has its own loop, tools and permissions, so
  the command line (not `Agents.Loop`) must enforce the catalogue's restrictions.
  """
  @impl Factory.Provider
  def family, do: :full_agent

  @doc """
  Translates a role's catalogue tools (`Factory.Tools.Catalog`) into CLI tool names for
  `--tools`. An unknown role yields `[]`, i.e. `--tools ""`: every tool disabled.
  """
  @spec cli_tools(String.t()) :: [String.t()]
  def cli_tools(role) do
    case Catalog.for_role(role) do
      {:ok, tools} -> tools |> Map.keys() |> cli_tools_for_vocabulary()
      {:error, _} -> []
    end
  end

  @doc """
  Same translation as `cli_tools/1`, from an explicit list of catalogue tool names (used by
  `Request.vocabulary`). Unknown names are dropped.
  """
  @spec cli_tools_for_vocabulary([String.t()]) :: [String.t()]
  def cli_tools_for_vocabulary(names) do
    names
    |> Enum.map(&Map.get(@cli_vocabulary, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Internal model names and the `--model` ID each one becomes."
  @spec cli_models() :: %{String.t() => String.t()}
  def cli_models, do: @cli_models

  @doc """
  Translates a factory model name into the ID the CLI accepts in `--model`.

  Internal names map to full IDs; full IDs and the CLI's short aliases map to themselves.
  Anything else returns `{:error, {:untranslated_model, name}}` and never reaches the CLI,
  which would reject it only after starting, as an indistinguishable `:refusal`.
  """
  @spec cli_model(term()) :: {:ok, String.t()} | {:error, {:untranslated_model, term()}}
  def cli_model(name) do
    cond do
      Map.has_key?(@cli_models, name) -> {:ok, Map.fetch!(@cli_models, name)}
      already_cli?(name) -> {:ok, name}
      true -> {:error, {:untranslated_model, name}}
    end
  end

  defp already_cli?(name), do: name in Map.values(@cli_models) or name in @cli_aliases

  @impl Factory.Provider
  def chat(%Request{} = request, opts) do
    root = Keyword.get(opts, :root, ".")
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Build the line first: an untranslated model fails before any process or temp file.
    with {:ok, line} <- command_line(request) do
      prompt_file = write_prompt(prompt_text(request))

      result =
        Command.run_split_streams(root, line,
          timeout: timeout,
          stdin: {:file, prompt_file}
        )

      remove_prompt(prompt_file)

      case result do
        {:ok, output} -> build_response(output, root)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  What `chat/2` returns for the raw output of one CLI process: the verdict of `parse/2`,
  plus the measured usage on errors of a session that already spent tokens.

  `{:outside_confinement, paths}` and `:timeout` become
  `{:error, {:with_usage, reason, %Usage{}}}`, using the `result` event's usage when present,
  or else a floor estimate from the `usage` of the `assistant` lines already written. With
  nothing measured, the bare error is returned and a warning says it counts as 0.0. A quota
  hit is never wrapped.
  """
  @spec build_response(
          %{
            :stdout => String.t(),
            :stderr => String.t(),
            optional(atom()) => term()
          },
          Path.t() | nil
        ) :: {:ok, Response.t()} | {:error, term()}
  def build_response(%{reason: :timeout} = output, _root),
    do: with_measured_usage(:timeout, output)

  def build_response(output, root) do
    case parse(output, root) do
      {:error, {:outside_confinement, _paths} = reason} -> with_measured_usage(reason, output)
      verdict -> verdict
    end
  end

  defp with_measured_usage(reason, output) do
    case measured_usage(events(output.stdout), output[:duration_ms]) do
      %Usage{} = usage ->
        {:error, {:with_usage, reason, usage}}

      nil ->
        Logger.warning(
          "provider error #{inspect(reason)} with no result and no assistant line with " <>
            "usage: this dispatch's usage is unknown and counts as 0.0"
        )

        {:error, reason}
    end
  end

  defp measured_usage(events, duration_ms) do
    case Enum.find(events, &(&1["type"] == "result")) do
      nil -> usage_from_messages(events, duration_ms)
      result -> usage(result)
    end
  end

  # The CLI writes one line per block of the same call, each with that call's full usage, so
  # only the last line per `message.id` counts. Their `output_tokens` is partial and auxiliary
  # calls are missing: the estimate is a floor.
  defp usage_from_messages(events, duration_ms) do
    usages =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"type" => "assistant", "message" => %{"usage" => %{} = usage} = message}, index} ->
          [{message["id"] || {:no_id, index}, usage}]

        _other ->
          []
      end)
      |> Map.new()
      |> Map.values()

    if usages == [], do: nil, else: estimate_from_usage(usages, duration_ms)
  end

  defp estimate_from_usage(usages, duration_ms) do
    write = sum(usages, &number(&1["cache_creation_input_tokens"]))

    Logger.warning(
      "timeout with no result: usage estimated from #{length(usages)} call(s) already " <>
        "written; a floor, not a total (partial output, no auxiliary CLI calls)"
    )

    %Usage{
      input_tokens: sum(usages, &number(&1["input_tokens"])),
      cache_write_tokens: write,
      cache_read_tokens: sum(usages, &number(&1["cache_read_input_tokens"])),
      output_tokens: sum(usages, &number(&1["output_tokens"])),
      duration_ms: if(is_integer(duration_ms), do: duration_ms),
      cache_ttl: cache_ttl(ttl_breakdown(usages), write)
    }
  end

  defp sum(usages, field), do: usages |> Enum.map(field) |> Enum.sum()

  # Same shape as `usage.cache_creation`, so `cache_ttl/2` applies the same rule.
  defp ttl_breakdown(usages) do
    breakdowns = for %{"cache_creation" => %{} = breakdown} <- usages, do: breakdown

    if breakdowns != [] do
      %{
        "ephemeral_5m_input_tokens" => sum(breakdowns, &number(&1["ephemeral_5m_input_tokens"])),
        "ephemeral_1h_input_tokens" => sum(breakdowns, &number(&1["ephemeral_1h_input_tokens"]))
      }
    end
  end

  @doc """
  Builds the command line for a request. Public so tests can check it without running the
  CLI.

  The line is constant with respect to the conversation: the prompt travels through `stdin`
  from a temp file, because there is no reliable escaping for newlines, quotes, `&`, `|` and
  `%VAR%` on an interpolated command line.

    * `--print --verbose --output-format stream-json`: the CLI refuses stream-json without
      `--verbose`.
    * `--permission-mode acceptEdits` and `--tools "<list>"` (see the moduledoc).
    * `--allowedTools "Bash"` right after `--tools`, only when `--tools` contains `Bash`.
    * `--max-turns <n>` from `request.max_turns`: the turn cap must live on the command line
      because the CLI runs the turns. The flag is undocumented but works.
    * `--setting-sources user`: otherwise the CLI reads the `CLAUDE.md` of every parent
      directory. `--bare` is not an option: it requires `ANTHROPIC_API_KEY`.
    * `--settings "<sandbox json>"` before `--model`, by the same rule as the approval.
    * `--model` with the ID from `cli_model/1`; an untranslated model returns
      `{:error, {:untranslated_model, name}}`.

  The approval and sandbox rules read the already translated tool list, so they hold the same
  for a role's vocabulary and for an explicit `request.vocabulary`.
  """
  @spec command_line(Request.t()) :: {:ok, String.t()} | {:error, {:untranslated_model, term()}}
  def command_line(%Request{} = request) do
    with {:ok, model} <- cli_model(request.model) do
      tools = request_tools(request)

      {:ok,
       ~s(#{executable()} --print --verbose --output-format stream-json ) <>
         ~s(--permission-mode acceptEdits --tools "#{Enum.join(tools, ",")}" ) <>
         shell_approval(tools) <>
         ~s(--max-turns #{request.max_turns} ) <>
         ~s(--setting-sources user ) <>
         shell_sandbox(tools) <>
         ~s(--model #{model})}
    end
  end

  defp request_tools(%Request{vocabulary: vocabulary}) when is_list(vocabulary) do
    cli_tools_for_vocabulary(vocabulary)
  end

  defp request_tools(%Request{role: role}), do: cli_tools(role)

  @cli_shell Map.fetch!(@cli_vocabulary, "run")

  defp shell_approval(tools) do
    if @cli_shell in tools, do: ~s(--allowedTools "#{@cli_shell}" ), else: ""
  end

  # Inline JSON keeps `command_line/1` pure. Quoted as "..." with each inner quote as \",
  # the only form both the `sh` and the Windows `.bat` launchers unquote correctly.
  @cli_sandbox Jason.encode!(%{
                 "sandbox" => %{
                   "enabled" => true,
                   "failIfUnavailable" => true,
                   "autoAllowBashIfSandboxed" => true,
                   "allowUnsandboxedCommands" => false
                 }
               })

  defp shell_sandbox(tools) do
    if @cli_shell in tools,
      do: ~s(--settings "#{String.replace(@cli_sandbox, ~s("), ~s(\\"))}" ),
      else: ""
  end

  @doc "The full prompt text: the whole conversation, one message per line."
  @spec prompt_text(Request.t()) :: String.t()
  def prompt_text(%Request{messages: messages}) do
    Enum.map_join(messages, "\n", &message_text/1)
  end

  defp message_text(%{content: content}) when is_binary(content), do: content
  defp message_text(%{content: content}), do: inspect(content)
  defp message_text(other), do: inspect(other)

  # Always removed afterwards, even when the call fails (see `chat/2`).
  @spec write_prompt(String.t()) :: Path.t()
  defp write_prompt(text) do
    mark = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "factory-cli-prompt-#{mark}.txt")
    File.write!(path, text)
    path
  end

  # Best effort: the call's result is already in hand, so a failed removal only logs.
  @spec remove_prompt(Path.t()) :: :ok
  defp remove_prompt(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not remove the temporary prompt #{path}: #{inspect(reason)}")
    end
  end

  @doc """
  Parses the CLI output: one JSON event per line. Public so tests can feed known events.

  The map is open on purpose: `Command.run_split_streams/3` returns more keys (`reason`,
  `code`, `duration_ms`). With `root`, the path audit (half 2 of confinement) is on; without
  it (`parse/1`) the audit is off, as there is nothing to compare against.
  """
  @spec parse(
          %{
            :stdout => String.t(),
            :stderr => String.t(),
            optional(atom()) => term()
          },
          Path.t() | nil
        ) :: {:ok, Response.t()} | {:error, term()}
  def parse(result, root \\ nil)

  def parse(%{stdout: stdout, stderr: stderr}, root) do
    events = events(stdout)

    if sandbox_unavailable?(events, stderr) do
      warn_sandbox(events, stderr)
      {:error, :sandbox_unavailable}
    else
      case quota(events, stdout <> stderr) do
        {:quota, reopens_at} -> {:error, {:quota, reopens_at}}
        :no_quota -> build(events, root)
      end
    end
  end

  # The CLI refusing to start because the required sandbox is missing: exit 1, a single error
  # `result` with `num_turns: 0` (reason in `errors`) and, on stderr, "sandbox required but
  # unavailable ... refusing to start without a working sandbox". Checked before everything,
  # since on the normal path that `result` would become `:refusal`. Both conditions are
  # required: the session did not start (only zero-turn `result`s; a started session writes
  # `system/init` first) and the text appears on stderr or in `errors`.
  @sandbox_unavailable ~r/sandbox required but unavailable|refusing to start without a working sandbox/i

  defp sandbox_unavailable?(events, stderr) do
    not_started?(events) and missing_sandbox_cause(events, stderr) != nil
  end

  # Also matches an empty stdout (no events).
  defp not_started?(events) do
    Enum.all?(events, &match?(%{"type" => "result", "num_turns" => 0}, &1))
  end

  defp missing_sandbox_cause(events, stderr) do
    errors =
      for %{"type" => "result", "errors" => [_ | _] = list} <- events,
          text <- list,
          is_binary(text),
          do: text

    texts = if is_binary(stderr), do: [stderr | errors], else: errors
    Enum.find(texts, &(&1 =~ @sandbox_unavailable))
  end

  defp warn_sandbox(events, stderr) do
    Logger.warning(
      "claude refused to start: the role has Bash and the required sandbox is unavailable " <>
        "(no command ran, nothing was spent). cause: " <>
        String.trim(missing_sandbox_cause(events, stderr))
    )
  end

  defp events(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = event} -> [event]
        # The CLI sometimes writes loose text; a noise line must not sink the dispatch.
        _ -> []
      end
    end)
  end

  # Quota hit, read from the events the CLI actually emits:
  #
  #     {"type":"rate_limit_event",
  #      "rate_limit_info":{"status":"allowed","resetsAt":1788236400, ...}}
  #
  # A status not starting with "allowed" ("allowed_warning" is still allowed) is a warning
  # about the account; it is a hit only when the call was not served (`served?/1`). The text
  # fallback uses the same recogniser as the warning path.
  defp quota(events, text) do
    structured = Enum.find(events, &wall?/1)
    served_warning = warning?(structured) and served?(events)

    cond do
      structured != nil and not served_warning ->
        {:quota, time(reopens_at(structured))}

      limit_message?(text) ->
        {:quota, time_in_text(text)}

      served_warning ->
        warn_limit(structured, events)
        :no_quota

      true ->
        :no_quota
    end
  end

  # Only `rate_limit_event` is a warning; the older `usage_limit`/`rate_limit` subtypes are
  # the verdict itself.
  defp warning?(%{"type" => "rate_limit_event"}), do: true
  defp warning?(_event), do: false

  # The CLI's own errors: the subtype names a cause that is not the quota.
  @own_errors ["error_max_turns", "error_during_execution", "error_max_budget_usd"]

  # Called only with a non-allowed warning present:
  #   * no `result` -> not served;
  #   * own error subtype -> served, unless the error is caused by the limit;
  #   * any other `is_error: true` -> not served (the real hit arrives as
  #     `subtype: "success"` + `is_error: true`);
  #   * no error -> served if there was an answer (an assistant block or result text).
  defp served?(events) do
    case Enum.find(events, &(&1["type"] == "result")) do
      nil ->
        false

      %{"is_error" => true, "subtype" => subtype} = result when subtype in @own_errors ->
        not limit_error?(result)

      %{"is_error" => true} ->
        false

      result ->
        Enum.any?(events, &(event_blocks(&1) != [])) or text_in_result?(result)
    end
  end

  # Positive signal in an error `result`: HTTP 429, or a limit message in `result`/`errors`.
  defp limit_error?(result) do
    result["api_error_status"] in [429, "429"] or
      Enum.any?(error_texts(result), &limit_message?/1)
  end

  defp error_texts(result) do
    errors = if is_list(result["errors"]), do: result["errors"], else: []
    [result["result"] | errors]
  end

  # The single recogniser of the CLI's limit messages:
  #   * "You've hit your <window> limit|budget" (session, weekly, Opus, Sonnet, usage credit,
  #     monthly spend, fast, team's shared budget...); the middle never crosses a quote or a
  #     newline, so two JSON strings are never joined;
  #   * "monthly spend limit" without the prefix;
  #   * older forms: "limit reached", "usage limit", `rate_limit_error`, "rate limit exceeded".
  # A bare `rate.?limit` is excluded: every stream contains `rate_limit_event`.
  @limit_message ~r/hit your [^"\n]{0,60}?\b(?:limit|budget)\b|monthly spend limit|limit reached|usage limit|rate.?limit(?:_error|\s+exceeded)/i

  defp limit_message?(text) when is_binary(text), do: text =~ @limit_message
  defp limit_message?(_text), do: false

  defp text_in_result?(%{"result" => text}) when is_binary(text),
    do: String.trim(text) != ""

  defp text_in_result?(_result), do: false

  defp warn_limit(%{"rate_limit_info" => info} = event, events) do
    reopens = time(reopens_at(event))
    result = Enum.find(events, &(&1["type"] == "result")) || %{}

    Logger.warning(
      "rate_limit_event #{info["status"]} with the call SERVED (result #{result["subtype"]}, " <>
        "is_error: #{inspect(result["is_error"])}, not caused by the limit): " <>
        "not a quota hit. Window: #{info["rateLimitType"] || "unknown"}; " <>
        "resetsAt: #{if reopens, do: DateTime.to_iso8601(reopens), else: "unknown"}; " <>
        "overageStatus: #{info["overageStatus"] || "-"}; " <>
        "isUsingOverage: #{inspect(info["isUsingOverage"])}; " <>
        "unifiedWindows: #{inspect(info["unifiedWindows"])}"
    )
  end

  defp wall?(%{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => status}}) do
    not String.starts_with?(status, "allowed")
  end

  defp wall?(event) do
    event["subtype"] in ["usage_limit", "rate_limit"] or event["type"] == "usage_limit"
  end

  defp reopens_at(%{"rate_limit_info" => %{} = info}) do
    info["resetsAt"] || info["resets_at"]
  end

  defp reopens_at(event), do: event["resetsAt"] || event["resets_at"]

  @doc """
  The quota window utilisation, when the CLI reports it (inside `rate_limit_event`), or `nil`
  when the event is absent.
  """
  @spec quota_windows(String.t()) :: %{String.t() => map()} | nil
  def quota_windows(stdout) do
    stdout
    |> events()
    |> Enum.find_value(fn
      %{"type" => "rate_limit_event", "rate_limit_info" => info} -> info["unifiedWindows"]
      _other -> nil
    end)
  end

  defp time(nil), do: nil

  defp time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, at} -> at
      _ -> nil
    end
  end

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp time(_), do: nil

  defp time_in_text(text) do
    case Regex.run(~r/(\d{4}-\d{2}-\d{2}T[\d:]+(?:\.\d+)?Z?)/, text) do
      [_, iso] -> time(iso)
      _ -> nil
    end
  end

  defp build(events, root) do
    blocks = Enum.flat_map(events, &event_blocks/1)
    result = Enum.find(events, &(&1["type"] == "result"))

    cond do
      result == nil and blocks == [] ->
        {:error, :unreadable_output}

      (outside_paths = outside_confinement(blocks, root)) != [] ->
        {:error, {:outside_confinement, outside_paths}}

      true ->
        {:ok,
         %Response{
           blocks: blocks,
           stop_reason: stop_reason(result),
           usage: usage(result)
         }}
    end
  end

  # Path audit (half 2 of confinement), using the same function as the factory's own tools.
  defp outside_confinement(_blocks, nil), do: []

  defp outside_confinement(blocks, root) do
    blocks
    |> Enum.filter(&(&1.type == :tool_use))
    |> Enum.flat_map(&block_paths/1)
    |> Enum.uniq()
    |> Enum.filter(&outside_root?(root, &1))
  end

  defp block_paths(%{arguments: arguments}) do
    arguments
    |> Enum.filter(fn {key, value} -> key in @path_keys and is_binary(value) end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp outside_root?(root, path) do
    match?({:error, _reason}, Confinement.resolve(root, path))
  end

  defp event_blocks(%{"type" => "assistant", "message" => %{"content" => content}}) do
    Enum.map(content, &translate_block/1)
  end

  defp event_blocks(_event), do: []

  # The rest of the factory must not know which provider is running.
  defp translate_block(%{"type" => "text", "text" => text}) do
    %{type: :text, text: text}
  end

  defp translate_block(%{"type" => "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block["id"],
      name: block["name"],
      arguments: block["input"] || %{}
    }
  end

  # Extended thinking has its own type (it appears in almost every response) and keeps the
  # `signature`, which is what allows sending the block back to the model.
  defp translate_block(%{"type" => "thinking"} = block) do
    %{type: :thinking, text: block["thinking"], signature: block["signature"]}
  end

  defp translate_block(other), do: %{type: :unknown, raw: other}

  # Reads only the terminal `result` event, never the accumulated blocks.
  defp stop_reason(result) do
    cond do
      result["subtype"] == "error_max_turns" -> :max_turns
      result["is_error"] == true -> :refusal
      true -> :end_turn
    end
  end

  # Usage of a real dispatch, from the `result` event. This becomes the recorded spend, so
  # under-counting here means spending past the cap. Tokens come from `modelUsage` (which also
  # counts the CLI's auxiliary calls), falling back to `usage`; the TTL from
  # `usage.cache_creation`.
  defp usage(nil), do: %Usage{}

  defp usage(result) do
    raw = result["usage"] || %{}
    tokens = tokens(result["modelUsage"], raw)

    %Usage{
      input_tokens: tokens.input,
      cache_write_tokens: tokens.write,
      cache_read_tokens: tokens.read,
      output_tokens: tokens.output,
      duration_ms: number(result["duration_ms"]),
      cache_ttl: cache_ttl(raw["cache_creation"], tokens.write)
    }
  end

  # Sums every model in `modelUsage`; auxiliary calls are priced at the dispatch model's
  # price, which errs on the safe (higher) side.
  defp tokens(%{} = per_model, _raw) when map_size(per_model) > 0 do
    per_model
    |> Map.values()
    |> Enum.reduce(%{input: 0, write: 0, read: 0, output: 0}, fn model, acc ->
      %{
        input: acc.input + number(model["inputTokens"]),
        write: acc.write + number(model["cacheCreationInputTokens"]),
        read: acc.read + number(model["cacheReadInputTokens"]),
        output: acc.output + number(model["outputTokens"])
      }
    end)
  end

  defp tokens(_per_model, raw) do
    %{
      input: number(raw["input_tokens"]),
      write: number(raw["cache_creation_input_tokens"]),
      read: number(raw["cache_read_input_tokens"]),
      output: number(raw["output_tokens"])
    }
  end

  # Cache-write TTL, which sets the multiplier (1.25x for 5 min, 2.0x for 1 h):
  #   * no write -> `:no_cache`;
  #   * no TTL breakdown -> `:no_cache` ("unknown", priced at 0.0x), with a warning;
  #   * only 5 min -> `:five_minutes`;
  #   * any 1 h write -> `:one_hour`. Both TTLs in one dispatch are charged at 2.0x (never
  #     below the exact cost), with a warning.
  defp cache_ttl(_breakdown, 0), do: :no_cache

  defp cache_ttl(%{} = breakdown, write) do
    five_minutes = number(breakdown["ephemeral_5m_input_tokens"])
    one_hour = number(breakdown["ephemeral_1h_input_tokens"])

    cond do
      five_minutes > 0 and one_hour > 0 ->
        Logger.warning(
          "dispatch with both cache TTLs (5 min: #{five_minutes}, 1 h: #{one_hour}); " <>
            "all writes (#{write}) charged at 2.0x, above the exact cost"
        )

        :one_hour

      five_minutes > 0 and one_hour == 0 and five_minutes >= write ->
        :five_minutes

      true ->
        :one_hour
    end
  end

  defp cache_ttl(_no_breakdown, write) do
    Logger.warning(
      "CLI result without usage.cache_creation: #{write} cache-write tokens " <>
        "with unknown TTL, charged at 0.0x"
    )

    :no_cache
  end

  defp number(value) when is_integer(value), do: value
  defp number(_), do: 0
end
