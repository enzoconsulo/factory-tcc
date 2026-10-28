defmodule Factory.Provider.ClaudeCLI.ToolServerTest do
  use ExUnit.Case, async: true

  alias Factory.Agents.Loop
  alias Factory.Provider.ClaudeCLI
  alias Factory.Provider.ClaudeCLI.ToolServer
  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Tools.Confinement
  alias Factory.Tools.Files
  alias Factory.Tools.ReportResult

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "tool-server-#{System.unique_integer([:positive])}")
    root = Path.join(base, "project")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "the secret word is MAGENTA\n")
    {:ok, collector} = ReportResult.start_collector()

    {:ok, session} =
      ToolServer.open(root: root, tools: bound(root, collector), max_actions: 3)

    on_exit(fn ->
      ToolServer.close(session)
      File.rm_rf(base)
    end)

    %{base: base, root: root, session: session, collector: collector}
  end

  # The bound tool map, in the shape `Agents.Loop` receives. `write` goes through
  # `Confinement.resolve/2` directly, so this file does not depend on the `Files.write`
  # arity, which later stages extend.
  defp bound(root, collector) do
    %{
      "read" => fn args, _ -> Files.read(root, args["path"]) end,
      "list" => fn args, _ -> Files.list(root, args["pattern"] || "**/*") end,
      "write" => fn args, _ ->
        with {:ok, absolute} <- Confinement.resolve(root, args["path"] || ""),
             content when is_binary(content) <- args["content"] || {:error, :missing_content} do
          File.mkdir_p!(Path.dirname(absolute))
          File.write!(absolute, content)
          {:ok, absolute}
        end
      end,
      "run" => fn _args, _ -> {:error, :should_never_be_called} end,
      "report_result" => fn args, _ -> ReportResult.append(collector, args) end
    }
  end

  # Plain `:httpc` on the loopback: the suite's `Req` is wired to `Factory.NoNetwork`, and
  # this server never leaves the machine.
  defp post(%{url: url}, body), do: request(:post, url, Jason.encode!(body))

  defp request(method, url, body \\ nil) do
    http =
      if method == :post,
        do: {String.to_charlist(url), [], ~c"application/json", body},
        else: {String.to_charlist(url), []}

    case :httpc.request(method, http, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, ""}} -> %{status: status, body: nil}
      {:ok, {{_, status, _}, _headers, raw}} -> %{status: status, body: Jason.decode!(raw)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call(session, name, arguments, id \\ 1) do
    response =
      post(session, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })

    response.body["result"]
  end

  describe "the MCP handshake over HTTP" do
    test "initialize answers the requested protocol version and declares tools", %{
      session: session
    } do
      body =
        post(session, %{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
        }).body

      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["capabilities"]["tools"]
      assert body["result"]["serverInfo"]["name"] == "factory"
    end

    test "a notification gets 202 with no body, a GET gets 405", %{session: session} do
      assert post(session, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}).status ==
               202

      assert request(:get, session.url).status == 405
    end

    test "a wrong path is 404: the URL carries an unguessable segment", %{session: session} do
      wrong = String.replace(session.url, ~r{/mcp/.*$}, "/mcp/guess")
      assert request(:post, wrong, "{}").status == 404
    end

    test "tools/list serves the file tools and report_result, never the shell", %{
      session: session
    } do
      body = post(session, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}).body
      names = body["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

      assert names == ~w(list read report_result write)
      refute "run" in names
      assert Enum.all?(body["result"]["tools"], &(&1["inputSchema"]["type"] == "object"))
    end

    test "an unknown method is a JSON-RPC error, not a crash", %{session: session} do
      body = post(session, %{"jsonrpc" => "2.0", "id" => 3, "method" => "resources/list"}).body
      assert body["error"]["code"] == -32_601
    end
  end

  describe "every action goes through the factory, judged before it happens" do
    test "read and write inside the root work and are recorded in order", %{
      session: session,
      root: root
    } do
      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               call(session, "read", %{"path" => "input.txt"})

      assert text =~ "MAGENTA"

      assert %{"isError" => false} =
               call(session, "write", %{"path" => "out/output.txt", "content" => "MAGENTA"})

      assert File.read!(Path.join(root, "out/output.txt")) == "MAGENTA"
      assert Enum.map(ToolServer.calls(session), & &1.name) == ~w(read write)
    end

    test "a write outside the root is refused as an error result and nothing is written", %{
      session: session,
      base: base
    } do
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               call(session, "write", %{"path" => "../outside.txt", "content" => "escaped"})

      assert text =~ "outside_confinement"
      refute File.exists?(Path.join(base, "outside.txt"))
      assert [%{name: "write", error: true}] = ToolServer.calls(session)
    end

    test "a tool not served (the shell) is an error result, not a crash", %{session: session} do
      assert %{"isError" => true, "content" => [%{"text" => "unknown tool: run"}]} =
               call(session, "run", %{"command" => "rm -rf /"})
    end

    test "a bound tool's own refusal is an error result", %{session: session} do
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               call(session, "write", %{"path" => "x.txt"})

      assert text =~ "missing_content"
    end
  end

  describe "the action cap lives in the session, not in the prompt" do
    test "past the cap every call is refused BEFORE it runs", %{session: session, root: root} do
      for n <- 1..3, do: call(session, "write", %{"path" => "f#{n}.txt", "content" => "x"})

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               call(session, "write", %{"path" => "f4.txt", "content" => "x"})

      assert text =~ "action_cap"
      refute File.exists?(Path.join(root, "f4.txt"))
    end

    test "report_result is never capped: the refusal itself asks for the report", %{
      session: session,
      collector: collector
    } do
      for n <- 1..4, do: call(session, "list", %{}, n)

      assert %{"isError" => false} =
               call(session, "report_result", %{"summary" => "stopped at the cap"})

      assert [%{summary: "stopped at the cap"}] = ReportResult.reports(collector)
    end

    test "a system field in the report is dropped with a warning in the same answer", %{
      session: session
    } do
      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               call(session, "report_result", %{"summary" => "done", "status" => "done"})

      assert text =~ "`status` was IGNORED"
    end
  end

  describe "sessions" do
    test "only the tools the caller bound are served", %{root: root} do
      read = fn args, _ -> Files.read(root, args["path"]) end
      {:ok, session} = ToolServer.open(root: root, tools: %{"read" => read, "x" => read})
      on_exit(fn -> ToolServer.close(session) end)

      assert ToolServer.cli_names(session) == ["mcp__factory__read"]
    end

    test "two dispatches get two servers that share nothing", %{root: root, session: session} do
      {:ok, other} = ToolServer.open(root: root, tools: bound(root, nil))
      on_exit(fn -> ToolServer.close(other) end)

      call(session, "read", %{"path" => "input.txt"})

      assert other.url != session.url
      assert ToolServer.calls(other) == []
    end

    test "close stops the listener", %{root: root} do
      {:ok, session} = ToolServer.open(root: root, tools: bound(root, nil))
      ToolServer.close(session)

      assert {:error, _reason} = request(:post, session.url, "{}")
    end
  end

  describe "command line with the tool server" do
    test "built-in file tools are off; the server's tools are approved by name", %{
      session: session
    } do
      served = %{session: session, config: "C:/tmp/mcp.json"}
      request = %Request{role: "reviewer", model: "haiku", messages: []}

      {:ok, line} = ClaudeCLI.command_line(request, served: served, platform: {:unix, :linux})

      assert line =~ ~s(--tools "" )
      assert line =~ "--strict-mcp-config"
      assert line =~ ~s(--mcp-config "C:/tmp/mcp.json")
      assert line =~ ~s(--allowedTools "mcp__factory__list" "mcp__factory__read")
      refute line =~ "Read"
      refute line =~ "--settings"
    end

    test "a role with the shell keeps Bash, approved and sandboxed", %{session: session} do
      served = %{session: session, config: "C:/tmp/mcp.json"}
      request = %Request{role: "builder", model: "haiku", messages: []}

      {:ok, line} = ClaudeCLI.command_line(request, served: served, platform: {:unix, :linux})

      assert line =~ ~s(--tools "Bash" )
      assert line =~ ~s("mcp__factory__write" "Bash" )
      assert line =~ "--settings"
    end
  end

  describe "the after-the-fact audit" do
    defp stdout(tool, path) do
      [
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => tool,
                "input" => %{"file_path" => path, "path" => path, "content" => "x"}
              }
            ]
          }
        },
        %{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "done"}
      ]
      |> Enum.map_join(
        "
",
        &Jason.encode!/1
      )
    end

    test "skips the server's calls: they were judged before running", %{root: root} do
      output = %{stdout: stdout("mcp__factory__write", "../outside.txt"), stderr: ""}
      assert {:ok, %{stop_reason: :end_turn}} = ClaudeCLI.parse(output, root)
    end

    test "still catches a built-in tool writing outside the root", %{root: root} do
      output = %{stdout: stdout("Write", "../outside.txt"), stderr: ""}
      assert {:error, {:outside_confinement, ["../outside.txt"]}} = ClaudeCLI.parse(output, root)
    end
  end

  describe "Agents.Loop under the :full_agent family" do
    defmodule CapturingCLI do
      @moduledoc false
      def family, do: :full_agent

      def chat(_request, opts) do
        send(opts[:needle], {:chat_opts, opts})
        {:ok, %Response{stop_reason: :end_turn}}
      end
    end

    test "hands its bound tools to the provider, so the CLI can be served them", %{
      root: root,
      collector: collector
    } do
      tools = bound(root, collector)

      {:ok, _summary} =
        Loop.run(provider: CapturingCLI, needle: self(), tools: tools, root: root)

      assert_received {:chat_opts, opts}
      assert opts[:tools] == tools
    end
  end
end
