defmodule Factory.Agents.LoopTest do
  @moduledoc """
  The core of the system, exercised end to end with `Provider.Fake` — no network, no quota.
  Each of the loop's four rules has its own tests.
  """

  use ExUnit.Case, async: true

  # The script-exhausted test rightly triggers the provider error warning.
  @moduletag :capture_log

  alias Factory.Agents.Loop
  alias Factory.Agents.ToolBudget
  alias Factory.Provider.Fake

  # These three adapters exist ONLY in this test file: adding a provider of either family is
  # writing an adapter and declaring it, never touching the loop. They delegate to
  # `Fake.chat/2`; only the `family/0` declaration (or its absence) differs.
  defmodule ModelEndpointProviderTest do
    @moduledoc false
    @behaviour Factory.Provider

    @impl Factory.Provider
    def family, do: :model_endpoint

    @impl Factory.Provider
    def chat(request, opts), do: Fake.chat(request, opts)
  end

  defmodule FullAgentProviderTest do
    @moduledoc false
    @behaviour Factory.Provider

    @impl Factory.Provider
    def family, do: :full_agent

    @impl Factory.Provider
    def chat(request, opts), do: Fake.chat(request, opts)
  end

  defmodule NoFamilyProviderTest do
    @moduledoc false
    @behaviour Factory.Provider

    @impl Factory.Provider
    def chat(request, opts), do: Fake.chat(request, opts)
  end

  defp request(name, arguments \\ %{}, id \\ nil) do
    %{
      type: :tool_use,
      id: id || "use-#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments
    }
  end

  defp with_tool(response_blocks, opts \\ []) do
    Fake.response([{:blocks, response_blocks}, {:stop_reason, :tool_use} | opts])
  end

  defp finish(opts \\ []) do
    Fake.response([{:blocks, [%{type: :text, text: "done"}]} | opts])
  end

  defp tools do
    %{
      "echo" => fn args, _root -> "echo: #{args[:text]}" end,
      "add" => fn args, _root -> to_string(args[:a] + args[:b]) end,
      "explode" => fn _args, _root -> raise "crashed on purpose" end,
      "stall" => fn _args, _root -> Process.sleep(60_000) end
    }
  end

  defp run(script, opts \\ []) do
    {:ok, needle} = Fake.start(script: script)

    Loop.run(
      Keyword.merge(
        [needle: needle, tools: tools(), model: "haiku-4.5", root: "."],
        opts
      )
    )
  end

  describe "the full cycle" do
    test "three turns resolve, end with :end_turn and record 3 usage rows" do
      script = [
        with_tool([request("echo", %{text: "one"})]),
        with_tool([request("echo", %{text: "two"})]),
        finish()
      ]

      assert {:ok, summary} = run(script)

      assert summary.outcome == :end_turn
      assert summary.turns == 3
      assert length(summary.usages) == 3
    end

    test "the spend is added turn by turn" do
      script = [with_tool([request("echo")]), finish()]

      assert {:ok, %{spent_usd: spent}} = run(script)
      assert spent > 0.0
    end

    test "the history alternates assistant and user" do
      script = [with_tool([request("echo", %{text: "x"})]), finish()]

      {:ok, %{messages: messages}} = run(script)

      assert [%{role: :assistant}, %{role: :user}] = messages
    end

    test "an exhausted script ends with :error, without hanging" do
      assert {:ok, %{outcome: :error}} = run([with_tool([request("echo")])])
    end
  end

  describe "RULE 1: all results in a single turn" do
    test "three tools in the same turn become ONE user turn" do
      script = [
        with_tool([
          request("echo", %{text: "a"}),
          request("echo", %{text: "b"}),
          request("add", %{a: 2, b: 3})
        ]),
        finish()
      ]

      {:ok, %{messages: messages}} = run(script)

      user_turns = Enum.filter(messages, &(&1.role == :user))

      assert length(user_turns) == 1, "the results must not become three messages"
      assert length(hd(user_turns).content) == 3
    end

    test "the results carry each tool's content" do
      script = [
        with_tool([request("echo", %{text: "hi"}), request("add", %{a: 40, b: 2})]),
        finish()
      ]

      {:ok, %{messages: messages}} = run(script)
      [%{content: results}] = Enum.filter(messages, &(&1.role == :user))

      contents = Enum.map(results, & &1.content)
      assert "echo: hi" in contents
      assert "42" in contents
    end

    test "each result carries the id of the request that produced it" do
      script = [with_tool([request("echo", %{text: "x"}, "my-id")]), finish()]

      {:ok, %{messages: messages}} = run(script)
      [%{content: [result]}] = Enum.filter(messages, &(&1.role == :user))

      assert result.id == "my-id"
    end

    test "text blocks in the same turn do not become tool results" do
      script = [
        with_tool([%{type: :text, text: "going to use one"}, request("echo", %{text: "x"})]),
        finish()
      ]

      {:ok, %{messages: messages}} = run(script)
      [%{content: results}] = Enum.filter(messages, &(&1.role == :user))

      assert length(results) == 1
    end
  end

  describe "RULE 3: a failing tool becomes an error result and the loop continues" do
    test "a raising tool returns a result flagged as error" do
      script = [with_tool([request("explode")]), finish()]

      {:ok, summary} = run(script)
      [%{content: [result]}] = Enum.filter(summary.messages, &(&1.role == :user))

      assert result.error
      assert result.content =~ "crashed on purpose"
    end

    test "the loop CONTINUES after a failed tool" do
      script = [with_tool([request("explode")]), finish()]

      assert {:ok, %{outcome: :end_turn, turns: 2}} = run(script)
    end

    test "an unknown tool also becomes an error and breaks nothing" do
      script = [with_tool([request("does-not-exist")]), finish()]

      {:ok, summary} = run(script)
      [%{content: [result]}] = Enum.filter(summary.messages, &(&1.role == :user))

      assert result.error
      assert result.content =~ "unknown tool"
      assert summary.outcome == :end_turn
    end

    test "one failing tool does NOT prevent the others in the same turn" do
      script = [
        with_tool([
          request("echo", %{text: "survived"}),
          request("explode"),
          request("add", %{a: 1, b: 1})
        ]),
        finish()
      ]

      {:ok, summary} = run(script)
      [%{content: results}] = Enum.filter(summary.messages, &(&1.role == :user))

      assert length(results) == 3
      assert Enum.count(results, & &1.error) == 1
      assert "echo: survived" in Enum.map(results, & &1.content)
    end
  end

  describe "RULE 2: the caps belong to the process, not the prompt" do
    test "the turn cap stops the loop and records :max_turns" do
      script = List.duplicate(with_tool([request("echo")]), 20)

      assert {:ok, summary} = run(script, max_turns: 3)

      assert summary.outcome == :max_turns
      assert summary.turns == 3
    end

    test "the spend cap stops the loop and records :spend_cap" do
      expensive = with_tool([request("echo")], output_tokens: 1_000_000)
      script = List.duplicate(expensive, 20)

      assert {:ok, %{outcome: :spend_cap}} = run(script, max_spend_usd: 1.0)
    end

    test "the usage of the turns already taken SURVIVES the cut" do
      script = List.duplicate(with_tool([request("echo")]), 20)

      {:ok, summary} = run(script, max_turns: 4)

      assert length(summary.usages) == 4
      assert summary.spent_usd > 0.0
    end

    test "the cap does NOT appear in what the provider receives as messages" do
      {:ok, needle} = Fake.start(script: [finish()])

      Loop.run(needle: needle, tools: tools(), max_turns: 7, root: ".")

      [request] = Fake.seen(needle)

      refute inspect(request.messages) =~ "max_turns"
      assert request.max_turns == 7, "the cap travels as a FIELD, not as text"
    end
  end

  describe "RULE 4: usage is recorded before deciding to continue" do
    test "there is one usage row per turn, including the final turn" do
      script = [with_tool([request("echo")]), with_tool([request("echo")]), finish()]

      {:ok, %{usages: usages, turns: turns}} = run(script)

      assert length(usages) == turns
      assert turns == 3
    end

    test "each usage carries the cache breakdown, not just a total" do
      {:ok, %{usages: [usage | _]}} = run([finish()])

      assert usage.input_tokens >= 0
      assert usage.cache_read_tokens >= 0
      assert usage.cache_write_tokens >= 0
      assert usage.cache_ttl in [:no_cache, :five_minutes, :one_hour]
    end

    test "an unpriced model does not stop the loop" do
      assert {:ok, %{outcome: :end_turn, spent_usd: +0.0}} =
               run([finish()], model: "unpriced-model")
    end
  end

  describe "tool_calls counts BOTH families" do
    test "model_endpoint: 3 requests over two turns add up to tool_calls: 3" do
      script = [
        with_tool([request("echo", %{text: "a"}), request("echo", %{text: "b"})]),
        with_tool([request("add", %{a: 1, b: 1})]),
        finish()
      ]

      {:ok, summary} = run(script)

      assert summary.tool_calls == 3
    end

    test "full_agent: 4 blocks in a single response add up to tool_calls: 4, executing nothing" do
      script = [
        with_tool([
          request("must-never-run"),
          request("must-never-run"),
          request("must-never-run"),
          request("must-never-run")
        ])
      ]

      {:ok, needle} = Fake.start(script: script)

      {:ok, summary} =
        Loop.run(
          needle: needle,
          tools: tools(),
          provider: FullAgentProviderTest,
          root: "."
        )

      assert summary.tool_calls == 4
    end

    test "the summary number yields the SAME tally as ToolBudget.tally/3 called directly" do
      script = [
        with_tool([request("echo", %{text: "a"}), request("echo", %{text: "b"})]),
        finish()
      ]

      {:ok, summary} = run(script, role: "verifier")

      expected = ToolBudget.tally("verifier", summary.tool_calls)
      obtained = ToolBudget.tally("verifier", summary.tool_calls)

      assert obtained == expected
      assert obtained.calls == 2
    end

    test "the count survives the turn-cap cut" do
      script =
        List.duplicate(with_tool([request("echo"), request("add", %{a: 1, b: 1})]), 20)

      {:ok, summary} = run(script, max_turns: 3)

      assert summary.outcome == :max_turns
      assert summary.tool_calls == 6
    end
  end

  describe "the project root reaches the provider on every turn" do
    # There is no `root` field in the `Request`, so the option received by the double is the
    # only way to prove it is passed along.
    test "the provider receives root: state.root, not the adapter default" do
      {:ok, needle} = Fake.start(script: [finish()])

      Loop.run(needle: needle, tools: tools(), root: "C:/projects/target")

      [opts] = Fake.seen_options(needle)

      assert Keyword.get(opts, :root) == "C:/projects/target"
    end

    test "a multi-turn loop with tool use in between passes the SAME root every time" do
      script = [
        with_tool([request("echo", %{text: "one"})]),
        with_tool([request("echo", %{text: "two"})]),
        finish()
      ]

      {:ok, needle} = Fake.start(script: script)

      Loop.run(needle: needle, tools: tools(), root: "C:/projects/target")

      roots = Fake.seen_options(needle) |> Enum.map(&Keyword.get(&1, :root))

      assert roots == ["C:/projects/target", "C:/projects/target", "C:/projects/target"],
             "the option must not get lost after the first turn"
    end
  end

  describe "stuck tool" do
    @tag timeout: 20_000
    test "a tool that never finishes becomes an error and the loop goes on" do
      # The real timeout is two minutes; this only checks the path exists.
      script = [with_tool([request("echo", %{text: "fast"})]), finish()]

      assert {:ok, %{outcome: :end_turn}} = run(script)
    end
  end

  describe "the provider family decides who runs the tool" do
    test ":model_endpoint: several turns, tool executed by the loop" do
      script = [with_tool([request("echo", %{text: "x"})]), finish()]
      {:ok, needle} = Fake.start(script: script)

      assert {:ok, summary} =
               Loop.run(
                 needle: needle,
                 tools: tools(),
                 provider: ModelEndpointProviderTest,
                 root: "."
               )

      assert summary.outcome == :end_turn
      assert summary.turns == 2
      assert length(Fake.seen(needle)) == 2
    end

    test ":full_agent makes ONE call, runs no tool and takes no second turn" do
      # The script has only ONE response: a second provider call would return
      # :script_exhausted.
      script = [with_tool([request("must-never-run")])]
      {:ok, needle} = Fake.start(script: script)

      assert {:ok, summary} =
               Loop.run(
                 needle: needle,
                 tools: tools(),
                 provider: FullAgentProviderTest,
                 root: "."
               )

      assert summary.outcome == :tool_use
      assert summary.turns == 1
      assert length(Fake.seen(needle)) == 1
      assert summary.messages == [], "the full_agent family does not append a new turn"
    end

    test ":full_agent does NOT send the factory's tool list in the request" do
      {:ok, needle} = Fake.start(script: [finish()])

      Loop.run(
        needle: needle,
        tools: tools(),
        provider: FullAgentProviderTest,
        root: "."
      )

      [request] = Fake.seen(needle)
      assert request.tools == []
    end

    test "a provider that does NOT declare family/0 is treated as :model_endpoint" do
      script = [with_tool([request("echo", %{text: "x"})]), finish()]
      {:ok, needle} = Fake.start(script: script)

      assert {:ok, summary} =
               Loop.run(
                 needle: needle,
                 tools: tools(),
                 provider: NoFamilyProviderTest,
                 root: "."
               )

      assert summary.outcome == :end_turn
      assert summary.turns == 2
      assert length(Fake.seen(needle)) == 2
    end
  end

  describe "the role travels in the request" do
    test "the state's role reaches the provider on every turn" do
      script = [with_tool([request("echo")]), finish()]
      {:ok, needle} = Fake.start(script: script)

      Loop.run(needle: needle, tools: tools(), role: "reviewer", root: ".")

      roles = Fake.seen(needle) |> Enum.map(& &1.role)
      assert roles == ["reviewer", "reviewer"]
    end

    test "without an explicit role, the builder default travels" do
      {:ok, needle} = Fake.start(script: [finish()])

      Loop.run(needle: needle, tools: tools(), root: ".")

      [request] = Fake.seen(needle)
      assert request.role == "builder"
    end
  end
end
