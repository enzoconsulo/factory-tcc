defmodule Factory.Provider.MessagesAPITest do
  @moduledoc """
  Tests the Messages API provider without network access: body building is public so the
  cache pitfalls can be proven offline, and the HTTP part uses `Req.Test`.
  """

  use ExUnit.Case, async: true

  alias Factory.Provider.Block
  alias Factory.Provider.MessagesAPI
  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage

  # `Factory.Provider.Block` (the request block), not `Factory.Prompt.Block`.
  defp prefix(texts) do
    Enum.map(texts, &%Block{text: &1, cache_breakpoint: true})
  end

  defp request(attrs \\ %{}) do
    struct(
      %Request{
        model: "opus-5",
        prefix: prefix(["role doctrine", "# project MAP"]),
        messages: [%{role: :user, content: "do T-019"}],
        tools: ["read", "write"]
      },
      attrs
    )
  end

  defp long_messages(count) do
    Enum.map(1..count, fn n ->
      %{role: if(rem(n, 2) == 0, do: :assistant, else: :user), content: "turn #{n}"}
    end)
  end

  defp cache_breakpoints(body) do
    [body.tools, body.system, body.messages]
    |> List.flatten()
    |> Enum.map(&marked_content/1)
    |> List.flatten()
    |> Enum.count(& &1)
  end

  defp marked_content(%{content: content}) when is_list(content) do
    Enum.map(content, &Map.has_key?(&1, :cache_control))
  end

  defp marked_content(item) when is_map(item), do: [Map.has_key?(item, :cache_control)]
  defp marked_content(_), do: [false]

  describe "body order imposed by the API" do
    test "the body has tools, system and messages" do
      body = MessagesAPI.build(request())

      assert Map.has_key?(body, :tools)
      assert Map.has_key?(body, :system)
      assert Map.has_key?(body, :messages)
      assert body.model == "opus-5"
    end

    test "each band lands in the right field" do
      # The order is defined over fields, not over key positions in the serialised JSON.
      body = MessagesAPI.build(request())

      assert Enum.map(body.tools, & &1.name) == ["read", "write"]
      assert Enum.map(body.system, & &1.text) == ["role doctrine", "# project MAP"]
      assert Enum.map(body.messages, & &1.role) == ["user"]

      assert Map.has_key?(List.last(body.tools), :cache_control)
      assert Map.has_key?(List.last(body.system), :cache_control)
      refute Map.has_key?(List.last(body.messages), :cache_control)
    end

    test "tools take the API format" do
      body = MessagesAPI.build(request())

      assert [%{name: "read"}, %{name: "write", cache_control: _}] = body.tools
    end

    test "the prefix becomes system blocks" do
      body = MessagesAPI.build(request())

      assert [%{type: "text", text: "role doctrine"}, %{text: "# project MAP"}] =
               body.system
    end
  end

  describe "cache breakpoints: at most 4, 1h TTL on stable bands" do
    test "the LAST block of each stable band gets the breakpoint" do
      body = MessagesAPI.build(request())

      refute Map.has_key?(List.first(body.system), :cache_control)
      assert %{cache_control: %{ttl: "1h"}} = List.last(body.system)

      refute Map.has_key?(List.first(body.tools), :cache_control)
      assert %{cache_control: %{ttl: "1h"}} = List.last(body.tools)
    end

    test "the TTL is 1 hour, not 5 minutes" do
      body = MessagesAPI.build(request())

      assert List.last(body.system).cache_control.ttl == "1h"
      assert List.last(body.tools).cache_control.ttl == "1h"
    end

    test "never exceeds 4 breakpoints, even with a huge history" do
      body = MessagesAPI.build(request(%{messages: long_messages(200)}))

      assert cache_breakpoints(body) <= 4
    end

    test "an empty prefix yields no system block and no breakpoint" do
      body = MessagesAPI.build(request(%{prefix: [], tools: []}))

      assert body.system == []
      assert body.tools == []
    end
  end

  describe "pitfall 1: the 20-block window" do
    test "a history longer than the window gets an INTERMEDIATE breakpoint" do
      short = MessagesAPI.build(request(%{messages: long_messages(5)}))
      long = MessagesAPI.build(request(%{messages: long_messages(60)}))

      marked_in_short = Enum.count(short.messages, &(marked_content(&1) == [true]))
      marked_in_long = Enum.count(long.messages, &(marked_content(&1) == [true]))

      assert marked_in_short == 0, "a short history needs no intermediate breakpoint"
      assert marked_in_long > 0, "a long history NEEDS an intermediate breakpoint"
    end

    test "the window is smaller than the API's 20" do
      assert MessagesAPI.block_window() < 20
    end

    test "intermediates respect the cap left after the stable bands" do
      body = MessagesAPI.build(request(%{messages: long_messages(300)}))

      intermediates = Enum.count(body.messages, &(marked_content(&1) == [true]))

      assert intermediates <= 2
      assert cache_breakpoints(body) <= 4
    end
  end

  describe "pitfall 3: system message mid-conversation" do
    test "the per-task instruction goes into `messages`, NOT the top-level system" do
      body = MessagesAPI.build(request(), task_instruction: "focus on criterion 2")

      assert Enum.any?(body.messages, &(&1.role == "system"))
      assert Enum.any?(body.messages, &(&1[:content] == "focus on criterion 2"))

      refute Enum.any?(body.system, &(&1.text =~ "criterion 2"))
    end

    test "without a per-task instruction, no system message is inserted" do
      body = MessagesAPI.build(request())

      refute Enum.any?(body.messages, &(&1.role == "system"))
    end

    test "the top-level system is IDENTICAL with and without a per-task instruction" do
      without = MessagesAPI.build(request())
      with_instruction = MessagesAPI.build(request(), task_instruction: "something else")

      assert without.system == with_instruction.system
      assert without.tools == with_instruction.tools
    end
  end

  describe "byte-for-byte stability" do
    test "building the same request twice yields the SAME body" do
      assert MessagesAPI.build(request()) == MessagesAPI.build(request())
    end

    test "the serialised JSON is identical too" do
      one = request() |> MessagesAPI.build() |> Jason.encode!()
      other = request() |> MessagesAPI.build() |> Jason.encode!()

      assert one == other
    end
  end

  describe "response translation, with an HTTP stub" do
    test "a text response becomes Response and Usage" do
      body = %{
        "content" => [%{"type" => "text", "text" => "done"}],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 50,
          "cache_creation_input_tokens" => 3_000,
          "cache_read_input_tokens" => 70_000,
          "output_tokens" => 120
        }
      }

      stub = fn conn -> Req.Test.json(conn, body) end

      assert {:ok, %Response{} = response} =
               MessagesAPI.chat(request(), plug: stub)

      assert [%{type: :text, text: "done"}] = response.blocks
      assert response.stop_reason == :end_turn
      assert %Usage{cache_read_tokens: 70_000, cache_ttl: :one_hour} = response.usage
    end

    test "the Usage TTL is :one_hour because we asked for it" do
      stub = fn conn -> Req.Test.json(conn, %{"content" => [], "usage" => %{}}) end

      {:ok, response} = MessagesAPI.chat(request(), plug: stub)
      assert response.usage.cache_ttl == :one_hour
    end

    test "a tool request becomes :tool_use" do
      body = %{
        "content" => [
          %{"type" => "tool_use", "id" => "u1", "name" => "read", "input" => %{"c" => "x.ex"}}
        ],
        "stop_reason" => "tool_use",
        "usage" => %{}
      }

      stub = fn conn -> Req.Test.json(conn, body) end

      {:ok, response} = MessagesAPI.chat(request(), plug: stub)

      assert response.stop_reason == :tool_use
      assert [%{type: :tool_use, name: "read"}] = response.blocks
    end

    test "429 becomes {:error, {:quota, reopens_at}}" do
      body = %{"error" => %{"resets_at" => "2026-08-29T02:00:00Z"}}
      stub = fn conn -> conn |> Plug.Conn.put_status(429) |> Req.Test.json(body) end

      assert {:error, {:quota, reopens_at}} = MessagesAPI.chat(request(), plug: stub)
      assert reopens_at.hour == 2
    end

    test "another HTTP error comes back named, with the status" do
      stub = fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "x"}) end

      assert {:error, {:http, 500, _}} = MessagesAPI.chat(request(), plug: stub)
    end
  end

  describe "credential and contract" do
    test "implements the Factory.Provider behaviour" do
      behaviours =
        MessagesAPI.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Factory.Provider in behaviours
    end

    test "this is the ONLY production module that reads ANTHROPIC_API_KEY" do
      # Docs and comments are ignored: other modules may mention the variable in prose.
      without_prose = fn file ->
        file
        |> File.read!()
        |> String.replace(
          ~r/@(module)?doc\s+"""
.*?"""/s,
          ""
        )
        |> String.replace(~r/^\s*#.*$/m, "")
      end

      readers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(without_prose.(&1) =~ "ANTHROPIC_API_KEY"))

      assert readers == ["lib/factory/provider/messages_api.ex"]
    end

    test "no credential is read during the suite" do
      assert System.get_env("ANTHROPIC_API_KEY") == nil

      stub = fn conn -> Req.Test.json(conn, %{"content" => [], "usage" => %{}}) end
      assert {:ok, _} = MessagesAPI.chat(request(), plug: stub)
    end

    test "the module doc states that THIS provider costs real money" do
      source = File.read!("lib/factory/provider/messages_api.ex")

      assert source =~ "costs real money"
      assert source =~ "cache_read_input_tokens"
    end
  end
end
