defmodule Factory.Provider.ClaudeCLI.ToolServer do
  @moduledoc """
  The factory's own tools, served to the CLI over MCP, so a `:full_agent` session acts only
  through the factory.

  Without it the CLI runs its own file tools and the factory can only audit the paths
  afterwards: a write outside the root is found when the session has already run and been
  paid for. With it, the CLI's built-in file tools are off (`--tools` lists none of them) and
  every read, write and report is a call into this server, which runs the SAME bound tool
  functions the loop receives on the `:model_endpoint` path (`state.tools`): the same
  `Factory.Tools.Files`, `Confinement` and `ReportResult` judge the action BEFORE it happens,
  with whatever the caller captured in them. The loop rules come back to this path:

    * a refused or failing tool returns `isError: true` with the reason, never disappears;
    * the action cap lives here, in the session state: past `max_actions` every call is
      refused with `action_cap`, whatever the prompt says;
    * every call is recorded in order, as it happens, not parsed from the output afterwards.

  One session per dispatch: `open/1` starts a listener on `127.0.0.1` on a free port, with an
  unguessable path segment, and `close/1` stops it. Nothing is shared between dispatches.

  Transport: the MCP Streamable HTTP subset the CLI needs, answered with plain JSON (the spec
  allows it): `initialize`, `ping`, `tools/list`, `tools/call`; notifications get `202`; `GET`
  (server-initiated stream) gets `405`. Four methods did not justify a dependency: the Hex
  libraries for it were pre-1.0 when this was written.

  The shell (`run`) is not served here: a command cannot be judged by path. It stays the
  CLI's `Bash`, inside the OS sandbox (see `Factory.Provider.ClaudeCLI`).
  """

  @server_name "factory"
  @protocol_versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)
  @default_max_actions 60

  # Catalogue name -> MCP tool definition. `run` is absent on purpose (see the moduledoc).
  @tools %{
    "read" => %{
      description: "Reads a project file. `path` is relative to the project root.",
      schema: %{"path" => "string"},
      required: ["path"]
    },
    "list" => %{
      description: "Lists project files matching a glob (default `**/*`).",
      schema: %{"pattern" => "string"},
      required: []
    },
    "search" => %{
      description: "Searches literal text in project files; optional glob `pattern`.",
      schema: %{"text" => "string", "pattern" => "string", "limit" => "integer"},
      required: ["text"]
    },
    "write" => %{
      description: "Writes a whole project file, creating missing directories.",
      schema: %{"path" => "string", "content" => "string"},
      required: ["path", "content"]
    },
    "edit" => %{
      description:
        "Replaces ONE exact occurrence of `target` with `new` in a project file. " <>
          "Refused when `target` appears zero times or more than once.",
      schema: %{"path" => "string", "target" => "string", "new" => "string"},
      required: ["path", "target", "new"]
    },
    "report_result" => %{
      description:
        "Reports what was done: summary, files, commands, commit, blocker. " <>
          "It does NOT change the task status: the system does.",
      schema: %{
        "summary" => "string",
        "files" => "array",
        "commands" => "array",
        "commit" => "string",
        "blocker" => "string"
      },
      required: ["summary"]
    }
  }

  @typedoc "A served call, recorded as it happened."
  @type call :: %{name: String.t(), arguments: map(), error: boolean(), content: String.t()}

  @typedoc "An open session."
  @type session :: %{agent: pid(), listener: pid(), url: String.t()}

  @doc "The MCP server name; the CLI exposes its tools as `mcp__factory__<tool>`."
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @typedoc "A bound tool, in the shape `Factory.Agents.Loop` calls: `fun.(arguments, root)`."
  @type tool :: (map(), Path.t() -> term())

  @doc "The catalogue tools this server can serve."
  @spec servable() :: [String.t()]
  def servable, do: @tools |> Map.keys() |> Enum.sort()

  @doc """
  Opens a session for one dispatch.

  Options: `:root` (required), `:tools` (the bound tool map `%{name => fun}`, as in
  `Factory.Agents.Loop.run(tools: ...)`; names this server does not serve are dropped) and
  `:max_actions` (default #{@default_max_actions}).
  """
  @spec open(keyword()) :: {:ok, session()} | {:error, term()}
  def open(opts) do
    root = Keyword.fetch!(opts, :root)
    tools = opts |> Keyword.get(:tools, %{}) |> Map.take(Map.keys(@tools))

    {:ok, agent} =
      Agent.start(fn ->
        %{
          root: root,
          tools: tools,
          max_actions: Keyword.get(opts, :max_actions, @default_max_actions),
          calls: []
        }
      end)

    secret = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    plug = {__MODULE__.Plug, agent: agent, path: ["mcp", secret]}

    case Bandit.start_link(
           plug: plug,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ) do
      {:ok, listener} ->
        Process.unlink(listener)
        {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
        {:ok, %{agent: agent, listener: listener, url: "http://127.0.0.1:#{port}/mcp/#{secret}"}}

      {:error, reason} ->
        Agent.stop(agent)
        {:error, reason}
    end
  end

  @doc "The served tool names in the CLI's own naming (`mcp__factory__read`, ...)."
  @spec cli_names(session()) :: [String.t()]
  def cli_names(%{agent: agent}) do
    agent |> Agent.get(&served_names/1) |> Enum.map(&"mcp__#{@server_name}__#{&1}")
  end

  @doc "The `--mcp-config` JSON for this session."
  @spec mcp_config(session()) :: String.t()
  def mcp_config(%{url: url}) do
    Jason.encode!(%{"mcpServers" => %{@server_name => %{"type" => "http", "url" => url}}})
  end

  @doc "Every call served so far, in order."
  @spec calls(session()) :: [call()]
  def calls(%{agent: agent}), do: Agent.get(agent, &Enum.reverse(&1.calls))

  @doc "Tells whether the session refused a call because of the action cap."
  @spec cap_hit?(session()) :: boolean()
  def cap_hit?(session), do: Enum.any?(calls(session), &(&1.content =~ "action_cap"))

  @doc "Stops the listener and the session state. Idempotent."
  @spec close(session()) :: :ok
  def close(%{agent: agent, listener: listener}) do
    if Process.alive?(listener), do: Supervisor.stop(listener, :normal)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  @doc false
  # The JSON-RPC answer for one decoded message; `nil` for notifications (no reply).
  @spec handle(pid(), map()) :: map() | nil
  def handle(agent, %{"method" => method} = message) do
    id = message["id"]

    if is_nil(id), do: nil, else: reply(id, dispatch(agent, method, message["params"] || %{}))
  end

  def handle(_agent, %{"id" => id}), do: reply(id, {:error, -32_600, "invalid request"})
  def handle(_agent, _other), do: nil

  defp reply(id, {:ok, result}), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp reply(id, {:error, code, message}),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp dispatch(_agent, "initialize", params) do
    requested = params["protocolVersion"]
    version = if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)

    {:ok,
     %{
       "protocolVersion" => version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => @server_name, "version" => "1.0.0"}
     }}
  end

  defp dispatch(_agent, "ping", _params), do: {:ok, %{}}

  defp dispatch(agent, "tools/list", _params) do
    names = Agent.get(agent, &served_names/1)
    {:ok, %{"tools" => Enum.map(names, &definition/1)}}
  end

  defp dispatch(agent, "tools/call", %{"name" => name} = params) do
    arguments = params["arguments"] || %{}
    {error, content} = call(agent, name, arguments)

    entry = %{name: name, arguments: arguments, error: error, content: content}
    Agent.update(agent, &%{&1 | calls: [entry | &1.calls]})

    {:ok, %{"content" => [%{"type" => "text", "text" => content}], "isError" => error}}
  end

  defp dispatch(_agent, method, _params), do: {:error, -32_601, "method not found: #{method}"}

  defp definition(name) do
    %{description: description, schema: schema, required: required} = Map.fetch!(@tools, name)

    properties =
      Map.new(schema, fn
        {key, "array"} -> {key, %{"type" => "array", "items" => %{"type" => "string"}}}
        {key, type} -> {key, %{"type" => type}}
      end)

    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => properties, "required" => required}
    }
  end

  # The cap is checked BEFORE the tool runs; the call that hits it is refused, not executed.
  # Refused calls count too: an agent hammering the cap is still spending turns.
  defp call(agent, name, arguments) do
    state = Agent.get(agent, & &1)

    cond do
      not Map.has_key?(state.tools, name) ->
        {true, "unknown tool: #{name}"}

      # `report_result` is never capped: the refusal tells the agent to report.
      name != "report_result" and capped(state.calls) >= state.max_actions ->
        {true,
         "action_cap: this dispatch already used its #{state.max_actions} actions. " <>
           "Stop and report what was done."}

      true ->
        run(name, arguments, state)
    end
  rescue
    exception -> {true, "the tool raised: #{Exception.message(exception)}"}
  end

  defp capped(calls), do: Enum.count(calls, &(&1.name != "report_result"))

  defp served_names(state), do: state.tools |> Map.keys() |> Enum.sort()

  defp run(name, arguments, state) do
    state.tools |> Map.fetch!(name) |> apply([arguments, state.root]) |> text()
  end

  # Bound tools return `{:ok, _}` / `{:error, reason}`; `report_result` returns its reply map.
  defp text({:ok, content}) when is_binary(content), do: {false, content}
  defp text({:ok, items}) when is_list(items), do: {false, Enum.map_join(items, "
", &line/1)}
  defp text({:ok, other}), do: {false, inspect(other)}
  defp text({:error, reason}), do: {true, "refused: #{inspect(reason)}"}

  defp text(%{recorded: true, warnings: warnings}),
    do: {false, Enum.join(["recorded" | warnings], "
")}

  defp text(other), do: {false, inspect(other)}

  defp line({path, number, text}), do: "#{path}:#{number}: #{text}"
  defp line(item) when is_binary(item), do: item
  defp line(item), do: inspect(item)

  defmodule Plug do
    @moduledoc false
    # The HTTP side of `Factory.Provider.ClaudeCLI.ToolServer`: one POST endpoint.

    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    alias Factory.Provider.ClaudeCLI.ToolServer

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{path_info: path} = conn, opts) do
      if path == opts[:path], do: serve(conn, opts[:agent]), else: send_resp(conn, 404, "")
    end

    defp serve(%{method: "POST"} = conn, agent) do
      {:ok, body, conn} = read_body(conn, length: 20_000_000)

      case Jason.decode(body) do
        {:ok, messages} when is_list(messages) ->
          answer(
            conn,
            messages |> Enum.map(&ToolServer.handle(agent, &1)) |> Enum.reject(&is_nil/1)
          )

        {:ok, message} ->
          answer(conn, ToolServer.handle(agent, message))

        {:error, _} ->
          answer(conn, %{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{"code" => -32_700, "message" => "parse error"}
          })
      end
    end

    defp serve(%{method: "DELETE"} = conn, _agent), do: send_resp(conn, 200, "")
    defp serve(conn, _agent), do: send_resp(conn, 405, "")

    defp answer(conn, nil), do: send_resp(conn, 202, "")
    defp answer(conn, []), do: send_resp(conn, 202, "")

    defp answer(conn, reply) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(reply))
    end
  end
end
