defmodule Factory.Provider.ClaudeCLITest do
  @moduledoc """
  The default provider, exercised without network and without quota: the executable comes
  from configuration and points at fake scripts that print known JSON events.
  """

  use ExUnit.Case, async: true

  # `parse/1` warns when the `result` has no TTL breakdown, which most fixtures here lack.
  @moduletag :capture_log

  alias Factory.Agents.Loop
  alias Factory.Cost.Pricing
  alias Factory.Provider.ClaudeCLI
  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage
  alias Factory.Tools.Catalog

  # Events in the CLI format: one JSON line per event.
  defp text_event(text) do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp tool_event(name, input, id \\ "use-1") do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
      }
    })
  end

  defp result_event(opts \\ []) do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => Keyword.get(opts, :subtype, "success"),
      "is_error" => Keyword.get(opts, :error, false),
      "duration_ms" => 1234,
      "usage" => %{
        "input_tokens" => Keyword.get(opts, :input, 120),
        "cache_creation_input_tokens" => Keyword.get(opts, :write, 4_000),
        "cache_read_input_tokens" => Keyword.get(opts, :read, 90_000),
        "output_tokens" => Keyword.get(opts, :output, 300)
      }
    })
  end

  defp output(lines, stderr \\ "") do
    %{stdout: Enum.join(lines, "\n"), stderr: stderr}
  end

  defp line!(request) do
    {:ok, line} = ClaudeCLI.command_line(request)
    line
  end

  describe "event translation into the behaviour vocabulary" do
    test "a text event becomes a text block" do
      assert {:ok, %Response{blocks: [block]}} =
               ClaudeCLI.parse(output([text_event("hello"), result_event()]))

      assert block == %{type: :text, text: "hello"}
    end

    test "a tool use event becomes a tool use block" do
      lines = [tool_event("read", %{"path" => "lib/x.ex"}), result_event()]

      assert {:ok, %Response{blocks: [block]}} = ClaudeCLI.parse(output(lines))

      assert block.type == :tool_use
      assert block.name == "read"
      assert block.arguments == %{"path" => "lib/x.ex"}
      assert block.id == "use-1"
    end

    test "the CLI vocabulary stops here: no tool_use leaks" do
      lines = [tool_event("read", %{}), result_event()]
      {:ok, response} = ClaudeCLI.parse(output(lines))

      # In English the internal names (`:tool_use`, `Usage.input_tokens`) coincide with the
      # CLI's, so what must not leak is the CLI's raw JSON vocabulary: string keys and types.
      refute inspect(response) =~ ~s("tool_use")
      refute inspect(response) =~ ~s("input")
      refute inspect(response) =~ ~s("input_tokens")
      refute inspect(response) =~ "cache_creation_input_tokens"
    end

    test "several events become several blocks, in order" do
      lines = [
        text_event("reading"),
        tool_event("read", %{}, "a"),
        tool_event("search", %{}, "b"),
        result_event()
      ]

      {:ok, %Response{blocks: blocks}} = ClaudeCLI.parse(output(lines))

      assert length(blocks) == 3
      assert Enum.map(blocks, & &1.type) == [:text, :tool_use, :tool_use]
    end

    test "a block of unknown type breaks nothing" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "new_thing", "x" => 1}]}
        })

      assert {:ok, %Response{blocks: [%{type: :unknown}]}} =
               ClaudeCLI.parse(output([line, result_event()]))
    end

    test "a line that is not JSON is ignored" do
      lines = ["this is not json", text_event("ok"), result_event()]

      assert {:ok, %Response{blocks: [%{text: "ok"}]}} = ClaudeCLI.parse(output(lines))
    end

    test "output with no event returns a named error" do
      assert {:error, :unreadable_output} = ClaudeCLI.parse(output(["junk", "more junk"]))
    end
  end

  describe "the thinking block has its own type" do
    test "thinking becomes :thinking, not :unknown" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "thinking", "thinking" => "the request is simple", "signature" => "abc"}
            ]
          }
        })

      assert {:ok, %Response{blocks: [block]}} = ClaudeCLI.parse(output([line]))
      assert block.type == :thinking
      assert block.text == "the request is simple"
    end

    test "the signature is kept, since it allows sending the block back to the model" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "thinking", "thinking" => "x", "signature" => "sig-123"}]
          }
        })

      assert {:ok, %Response{blocks: [%{signature: "sig-123"}]}} =
               ClaudeCLI.parse(output([line]))
    end

    test "a REALLY unknown type still becomes :unknown" do
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "future_new_thing", "x" => 1}]}
        })

      assert {:ok, %Response{blocks: [%{type: :unknown}]}} =
               ClaudeCLI.parse(output([line]))
    end
  end

  describe "stop reason" do
    test "a tool use mid-session, with the session finished, becomes :end_turn" do
      # The stop reason must come from the terminal event, not from any event in the stream.
      lines = [tool_event("read", %{}), result_event()]

      assert {:ok, %Response{stop_reason: :end_turn}} =
               ClaudeCLI.parse(output(lines))
    end

    test "text only becomes :end_turn" do
      assert {:ok, %Response{stop_reason: :end_turn}} =
               ClaudeCLI.parse(output([text_event("done"), result_event()]))
    end

    test "the CLI turn cap becomes :max_turns, not :max_tokens" do
      lines = [text_event("..."), result_event(subtype: "error_max_turns")]

      assert {:ok, %Response{stop_reason: :max_turns}} =
               ClaudeCLI.parse(output(lines))
    end

    test "a CLI error becomes :refusal" do
      lines = [text_event("I cannot"), result_event(error: true)]

      assert {:ok, %Response{stop_reason: :refusal}} = ClaudeCLI.parse(output(lines))
    end

    test "no possible input produces :tool_use" do
      variations = [
        [text_event("hi"), result_event()],
        [tool_event("read", %{}), result_event()],
        [
          tool_event("read", %{}),
          tool_event("search", %{}, "b"),
          result_event()
        ],
        [text_event("hi")],
        [tool_event("read", %{})],
        [text_event("..."), result_event(subtype: "error_max_turns")],
        [text_event("I cannot"), result_event(error: true)]
      ]

      for lines <- variations do
        assert {:ok, %Response{stop_reason: reason}} = ClaudeCLI.parse(output(lines))

        # Asserted by inclusion: comparing against :tool_use would be an always-false type
        # warning, which is the static proof the guarantee holds.
        assert reason in [:end_turn, :max_turns, :refusal],
               "lines #{inspect(lines)} produced an unexpected reason: #{inspect(reason)}"
      end
    end
  end

  describe "proof with a REAL stream" do
    test "sample with a tool_use mid-session and a finished session yields :end_turn, keeping the blocks" do
      stdout = File.read!("priv/probes/samples/session-with-tool.jsonl")

      assert {:ok, %Response{stop_reason: :end_turn} = response} =
               ClaudeCLI.parse(%{stdout: stdout, stderr: ""})

      assert Enum.any?(response.blocks, &(&1.type == :tool_use))
    end
  end

  describe "accounting" do
    test "the result event becomes Usage, with the cache breakdown" do
      lines = [
        text_event("x"),
        result_event(input: 100, write: 5_000, read: 80_000, output: 250)
      ]

      {:ok, %Response{usage: usage}} = ClaudeCLI.parse(output(lines))

      assert %Usage{} = usage
      assert usage.input_tokens == 100
      assert usage.cache_write_tokens == 5_000
      assert usage.cache_read_tokens == 80_000
      assert usage.output_tokens == 250
      assert usage.duration_ms == 1234
    end

    test "a result WITHOUT `usage.cache_creation` stays :no_cache" do
      lines = [text_event("x"), result_event(read: 90_000)]
      {:ok, %Response{usage: usage}} = ClaudeCLI.parse(output(lines))

      assert usage.cache_ttl == :no_cache
      assert usage.cache_read_tokens > 0
    end

    test "without a result event, usage is zero, not invented" do
      {:ok, %Response{usage: usage}} = ClaudeCLI.parse(output([text_event("x")]))

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
    end
  end

  # REAL `claude` streams: only the `assistant` and `result` lines, copied unedited.
  #
  # haiku (`claude-haiku-4-5-20251001`): 1 turn, short prompt, 4116 tokens written to the 1h
  # cache.
  @real_haiku_stream ~S"""
  {"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","id":"msg_011CfcDegYwkvctXzmstz2hY","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"EssDCtABCBIYAipAHTqSDoQtAIiIJnSvtjR+gvVGjoLT/7y2325wqh7eutOvk+CAw5HQnzmnUIFf3//BlLQmwABxi1pXF9ED/UBgZTIZY2xhdWRlLWhhaWt1LTQtNS0yMDI1MTAwMTgAQgh0aGlua2luZ1okMDNjNmZiNjgtNGFiOS00MjQ2LWI0NTEtYjU5Y2Q1ODdlZDg2chDFVo/z6akVqMy9E4asARTiiAEBmgEbChljbGF1ZGUtaGFpa3UtNC01LTIwMjUxMDAxqAH+nfvVBrABAhIMNBCpDO02NbB9aut+Ggw1SY3x5FPO7wYH614iMMxIv7X3QvZ5Ohep21Tf+T0ejM+P78ol/InBnwFHXE90Y3x61AWtaYmV3hvPQptBNCqnAYLfY55HZOdGt5R9XSEBZ8Xv84kIVr3krzWF5EAp7cFiGeI1GJmReuFKP5fEoI32yXe3N6nsZOeewXZ0EuX9A7gyIJLu7FFWUcW9VrgtfTiBgYEQ1q6Km/LYYBAuardgKRKshbDvWj+vdqIbMf+K7JQFClkIpcYZqg2jWNhiiEpmVlKG1EAJkjNKkyo2MNtkYBmJ4nypzN8X3SL3ZasYqPeblgcpOUkZGAE="}],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":9,"cache_creation_input_tokens":4116,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":4116},"output_tokens":3,"service_tier":"standard","inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"60cb1a63-3c90-5a7d-9d0e-2e259ed13b02","uuid":"a5b06fd3-e37f-4b81-9ff2-17275c444ae1","timestamp":"2026-10-01T21:22:06.734Z","request_id":"req_011CfcDegHpbfcnXKuhxqzDZ","thinking_duration_ms":415}
  {"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","id":"msg_011CfcDegYwkvctXzmstz2hY","type":"message","role":"assistant","content":[{"type":"text","text":"Hey! 👋 What can I help you with today?"}],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":9,"cache_creation_input_tokens":4116,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":4116},"output_tokens":3,"service_tier":"standard","inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"60cb1a63-3c90-5a7d-9d0e-2e259ed13b02","uuid":"3c127919-49f3-4202-b0b7-5fc8d4052b09","timestamp":"2026-10-01T21:22:06.880Z","request_id":"req_011CfcDegHpbfcnXKuhxqzDZ"}
  {"duration_api_ms":934,"stop_reason":"end_turn","session_id":"60cb1a63-3c90-5a7d-9d0e-2e259ed13b02","total_cost_usd":0.008546,"usage":{"input_tokens":9,"cache_creation_input_tokens":4116,"cache_read_input_tokens":0,"output_tokens":61,"output_tokens_details":{"thinking_tokens":41},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":4116,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":9,"output_tokens":61,"cache_read_input_tokens":0,"cache_creation_input_tokens":4116,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":4116},"type":"message"}],"speed":"standard","fallback_credit":null},"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":9,"outputTokens":61,"cacheReadInputTokens":0,"cacheCreationInputTokens":4116,"webSearchRequests":0,"costUSD":0.008546,"contextWindow":200000,"maxOutputTokens":32000,"thinkingTokens":41,"canonicalModel":"claude-haiku-4-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Hey! 👋 What can I help you with today?","ttft_ms":813,"type":"result","duration_ms":1018,"uuid":"60571196-fe69-462c-b3ad-f7874b3192cd","ttft_stream_ms":397,"time_to_request_ms":73,"time_to_request_phases_ms":{"other":20,"system_prompt":8,"resume_other":1,"process_user_input":1,"input_attachments":6,"input_hooks":2,"transcript_persist":11,"tool_pool_refresh":1,"init_message":4,"engine_pickup":1,"autocompact":1,"query_setup":0,"model_gates":1,"tool_schema_build":2,"message_normalization":1,"client_creation":4,"request_build":9},"turn_start_resume_kind":"none","process_turn_index":0,"time_to_request_loop_lag_ms":22,"time_to_request_cpu_ms":100,"time_to_request_major_faults":0,"first_content_frame_ms":398,"time_to_request_from_spawn_ms":827835,"warm_spare_claimed":false,"time_origin_ms":1790889724588.591,"queued_turn_count":0,"result_index":0}
  """

  # sonnet: `--model claude-sonnet-5-5 --max-turns 1 --tools ""`, 1082 written to the 1h
  # cache and 1395 read.
  @real_sonnet_stream ~S"""
  {"type":"assistant","message":{"model":"claude-sonnet-5-5","id":"msg_011CfcF3ni3WAA87QChgwAqt","type":"message","role":"assistant","content":[{"type":"text","text":"pronto"}],"container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":1082,"cache_read_input_tokens":1395,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1082},"output_tokens":5,"service_tier":"standard","inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"60cb1a63-3c90-5a7d-9d0e-2e259ed13b02","uuid":"5f80f4f8-6765-4364-874d-8b5f332192eb","timestamp":"2026-10-01T21:40:27.178Z","request_id":"req_011CfcF3nUuf6uEbEuckJh83"}
  {"duration_api_ms":916,"stop_reason":"end_turn","session_id":"60cb1a63-3c90-5a7d-9d0e-2e259ed13b02","total_cost_usd":0.004661,"usage":{"input_tokens":2,"cache_creation_input_tokens":1082,"cache_read_input_tokens":1395,"output_tokens":5,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":1082,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":2,"output_tokens":5,"cache_read_input_tokens":1395,"cache_creation_input_tokens":1082,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1082},"type":"message"}],"speed":"standard","fallback_credit":null},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":2,"outputTokens":5,"cacheReadInputTokens":1395,"cacheCreationInputTokens":1082,"webSearchRequests":0,"costUSD":0.004661,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":0,"canonicalModel":"claude-sonnet-5-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"pronto","ttft_ms":975,"type":"result","duration_ms":1527,"uuid":"cd93c004-c3b9-4f9f-9fbf-b31de49f7dc7","ttft_stream_ms":973,"time_to_request_ms":78,"time_to_request_phases_ms":{"other":24,"system_prompt":13,"resume_other":0,"process_user_input":2,"input_attachments":7,"input_hooks":2,"transcript_persist":4,"tool_pool_refresh":1,"init_message":5,"engine_pickup":1,"autocompact":1,"query_setup":1,"model_gates":0,"tool_schema_build":2,"message_normalization":2,"client_creation":5,"request_build":8},"turn_start_resume_kind":"none","process_turn_index":0,"time_to_request_loop_lag_ms":28,"time_to_request_cpu_ms":107,"time_to_request_major_faults":0,"first_content_frame_ms":974,"time_to_request_from_spawn_ms":1928123,"warm_spare_claimed":false,"time_origin_ms":1790890825138.9204,"queued_turn_count":0,"result_index":0}
  """

  # What the CLI itself says the session cost: `total_cost_usd` of the `result` event.
  defp reported_cost(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["type"] == "result"))
    |> Map.fetch!("total_cost_usd")
  end

  # What the factory computes along the real dispatch path: `parse` -> `Usage` ->
  # `Pricing.estimate`.
  defp computed_cost(stdout, model) do
    {:ok, %Response{usage: usage}} = ClaudeCLI.parse(%{stdout: stdout, stderr: ""})
    {:ok, %{total_usd: total}} = Pricing.estimate(model, usage)
    total
  end

  defp deviation(computed, reported), do: abs(computed - reported) / reported

  # Replaces the TTL breakdown of the real haiku `result`, keeping the rest intact.
  defp haiku_with_ttl(five_minutes, one_hour) do
    [assistant_1, assistant_2, result] = String.split(@real_haiku_stream, "\n", trim: true)

    result =
      result
      |> Jason.decode!()
      |> put_in(["usage", "cache_creation"], %{
        "ephemeral_5m_input_tokens" => five_minutes,
        "ephemeral_1h_input_tokens" => one_hour
      })
      |> put_in(["usage", "cache_creation_input_tokens"], five_minutes + one_hour)
      |> put_in(
        ["modelUsage", "claude-haiku-4-5-20251001", "cacheCreationInputTokens"],
        five_minutes + one_hour
      )
      |> Jason.encode!()

    Enum.join([assistant_1, assistant_2, result], "\n")
  end

  describe "the cost of a REAL dispatch matches the CLI's own total_cost_usd" do
    for model <- ["haiku-4.5", "claude-haiku-4-5-20251001"] do
      @model model
      test "haiku (#{model}), 1h cache write: within 1% of total_cost_usd" do
        computed = computed_cost(@real_haiku_stream, @model)
        reported = reported_cost(@real_haiku_stream)

        assert deviation(computed, reported) < 0.01,
               "computed #{computed} vs reported by the CLI #{reported}"
      end
    end

    for model <- ["sonnet-5", "claude-sonnet-5-5"] do
      @model model
      test "sonnet (#{model}), 1h write + read: within 1% of total_cost_usd" do
        computed = computed_cost(@real_sonnet_stream, @model)
        reported = reported_cost(@real_sonnet_stream)

        assert deviation(computed, reported) < 0.01,
               "computed #{computed} vs reported by the CLI #{reported}"
      end
    end

    test "REAL session with a tool and several turns: within 1% too" do
      # `usage` counts only the main loop; `modelUsage` also counts the CLI's auxiliary calls.
      stdout = File.read!("priv/probes/samples/session-with-tool.jsonl")

      computed = computed_cost(stdout, "haiku-4.5")
      reported = reported_cost(stdout)

      assert deviation(computed, reported) < 0.01,
             "computed #{computed} vs reported by the CLI #{reported}"
    end

    test "the TTL comes from usage.cache_creation: 1h only becomes :one_hour, with the result tokens" do
      {:ok, %Response{usage: usage}} =
        ClaudeCLI.parse(%{stdout: @real_haiku_stream, stderr: ""})

      assert usage.cache_ttl == :one_hour
      assert usage.cache_write_tokens == 4_116
      assert usage.input_tokens == 9
      # The assistant lines' usage is partial (output 3); the result's number (61) counts.
      assert usage.output_tokens == 61
    end

    test "5 minutes only becomes :five_minutes" do
      {:ok, %Response{usage: usage}} =
        ClaudeCLI.parse(%{stdout: haiku_with_ttl(4_116, 0), stderr: ""})

      assert usage.cache_ttl == :five_minutes
      assert usage.cache_write_tokens == 4_116
    end

    test "BOTH TTLs in one dispatch: charged never below the exact cost, with a warning" do
      five_minutes = 1_000
      one_hour = 3_116
      stdout = haiku_with_ttl(five_minutes, one_hour)

      {computed, log} =
        ExUnit.CaptureLog.with_log(fn -> computed_cost(stdout, "haiku-4.5") end)

      # haiku: input 1/Mtok -> 5m at 1.25x and 1h at 2.0x; input 9 and output 61 from the stream.
      exact = (9 * 1.0 + five_minutes * 1.25 + one_hour * 2.0 + 61 * 5.0) / 1_000_000

      assert computed >= exact
      assert log =~ "both cache TTLs"
    end
  end

  describe "QUOTA HIT" do
    test "a structured limit event becomes {:error, {:quota, reopens_at}}" do
      line =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "usage_limit",
          "resetsAt" => "2026-08-28T21:00:00Z"
        })

      assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(output([line]))
      assert %DateTime{} = reopens_at
      assert reopens_at.hour == 21
    end

    test "a unix time is recognised too" do
      line =
        Jason.encode!(%{"type" => "usage_limit", "resets_at" => 1_787_000_000})

      assert {:error, {:quota, %DateTime{}}} = ClaudeCLI.parse(output([line]))
    end

    test "a TEXT message is recognised too, with the time extracted" do
      text = "Claude usage limit reached. Your limit will reset at 2026-08-28T22:30:00Z"

      assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(output([], text))
      assert reopens_at.hour == 22
      assert reopens_at.minute == 30
    end

    test "a limit without a time is still a limit" do
      assert {:error, {:quota, nil}} = ClaudeCLI.parse(output([], "usage limit reached"))
    end

    test "the STRUCTURED event takes precedence over the text" do
      line =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "usage_limit",
          "resetsAt" => "2026-08-28T23:00:00Z"
        })

      assert {:error, {:quota, reopens_at}} =
               ClaudeCLI.parse(output([line], "rate limit at some point"))

      assert reopens_at.hour == 23
    end

    test "a normal response is NOT mistaken for quota" do
      lines = [text_event("all good"), result_event()]
      assert {:ok, %Response{}} = ClaudeCLI.parse(output(lines))
    end

    # The real event format: no `subtype`, and `type: "rate_limit_event"`.
    defp quota_event(status, opts \\ []) do
      Jason.encode!(%{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => status,
          "rateLimitType" => "five_hour",
          "resetsAt" => Keyword.get(opts, :reopens, 1_788_236_400),
          "unifiedWindows" => %{
            "five_hour" => %{"utilization" => 0.67, "resetsAt" => 1_788_236_400},
            "seven_day" => %{"utilization" => 0.6, "resetsAt" => 1_788_490_800}
          }
        }
      })
    end

    test "rate_limit_event with status ALLOWED is not a hit" do
      lines = [quota_event("allowed"), text_event("pong"), result_event()]

      assert {:ok, %Response{}} = ClaudeCLI.parse(output(lines))
    end

    test "rate_limit_event with status allowed_warning is NOT a hit either" do
      lines = [quota_event("allowed_warning"), text_event("pong"), result_event()]

      assert {:ok, %Response{}} = ClaudeCLI.parse(output(lines))
    end

    test "rate_limit_event with a status other than allowed IS a hit" do
      for status <- ["blocked", "rejected", "exceeded", "anything"] do
        lines = [quota_event(status), result_event()]

        assert {:error, {:quota, %DateTime{}}} = ClaudeCLI.parse(output(lines)),
               "status #{status} should be a hit"
      end
    end

    test "the reopening time comes from inside rate_limit_info" do
      lines = [quota_event("blocked", reopens: 1_787_000_000)]

      assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(output(lines))
      assert DateTime.to_unix(reopens_at) == 1_787_000_000
    end

    test "the window utilisation is available, for free" do
      stdout = Enum.join([quota_event("allowed"), result_event()], "\n")

      assert %{"five_hour" => %{"utilization" => 0.67}, "seven_day" => _} =
               ClaudeCLI.quota_windows(stdout)
    end

    test "without rate_limit_event the windows are nil, not an empty map" do
      assert ClaudeCLI.quota_windows(result_event()) == nil
    end
  end

  # The RAW `rate_limit_event` the CLI emitted on a call that WAS served (haiku, `result`
  # success right after), copied unedited: 7-day window at utilisation 1.
  @real_rejected_rate_limit ~S"""
  {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790910000,"rateLimitType":"seven_day","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0,"resetsAt":1790907600},"seven_day":{"utilization":1,"resetsAt":1790910000}}},"uuid":"9cbddf17-e2ae-4b2d-b162-d837700dfcd6","session_id":"60cb1a63-3c90-5a7d-9d0e-2e259ed13b02"}
  """

  # The real haiku stream with the warning where the CLI emitted it: right before `result`.
  defp haiku_with_rejected_warning do
    [assistant_1, assistant_2, result] = String.split(@real_haiku_stream, "\n", trim: true)

    Enum.join(
      [assistant_1, assistant_2, String.trim(@real_rejected_rate_limit), result],
      "\n"
    )
  end

  # The CLI's limit messages, read from the installed executable's strings: the window name
  # sits in the middle of "You've hit your ...", plus the spend literals.
  @limit_messages [
    "You've hit your limit · resets 3am (UTC)",
    "You've hit your weekly limit · resets Oct 2, 3am (UTC)",
    "You've hit your session limit · resets 3am (UTC)",
    "You've hit your Opus limit · resets Oct 2, 3am (UTC)",
    "You've hit your monthly spend limit · your monthly spend limit resets Nov 1",
    "You've hit your Sonnet limit · resets Oct 2, 3am (UTC)",
    "You've hit your usage credit limit",
    "You've hit your fast limit · resets in 2h",
    "You've hit your channel's monthly spend limit.",
    "You've hit your team's shared budget. /model to switch models.",
    "You've hit your monthly limit — raise it below, or it resets next month",
    "Request blocked: monthly spend limit"
  ]

  defp error_result(fields) do
    %{"type" => "result", "subtype" => "success", "is_error" => true}
    |> Map.merge(fields)
    |> Jason.encode!()
  end

  describe "a rejected warning on a SERVED call is not a hit" do
    test "rejected + result is_error: false with an answer -> success, with answer and usage" do
      stdout = haiku_with_rejected_warning()

      assert {:ok, %Response{} = response} = ClaudeCLI.parse(%{stdout: stdout, stderr: ""})

      assert response.stop_reason == :end_turn

      assert %{type: :text, text: "Hey! 👋 What can I help you with today?"} in response.blocks

      assert response.usage.cache_write_tokens == 4_116
      assert response.usage.output_tokens == 61
      assert response.usage.cache_ttl == :one_hour

      assert deviation(computed_cost(stdout, "haiku-4.5"), reported_cost(stdout)) < 0.01
    end

    test "rejected + error result caused by the limit -> still a hit, with the event's resetsAt" do
      result =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "You've hit your limit"
        })

      lines = [String.trim(@real_rejected_rate_limit), result]

      assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(output(lines))
      assert DateTime.to_unix(reopens_at) == 1_790_910_000
    end

    test "rejected WITHOUT result (call not finished) -> still a hit, with the resetsAt" do
      [assistant_1 | _] = String.split(@real_haiku_stream, "\n", trim: true)

      for lines <- [
            [String.trim(@real_rejected_rate_limit)],
            [assistant_1, String.trim(@real_rejected_rate_limit)]
          ] do
        assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(output(lines))
        assert DateTime.to_unix(reopens_at) == 1_790_910_000
      end
    end

    test "a served rejected warning is logged with the window and resetsAt" do
      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ClaudeCLI.parse(%{stdout: haiku_with_rejected_warning(), stderr: ""})
        end)

      assert {:ok, %Response{}} = result
      assert log =~ "[warning]"
      assert log =~ "rejected"
      assert log =~ "seven_day"
      assert log =~ "2026-10-02T03:00:00Z"
    end

    test "without a rejected warning, no quota warning" do
      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ClaudeCLI.parse(%{stdout: @real_haiku_stream, stderr: ""})
        end)

      assert {:ok, %Response{}} = result
      refute log =~ "rejected"
    end

    # A measured stream: haiku, `--max-turns 1`, Bash; the rejected warning, the tool called
    # and executed, and an `error_max_turns` result with `is_error: true`, `result: null`,
    # `num_turns: 2`. The call WAS served and stopped at the factory's own turn cap. The
    # result fields are the measured ones; the tokens are illustrative.
    defp max_turns_stream(opts \\ []) do
      result =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "result" => nil,
          "num_turns" => 2,
          "total_cost_usd" => 0.0042558,
          "api_error_status" => nil,
          "duration_ms" => 3_100,
          "usage" => %{
            "input_tokens" => 18,
            "cache_creation_input_tokens" => 1_500,
            "cache_read_input_tokens" => 9_000,
            "output_tokens" => 120,
            "cache_creation" => %{
              "ephemeral_1h_input_tokens" => 1_500,
              "ephemeral_5m_input_tokens" => 0
            }
          }
        })

      warning =
        if Keyword.get(opts, :warning, true),
          do: [String.trim(@real_rejected_rate_limit)],
          else: []

      Enum.join(
        warning ++
          [
            tool_event("Bash", %{"command" => "ls"}),
            text_event("Listing the files."),
            result
          ],
        "\n"
      )
    end

    test "rejected + error_max_turns result (the measured stream) -> :max_turns with usage and warning; NOT a hit" do
      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ClaudeCLI.parse(%{stdout: max_turns_stream(), stderr: ""})
        end)

      assert {:ok, %Response{} = response} = result
      assert response.stop_reason == :max_turns

      assert %{type: :tool_use, name: "Bash", arguments: %{"command" => "ls"}} =
               Enum.find(response.blocks, &(&1.type == :tool_use))

      assert %{type: :text, text: "Listing the files."} in response.blocks

      assert response.usage.input_tokens == 18
      assert response.usage.cache_write_tokens == 1_500
      assert response.usage.cache_read_tokens == 9_000
      assert response.usage.output_tokens == 120
      assert response.usage.cache_ttl == :one_hour

      assert log =~ "[warning]"
      assert log =~ "rejected"
      assert log =~ "seven_day"
      assert log =~ "2026-10-02T03:00:00Z"

      # Same path as the stream without the warning line.
      assert result ==
               ClaudeCLI.parse(%{stdout: max_turns_stream(warning: false), stderr: ""})
    end

    test "rejected + a known OWN error not caused by the limit -> same path as without the warning, never a hit" do
      for {subtype, fields} <- [
            {"error_max_turns", %{"result" => nil}},
            {"error_during_execution", %{"result" => nil}},
            {"error_during_execution",
             %{"errors" => ["turn_handoff: the turn was stopped before any of its calls ran"]}},
            {"error_max_budget_usd", %{"result" => nil}}
          ],
          before <- [[], [text_event("...")]] do
        result = error_result(Map.put(fields, "subtype", subtype))

        with_warning = output([String.trim(@real_rejected_rate_limit)] ++ before ++ [result])
        without_warning = output(before ++ [result])

        assert {:ok, %Response{}} = ClaudeCLI.parse(with_warning),
               "#{subtype} / #{inspect(fields)} / #{length(before)} block(s) is not a hit"

        assert ClaudeCLI.parse(with_warning) == ClaudeCLI.parse(without_warning)
      end
    end

    test "lock (a): with the warning, is_error: true of a subtype that is not a known own error is a hit, regardless of text" do
      for fields <- [
            %{"subtype" => "success", "result" => "API Error: 529 Overloaded"},
            %{"subtype" => "success", "result" => "API Error: 500 Internal server error"},
            %{"subtype" => "success", "result" => "a message nobody foresaw"},
            %{"subtype" => "success", "result" => nil},
            %{"subtype" => nil, "result" => "no subtype"},
            %{"subtype" => "error_from_a_future_version", "result" => nil}
          ],
          before <- [[], [text_event("...")]] do
        result = error_result(fields)

        with_warning = output([String.trim(@real_rejected_rate_limit)] ++ before ++ [result])

        assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(with_warning),
               "#{inspect(fields)} / #{length(before)} block(s) with warning: should be a hit"

        assert DateTime.to_unix(reopens_at) == 1_790_910_000

        # Without the warning there is no quota signal: the error stays a response.
        assert {:ok, %Response{}} = ClaudeCLI.parse(output(before ++ [result])),
               "#{inspect(fields)} without warning is not a hit"
      end
    end

    test "lock (b): every CLI limit message, WITH and WITHOUT the warning -> hit" do
      for message <- @limit_messages,
          # the CLI writes the message in a synthetic assistant line AND in the result
          before <- [[], [text_event(message)]] do
        result = error_result(%{"subtype" => "success", "result" => message})

        with_warning = output([String.trim(@real_rejected_rate_limit)] ++ before ++ [result])
        without_warning = output(before ++ [result])

        assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(with_warning),
               "#{inspect(message)} with warning: should be a hit"

        assert DateTime.to_unix(reopens_at) == 1_790_910_000

        assert {:error, {:quota, _}} = ClaudeCLI.parse(without_warning),
               "#{inspect(message)} WITHOUT warning: should be a hit (text fallback)"
      end
    end

    test "lock (b) on the warning path: a limit message inside an OWN error is a hit too" do
      for message <- @limit_messages,
          fields <- [%{"result" => message}, %{"result" => nil, "errors" => [message]}] do
        result = error_result(Map.put(fields, "subtype", "error_during_execution"))
        with_warning = output([String.trim(@real_rejected_rate_limit), result])

        assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(with_warning),
               "#{inspect(fields)}: should be a hit"

        assert DateTime.to_unix(reopens_at) == 1_790_910_000
      end
    end

    test "there is ONE limit-message recogniser, used by both paths" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert length(Regex.scan(~r/~r\/[^\n]*limit/i, source)) == 1
      assert source =~ "limit_message?(text) ->"
    end

    test "the CLI's own stream does not match the recogniser (no false hit)" do
      for stdout <- [haiku_with_rejected_warning(), @real_haiku_stream, @real_sonnet_stream] do
        assert {:ok, %Response{}} = ClaudeCLI.parse(%{stdout: stdout, stderr: ""})
      end
    end

    test "rejected + error result caused by the limit, in every recognised form -> hit with the event's resetsAt" do
      for fields <- [
            %{"result" => "You've hit your limit · resets 3am (UTC)"},
            %{"result" => "Claude AI usage limit reached|1790910000"},
            %{"result" => "5-hour limit reached ∙ resets 3am"},
            %{"result" => ~S(API Error: 429 {"error":{"type":"rate_limit_error"}})},
            %{"result" => "Request rejected", "api_error_status" => 429}
          ],
          before <- [[], [text_event("...")]] do
        result =
          %{"type" => "result", "subtype" => "success", "is_error" => true}
          |> Map.merge(fields)
          |> Jason.encode!()

        lines = [String.trim(@real_rejected_rate_limit)] ++ before ++ [result]

        assert {:error, {:quota, reopens_at}} = ClaudeCLI.parse(output(lines)),
               "#{inspect(fields)} is a limit error: should be a hit"

        assert DateTime.to_unix(reopens_at) == 1_790_910_000
      end
    end
  end

  describe "the executable comes from CONFIGURATION" do
    test "the default is `claude`" do
      original = Application.get_env(:factory, :claude_cli)
      Application.delete_env(:factory, :claude_cli)
      on_exit(fn -> if original, do: Application.put_env(:factory, :claude_cli, original) end)

      assert ClaudeCLI.executable() == "claude"
    end

    test "configuration overrides the default" do
      Application.put_env(:factory, :claude_cli, "C:/fake/test-claude")
      on_exit(fn -> Application.delete_env(:factory, :claude_cli) end)

      assert ClaudeCLI.executable() == "C:/fake/test-claude"
    end
  end

  describe "the contract matches the module doc" do
    test "implements the Factory.Provider behaviour" do
      behaviours =
        ClaudeCLI.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Factory.Provider in behaviours
    end

    test "the module doc states that this provider does NOT place cache breakpoints, and why" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ "does not place cache breakpoints"
      assert source =~ "cache_control"
      assert source =~ "MessagesAPI"
    end

    test "the module doc describes the quota hit as structural under a subscription" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ "Quota hit"
      assert source =~ "Structural under a subscription"
    end

    test "the command line carries --verbose, without which the CLI REFUSES the call" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ "--verbose"
      assert source =~ "--output-format stream-json"
    end

    test "parse/1 accepts the FULL Command result, not just two keys" do
      command_result = %{
        stdout: Enum.join([text_event("done"), result_event()], "\n"),
        stderr: "",
        reason: :normal,
        code: 0,
        duration_ms: 4_210
      }

      assert {:ok, %Response{} = response} = ClaudeCLI.parse(command_result)
      assert [%{type: :text, text: "done"}] = response.blocks
      assert %Usage{cache_read_tokens: 90_000} = response.usage
    end
  end

  describe "the root reaches the CLI with its long name" do
    test "a root with no short segment is returned untouched, without asking the OS" do
      expand = fn _ -> flunk("the OS must not be asked") end

      assert {:ok, "C:/Users/someone/project"} =
               ClaudeCLI.long_root("C:/Users/someone/project", expand)

      assert {:ok, "."} = ClaudeCLI.long_root(".", expand)
    end

    test "a short segment (8.3) is expanded to the long name" do
      expand = fn "C:\\Users\\ENZOCO~1\\project" -> {:ok, "C:\\Users\\someone\\project"} end

      assert {:ok, "C:\\Users\\someone\\project"} =
               ClaudeCLI.long_root("C:\\Users\\ENZOCO~1\\project", expand)
    end

    test "a short root that cannot be expanded is refused, not handed to the CLI" do
      assert {:error, {:short_path_root, "C:/X/PROGRA~9"}} =
               ClaudeCLI.long_root("C:/X/PROGRA~9", fn _ -> :error end)
    end

    test "the real temp directory comes out with no short segment and still exists" do
      assert {:ok, long} = ClaudeCLI.long_root(System.tmp_dir!())
      refute long =~ ~r/~\d/
      assert File.dir?(long)
    end

    if match?({:win32, _}, :os.type()) do
      test "chat/2 refuses a short root that does not exist before starting the CLI" do
        request = %Request{role: "builder", model: "haiku", messages: []}
        root = "C:/factory-missing-#{System.unique_integer([:positive])}/ABCDEF~1"

        assert {:error, {:short_path_root, ^root}} = ClaudeCLI.chat(request, root: root)
      end
    end
  end

  describe "the confinement audit (half 2), via Confinement.resolve/2" do
    # Under `_build` rather than `System.tmp_dir!/0`, to avoid 8.3 short paths.
    setup do
      base = Path.join([File.cwd!(), "_build", "test", "tmp"])
      root = Path.join(base, "conf-cli-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "a tool_use with file_path OUTSIDE the root makes parse/2 return the named error", %{
      root: root
    } do
      outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.txt")
      lines = [tool_event("write", %{"file_path" => outside}), result_event()]

      assert {:error, {:outside_confinement, paths}} =
               ClaudeCLI.parse(output(lines), root)

      assert outside in paths
    end

    test "the SAME stream with the path INSIDE the root returns {:ok, %Response{}}", %{
      root: root
    } do
      inside = Path.join(root, "ok.txt")
      lines = [tool_event("write", %{"file_path" => inside}), result_event()]

      assert {:ok, %Response{}} = ClaudeCLI.parse(output(lines), root)
    end

    test "traversal (\"..\\outside.txt\") is caught too", %{
      root: root
    } do
      lines = [
        tool_event("write", %{"file_path" => "../outside-by-traversal.txt"}),
        result_event()
      ]

      assert {:error, {:outside_confinement, _paths}} =
               ClaudeCLI.parse(output(lines), root)
    end

    test "without a root (parse/1) the audit is off" do
      lines = [
        tool_event("write", %{"file_path" => "C:/outside-any-root.txt"}),
        result_event()
      ]

      assert {:ok, %Response{}} = ClaudeCLI.parse(output(lines))
    end

    test "notebook_path and path are audited, not only file_path", %{root: root} do
      outside = Path.join(Path.dirname(root), "outside-notebook.ipynb")
      lines = [tool_event("edit", %{"notebook_path" => outside}), result_event()]

      assert {:error, {:outside_confinement, [^outside]}} =
               ClaudeCLI.parse(output(lines), root)
    end

    test "an argument that is not a path (e.g. a shell command) is not audited", %{
      root: root
    } do
      lines = [
        tool_event("run", %{"command" => "type C:\\outside\\secret.txt"}),
        result_event()
      ]

      assert {:ok, %Response{}} = ClaudeCLI.parse(output(lines), root)
    end

    test "the audit uses Factory.Tools.Confinement.resolve/2, not a path rule of its own" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ "Confinement.resolve(root, path)"
      refute source =~ "Path.type(path)"
      refute Regex.match?(~r/String\.starts_with\?\(path/, source)
    end
  end

  describe "the shell confinement gap is documented in the module doc" do
    test "the possible options are written down" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ "do not allow the shell tool"
      assert source =~ "OS-level sandbox"
      assert source =~ "MCP"
      assert source =~ "accept the gap"
    end
  end

  describe "family: this provider runs its own loop" do
    test "family/0 returns :full_agent" do
      assert ClaudeCLI.family() == :full_agent
    end

    test "Factory.Provider.family/1 resolves to :full_agent through the provider" do
      assert Factory.Provider.family(ClaudeCLI) == :full_agent
    end
  end

  describe "the model at the CLI boundary" do
    for {internal, id} <- [
          {"sonnet-5", "claude-sonnet-5-5"},
          {"opus-5", "claude-opus-5-5"},
          {"haiku-4.5", "claude-haiku-4-5-20251001"}
        ] do
      @internal internal
      @id id

      test "#{internal} becomes --model #{id} on the built line" do
        request = %Request{role: "builder", model: @internal, messages: []}

        assert {:ok, line} = ClaudeCLI.command_line(request)
        assert line =~ ~r/--model #{Regex.escape(@id)}$/
        refute line =~ "--model #{@internal}"
      end
    end

    test "cli_model/1 is the translation, and is idempotent on the real ID" do
      for {internal, id} <- ClaudeCLI.cli_models() do
        assert ClaudeCLI.cli_model(internal) == {:ok, id}
        assert ClaudeCLI.cli_model(id) == {:ok, id}
      end
    end

    test "the translation covers the three internal names the factory uses" do
      assert ClaudeCLI.cli_models() |> Map.keys() |> Enum.sort() ==
               ["haiku-4.5", "opus-5", "sonnet-5"]
    end

    test "an unknown internal name is a named error and never reaches the CLI raw" do
      request = %Request{role: "builder", model: "sonnet-6", messages: []}

      assert ClaudeCLI.command_line(request) == {:error, {:untranslated_model, "sonnet-6"}}
      assert ClaudeCLI.cli_model("sonnet-6") == {:error, {:untranslated_model, "sonnet-6"}}
    end

    test "a missing model is a named error too, not an empty `--model `" do
      request = %Request{role: "builder", model: nil, messages: []}

      assert ClaudeCLI.command_line(request) == {:error, {:untranslated_model, nil}}
    end

    test "the CLI's own short aliases pass through untranslated" do
      for alias_name <- ["haiku", "sonnet", "opus"] do
        request = %Request{role: "builder", model: alias_name, messages: []}

        assert {:ok, line} = ClaudeCLI.command_line(request)
        assert line =~ ~r/--model #{alias_name}$/
      end
    end
  end

  describe "headless permission on the built line" do
    test "every line carries --permission-mode acceptEdits" do
      request = %Request{role: "builder", model: "haiku", messages: []}

      assert line!(request) =~ "--permission-mode acceptEdits"
    end

    test "every line carries --tools (which CLOSES the vocabulary), never --disallowedTools" do
      for role <- Catalog.roles() ++ ["unknown-role"] do
        line = line!(%Request{role: role, model: "haiku", messages: []})

        assert line =~ "--tools \"", "#{role} without --tools"
        refute line =~ "--disallowedTools", "#{role} with --disallowedTools"
      end
    end
  end

  describe "the announced Bash is APPROVED on the real dispatch" do
    defp allowed_tools(line) do
      case Regex.scan(~r/--allowedTools "([^"]*)"/, line, capture: :all_but_first) do
        [] -> nil
        [[value]] -> value
        several -> flunk("--allowedTools repeated on the line: #{inspect(several)}")
      end
    end

    for role <- Catalog.roles() do
      @role role

      test "#{role}: --allowedTools \"Bash\" if and only if its --tools contains Bash" do
        line = line!(%Request{role: @role, model: "haiku", messages: []})
        [_, tools] = Regex.run(~r/--tools "([^"]*)"/, line)

        if "Bash" in String.split(tools, ",") do
          assert allowed_tools(line) == "Bash",
                 "#{@role} has Bash in --tools but the line does not approve it: #{line}"
        else
          assert allowed_tools(line) == nil,
                 "#{@role} has NO Bash in --tools and still gets --allowedTools: #{line}"
        end
      end
    end

    test "current catalogue: builder and verifier approve Bash; the others do not" do
      approving =
        for role <- Catalog.roles(),
            allowed_tools(line!(%Request{role: role, model: "haiku", messages: []})),
            do: role

      assert approving == ["builder", "verifier"]
    end

    test "an unknown role (empty --tools) gets no approval" do
      line = line!(%Request{role: "unknown-role", model: "haiku", messages: []})

      assert line =~ ~s(--tools "")
      refute line =~ "--allowedTools"
    end

    test "only Bash is approved: no Write/Edit/Read approved by flag" do
      for role <- Catalog.roles() do
        line = line!(%Request{role: role, model: "haiku", messages: []})

        assert allowed_tools(line) in [nil, "Bash"]
      end
    end

    test "--allowedTools comes right after --tools and before --max-turns (variadic flag)" do
      line = line!(%Request{role: "builder", model: "haiku", messages: []})

      assert line =~
               ~s(--tools "Bash,Edit,Glob,Grep,Read,Write" --allowedTools "Bash" --max-turns 30)
    end

    test "the module doc says what --allowedTools \"Bash\" approves and what it does NOT confine" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ ~s(`--allowedTools "Bash"`)
      assert source =~ "does NOT confine"
    end
  end

  describe "the agent's Bash runs CONFINED in the claude sandbox" do
    # Written here literally, not read from the module, so the test proves the requirement.
    @expected_sandbox %{
      "sandbox" => %{
        "enabled" => true,
        "failIfUnavailable" => true,
        "autoAllowBashIfSandboxed" => true,
        "allowUnsandboxedCommands" => false
      }
    }

    # The `--settings` argument on the line, unquoted (`\"` -> `"`); nil when absent.
    defp settings(line) do
      case Regex.scan(~r/--settings "((?:[^"\\]|\\.)*)"/, line, capture: :all_but_first) do
        [] -> nil
        [[value]] -> String.replace(value, ~s(\\"), ~s("))
        several -> flunk("--settings repeated on the line: #{inspect(several)}")
      end
    end

    for role <- Catalog.roles() do
      @role role

      test "#{role}: gets the sandbox if and only if its --tools contains Bash" do
        line = line!(%Request{role: @role, model: "haiku", messages: []})
        [_, tools] = Regex.run(~r/--tools "([^"]*)"/, line)

        if "Bash" in String.split(tools, ",") do
          assert value = settings(line),
                 "#{@role} has Bash and the line has no --settings: #{line}"

          assert Jason.decode!(value) == @expected_sandbox
        else
          assert settings(line) == nil,
                 "#{@role} has NO Bash and still gets --settings: #{line}"

          refute line =~ "sandbox"
        end
      end
    end

    test "current catalogue: builder and verifier start confined; the others without the block" do
      confined =
        for role <- Catalog.roles(),
            settings(line!(%Request{role: role, model: "haiku", messages: []})),
            do: role

      assert confined == ["builder", "verifier"]
    end

    test "an unknown role (empty --tools) gets no block" do
      line = line!(%Request{role: "unknown-role", model: "haiku", messages: []})

      assert line =~ ~s(--tools "")
      refute line =~ "--settings"
    end

    test "no escape hatch: the block does not depend on application configuration" do
      keys = [:sandbox, :sandbox_cli, :confine_shell]
      on_exit(fn -> Enum.each(keys, &Application.delete_env(:factory, &1)) end)
      Enum.each(keys, &Application.put_env(:factory, &1, false))

      line = line!(%Request{role: "builder", model: "haiku", messages: []})
      assert Jason.decode!(settings(line)) == @expected_sandbox
    end

    # REAL output of a `claude` that refuses to start for lack of a sandbox, with the
    # `command_line/1` flags (`--output-format stream-json`), captured without a model:
    # rc=1, stdout (1042 bytes) and stderr (341 bytes) below, byte for byte.
    @stdout_no_sandbox ~S"""
    {"type":"result","subtype":"error_during_execution","duration_ms":0,"duration_api_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,"session_id":"9f59b5d3-dffb-4d6f-83a2-0dae9867f219","total_cost_usd":0,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard","fallback_credit":null},"modelUsage":{},"permission_denials":[],"uuid":"cef4fd6e-ea3f-4f3c-9a31-27173d5484c1","errors":["Sandbox required but unavailable: sandbox is enabled but dependencies are missing: bubblewrap (bwrap) not installed, socat not installed · install missing tools (e.g. apt install bubblewrap socat) or see https://code.claude.com/docs/en/sandboxing. Set sandbox.failIfUnavailable=false to allow unsandboxed execution."],"result_index":0}
    """

    @stderr_no_sandbox """

    Error: sandbox required but unavailable: sandbox is enabled but dependencies are missing: bubblewrap (bwrap) not installed, socat not installed · install missing tools (e.g. apt install bubblewrap socat) or see https://code.claude.com/docs/en/sandboxing
      sandbox.failIfUnavailable is set — refusing to start without a working sandbox.

    """

    @output_no_sandbox %{stdout: @stdout_no_sandbox, stderr: @stderr_no_sandbox, code: 1}

    test "the fixture has the real shape (error result, zero turns)" do
      assert byte_size(@stdout_no_sandbox) == 1042
      assert byte_size(@stderr_no_sandbox) == 341

      assert [result] =
               @stdout_no_sandbox |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert %{"type" => "result", "subtype" => "error_during_execution", "is_error" => true} =
               result

      assert %{"num_turns" => 0, "errors" => [error]} = result
      assert error =~ "Sandbox required but unavailable"
    end

    test "a claude refusing to start without a sandbox becomes {:error, :sandbox_unavailable}" do
      assert ClaudeCLI.parse(@output_no_sandbox) == {:error, :sandbox_unavailable}

      assert ClaudeCLI.parse(@output_no_sandbox, "/tmp/root") ==
               {:error, :sandbox_unavailable}

      # `build_response/2` is what `chat/2` returns: no session, no usage, no envelope.
      assert ClaudeCLI.build_response(@output_no_sandbox, "/tmp/root") ==
               {:error, :sandbox_unavailable}
    end

    test "the sandbox error is not success, nor :refusal, nor a quota hit" do
      result = ClaudeCLI.parse(@output_no_sandbox, "/tmp/root")

      refute match?({:ok, _}, result)
      refute match?({:error, {:quota, _}}, result)
      refute match?({:error, :unreadable_output}, result)
      refute match?({:ok, %Response{stop_reason: :refusal}}, result)
    end

    test "the text only in the zero-turn result's `errors` (stderr lost) is still the sandbox error" do
      output = %{@output_no_sandbox | stderr: ""}

      assert ClaudeCLI.parse(output) == {:error, :sandbox_unavailable}
    end

    test "a session that STARTED (system/init, num_turns >= 1) with the text in errors and stderr is not the sandbox error" do
      init = Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "s"})

      result =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_during_execution",
          "is_error" => true,
          "num_turns" => 2,
          "total_cost_usd" => 0.01,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "errors" => ["Sandbox required but unavailable: (the agent read this from the task)"]
        })

      output = %{stdout: Enum.join([init, result], "\n"), stderr: @stderr_no_sandbox}

      assert {:ok, %Response{}} = ClaudeCLI.parse(output)
      refute ClaudeCLI.parse(output) == {:error, :sandbox_unavailable}
    end

    test "the error text INSIDE a finished session is not the sandbox error" do
      output =
        output(
          [text_event("read: sandbox required but unavailable"), result_event()],
          @stderr_no_sandbox
        )

      assert {:ok, %Response{stop_reason: :end_turn}} = ClaudeCLI.parse(output)
    end

    if match?({:win32, _}, :os.type()) do
      @tag skip: "on native Windows the claude sandbox does not exist and .bat quoting differs"
    end

    test "--settings reaches the executable as valid JSON through the real dispatch path" do
      root =
        Path.join([
          File.cwd!(),
          "_build",
          "test",
          "tmp",
          "cli-sandbox-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(root)
      dest = Path.join(root, "arguments.txt")
      script = Path.join(root, "arguments.sh")

      File.write!(
        script,
        ~s(#!/bin/sh\nfor a in "$@"; do printf '%s\\n' "$a"; done > "#{dest}"\n)
      )

      File.chmod!(script, 0o755)

      original = Application.get_env(:factory, :claude_cli)
      Application.put_env(:factory, :claude_cli, script)

      on_exit(fn ->
        File.rm_rf(root)

        if original,
          do: Application.put_env(:factory, :claude_cli, original),
          else: Application.delete_env(:factory, :claude_cli)
      end)

      request = %Request{role: "builder", model: "haiku", messages: []}
      _ = ClaudeCLI.chat(request, root: root)

      arguments = dest |> File.read!() |> String.split("\n", trim: true)
      index = Enum.find_index(arguments, &(&1 == "--settings"))

      assert index, "the executable did not receive --settings: #{inspect(arguments)}"
      assert Jason.decode!(Enum.at(arguments, index + 1)) == @expected_sandbox
      # The neighbouring flags are intact: the JSON quoting swallowed nothing.
      assert Enum.at(arguments, Enum.find_index(arguments, &(&1 == "--allowedTools")) + 1) ==
               "Bash"

      assert List.last(arguments) == "haiku"
    end

    test "the module doc says what the sandbox confines and what it does NOT" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      assert source =~ "failIfUnavailable"
      assert source =~ "allowUnsandboxedCommands"
      assert source =~ "Read-only file system"
      assert source =~ ~r/reading/i
      assert source =~ ~r/network/i
      assert source =~ "native Windows"
      assert source =~ ":sandbox_unavailable"
      refute source =~ "measured an `echo` writing outside"
    end
  end

  describe "the agent does not inherit CLAUDE.md from parent directories" do
    test "every line carries --setting-sources user" do
      request = %Request{role: "builder", model: "haiku", messages: []}

      assert line!(request) =~ ~r/--setting-sources user(\s|$)/
    end

    test "the project and local levels are left out, for every role" do
      for role <- ["builder", "verifier", "reviewer", "planner", "unknown-role"] do
        line = line!(%Request{role: role, model: "haiku", messages: []})

        assert [_, sources] = Regex.run(~r/--setting-sources (\S+)/, line)
        assert String.split(sources, ",") == ["user"]
      end
    end

    test "never --bare: it requires ANTHROPIC_API_KEY and the factory runs on the subscription" do
      request = %Request{role: "builder", model: "haiku", messages: []}

      refute line!(request) =~ "--bare"
    end
  end

  describe "the catalogue translation into the CLI vocabulary" do
    test "is TOTAL: every role of Catalog.roles/0 has a translation" do
      for role <- Catalog.roles() do
        tools = ClaudeCLI.cli_tools(role)

        assert is_list(tools), "role #{role} produced no tool list"
        assert tools != [], "role #{role} ended up with no translated tool"
      end
    end

    test "no role without the :write power gets a write tool" do
      for role <- Catalog.roles(), not Catalog.can_write?(role) do
        tools = ClaudeCLI.cli_tools(role)

        refute "Write" in tools, "#{role} cannot write but got Write"
        refute "Edit" in tools, "#{role} cannot write but got Edit"
      end
    end

    test "every role with the :write power gets Write and Edit" do
      for role <- Catalog.roles(), Catalog.can_write?(role) do
        tools = ClaudeCLI.cli_tools(role)

        assert "Write" in tools
        assert "Edit" in tools
      end
    end

    test "builder gets the full vocabulary on the built line" do
      request = %Request{role: "builder", model: "haiku", messages: []}

      assert line!(request) =~ ~s(--tools "Bash,Edit,Glob,Grep,Read,Write")
    end

    test "verifier has no Write/Edit on the built line" do
      request = %Request{role: "verifier", model: "haiku", messages: []}

      assert line!(request) =~ ~s(--tools "Bash,Glob,Grep,Read")
    end

    test "an unknown role becomes an empty --tools (everything off), not an error" do
      request = %Request{role: "role-that-does-not-exist", model: "haiku", messages: []}

      assert line!(request) =~ ~s(--tools "")
    end

    test "report_result has no CLI equivalent and leaks no null translation" do
      for role <- Catalog.roles() do
        assert Enum.all?(ClaudeCLI.cli_tools(role), &(is_binary(&1) and &1 != ""))
      end
    end
  end

  describe "an EXPLICIT vocabulary replaces the role's" do
    test "cli_tools_for_vocabulary translates like cli_tools, without the catalogue" do
      assert ClaudeCLI.cli_tools_for_vocabulary(["write", "read"]) == ["Read", "Write"]
      assert ClaudeCLI.cli_tools_for_vocabulary(["name-that-does-not-exist"]) == []
      assert ClaudeCLI.cli_tools_for_vocabulary([]) == []
    end

    test "a vocabulary without `run`: --tools has only what was asked, NO --allowedTools and NO sandbox block" do
      request = %Request{
        role: "builder",
        vocabulary: ["write"],
        model: "haiku",
        messages: []
      }

      line = line!(request)

      assert line =~ ~s(--tools "Write")
      refute line =~ "Bash"
      refute line =~ "--allowedTools"
      refute line =~ "--settings"
      refute line =~ "sandbox"
    end

    test "a vocabulary WITH `run`: still gets --allowedTools \"Bash\" and the sandbox block" do
      # The reviewer role has no `run` in the catalogue: the decision follows the vocabulary.
      request = %Request{
        role: "reviewer",
        vocabulary: ["run"],
        model: "haiku",
        messages: []
      }

      line = line!(request)

      assert line =~ ~s(--tools "Bash")
      assert line =~ ~s(--allowedTools "Bash")

      assert [_, block] = Regex.run(~r/--settings "((?:[^"\\]|\\.)*)"/, line)

      assert Jason.decode!(String.replace(block, ~s(\\"), ~s("))) == %{
               "sandbox" => %{
                 "enabled" => true,
                 "failIfUnavailable" => true,
                 "autoAllowBashIfSandboxed" => true,
                 "allowUnsandboxedCommands" => false
               }
             }
    end

    test "without a vocabulary (nil, the default), the line comes from the role" do
      request = %Request{role: "builder", model: "haiku", messages: []}

      assert line!(request) =~ ~s(--tools "Bash,Edit,Glob,Grep,Read,Write")
    end
  end

  describe "the turn cap is enforced by the command line, never by the prompt" do
    test "the line carries --max-turns from request.max_turns" do
      request = %Request{
        role: "builder",
        model: "haiku",
        messages: [],
        max_turns: 7
      }

      assert line!(request) =~ "--max-turns 7"
    end

    test "different caps produce different lines" do
      base = %Request{role: "builder", model: "haiku", messages: []}

      line_1 = line!(%{base | max_turns: 1})
      line_30 = line!(%{base | max_turns: 30})

      assert line_1 =~ "--max-turns 1"
      assert line_30 =~ "--max-turns 30"
      refute line_1 == line_30
    end

    test "the default cap (30, from Request) becomes a flag too" do
      request = %Request{role: "builder", model: "haiku", messages: []}

      assert line!(request) =~ "--max-turns 30"
    end

    test "the prompt text is not on the line: the cap is a flag and the text goes through stdin" do
      request = %Request{
        role: "builder",
        model: "haiku",
        messages: [%{role: :user, content: "answer ok"}],
        max_turns: 5
      }

      assert ClaudeCLI.prompt_text(request) == "answer ok"
      refute line!(request) =~ "answer ok"
      assert line!(request) =~ "--max-turns 5"
    end
  end

  describe "the CLI vocabulary stops at ClaudeCLI" do
    test "Write, Edit, Bash, Read, Glob and Grep appear in no other module of lib/" do
      findings =
        ~r/\bWrite\b|\bEdit\b|\bBash\b|\bRead\b|\bGlob\b|\bGrep\b/
        |> Factory.Source.matching_production_files()
        |> Enum.reject(&(&1 =~ "claude_cli.ex"))

      assert findings == []
    end
  end

  describe "the prompt leaves the command line" do
    defp windows_cli?, do: match?({:win32, _}, :os.type())

    setup do
      root =
        Path.join([
          File.cwd!(),
          "_build",
          "test",
          "tmp",
          "cli-stdin-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(root)

      original = Application.get_env(:factory, :claude_cli)

      on_exit(fn ->
        File.rm_rf(root)

        if original do
          Application.put_env(:factory, :claude_cli, original)
        else
          Application.delete_env(:factory, :claude_cli)
        end
      end)

      {:ok, root: root}
    end

    # A fake executable that copies the received stdin, byte for byte, into `dest`.
    defp copy_stdin_to_file(root, dest) do
      if windows_cli?() do
        script = Path.join(root, "copy-#{System.unique_integer([:positive])}.ps1")
        dest_ps1 = String.replace(dest, "/", "\\")

        File.write!(script, """
        $in = [Console]::OpenStandardInput()
        $out = [IO.File]::Create('#{dest_ps1}')
        $in.CopyTo($out)
        $out.Flush()
        $out.Close()
        """)

        ~s(powershell -NoProfile -ExecutionPolicy Bypass -File "#{String.replace(script, "/", "\\")}")
      else
        script = Path.join(root, "copy-#{System.unique_integer([:positive])}.sh")
        File.write!(script, "#!/bin/sh\ncat > \"#{dest}\"\n")
        File.chmod!(script, 0o755)
        script
      end
    end

    # A fake executable that just sleeps, to force the timeout.
    defp sleeping_script(root, seconds) do
      if windows_cli?() do
        script = Path.join(root, "sleep-#{System.unique_integer([:positive])}.ps1")
        File.write!(script, "Start-Sleep -Seconds #{seconds}\n")

        ~s(powershell -NoProfile -ExecutionPolicy Bypass -File "#{String.replace(script, "/", "\\")}")
      else
        script = Path.join(root, "sleep-#{System.unique_integer([:positive])}.sh")
        File.write!(script, "#!/bin/sh\nsleep #{seconds}\n")
        File.chmod!(script, 0o755)
        script
      end
    end

    test "two completely different prompts produce the SAME line" do
      base = %Request{role: "builder", model: "haiku", messages: []}

      line_1 =
        line!(%{base | messages: [%{role: :user, content: "request A"}]})

      line_2 =
        line!(%{
          base
          | messages: [%{role: :user, content: "another, very different request\nwith a newline"}]
        })

      assert line_1 == line_2
      refute line_1 =~ "request A"
    end

    test "a prompt with newlines, double quotes and & reaches the input file INTACT",
         %{root: root} do
      dest = Path.join(root, "received.txt")
      Application.put_env(:factory, :claude_cli, copy_stdin_to_file(root, dest))

      content =
        "line one\nline \"with double quotes\"\nline with & ampersand\nend without newline"

      request = %Request{
        role: "builder",
        model: "haiku",
        messages: [%{role: :user, content: content}]
      }

      ClaudeCLI.chat(request, root: root, timeout: 20_000)

      assert File.read!(dest) == content
    end

    test "there is no escape function in the module" do
      source = File.read!("lib/factory/provider/claude_cli.ex")

      refute source =~ "defp escape"
      refute source =~ "def escape"
    end

    test "the temporary prompt file is removed even when the timeout fires", %{root: root} do
      Application.put_env(:factory, :claude_cli, sleeping_script(root, 5))
      mark = "prompt-mark-#{System.unique_integer([:positive])}"

      request = %Request{
        role: "builder",
        model: "haiku",
        messages: [%{role: :user, content: mark}]
      }

      assert {:error, :timeout} = ClaudeCLI.chat(request, root: root, timeout: 300)

      # Under async tests other files may exist; what proves cleanup is that none holds OUR mark.
      left_over? =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "factory-cli-prompt-"))
        |> Enum.any?(fn name ->
          case File.read(Path.join(System.tmp_dir!(), name)) do
            {:ok, content} -> content =~ mark
            _ -> false
          end
        end)

      refute left_over?, "the temporary prompt file stayed on disk after the timeout"
    end

    test "the temporary prompt file is removed even with a missing executable", %{
      root: root
    } do
      Application.put_env(
        :factory,
        :claude_cli,
        "executable-that-does-not-exist-#{System.unique_integer([:positive])}"
      )

      mark = "prompt-mark-#{System.unique_integer([:positive])}"

      request = %Request{
        role: "builder",
        model: "haiku",
        messages: [%{role: :user, content: mark}]
      }

      assert {:error, _reason} = ClaudeCLI.chat(request, root: root, timeout: 10_000)

      left_over? =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "factory-cli-prompt-"))
        |> Enum.any?(fn name ->
          case File.read(Path.join(System.tmp_dir!(), name)) do
            {:ok, content} -> content =~ mark
            _ -> false
          end
        end)

      refute left_over?,
             "the temporary prompt file stayed on disk with a missing executable"
    end

    test "untranslated model: chat/2 returns the named error WITHOUT calling the executable",
         %{root: root} do
      dest = Path.join(root, "called.txt")
      Application.put_env(:factory, :claude_cli, copy_stdin_to_file(root, dest))

      request = %Request{
        role: "builder",
        model: "invented-model",
        messages: [%{role: :user, content: "hi"}]
      }

      assert ClaudeCLI.chat(request, root: root, timeout: 10_000) ==
               {:error, {:untranslated_model, "invented-model"}}

      refute File.exists?(dest), "the CLI was called with a model it does not know"
    end
  end

  # The REAL provider fed with the raw output of one CLI process: `ClaudeCLI.build_response/2`
  # does with it exactly what `chat/2` does, with no process, network or quota.
  defmodule RecordedCLIProvider do
    @moduledoc false
    @behaviour Factory.Provider

    @impl Factory.Provider
    def family, do: ClaudeCLI.family()

    @impl Factory.Provider
    def chat(_request, opts) do
      ClaudeCLI.build_response(Keyword.fetch!(opts, :needle), Keyword.fetch!(opts, :root))
    end
  end

  describe "a provider error carries the usage already measured" do
    @sample "priv/probes/samples/session-with-tool.jsonl"

    setup do
      root =
        Path.join([
          File.cwd!(),
          "_build",
          "test",
          "tmp",
          "cli-usage-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(root)
      original = Application.get_env(:factory, :claude_cli)

      on_exit(fn ->
        File.rm_rf(root)

        if original do
          Application.put_env(:factory, :claude_cli, original)
        else
          Application.delete_env(:factory, :claude_cli)
        end
      end)

      {:ok, root: root}
    end

    # The real stream up to the last `assistant` line: what the output holds when the process
    # is killed by the timeout before writing `result`.
    defp without_result(stdout) do
      stdout
      |> String.split("\n", trim: true)
      |> Enum.reject(&(Jason.decode!(&1)["type"] == "result"))
      |> Enum.join("\n")
    end

    defp loop_spend(output, root) do
      {:ok, summary} =
        Loop.run(
          needle: output,
          provider: RecordedCLIProvider,
          model: "haiku-4.5",
          root: root,
          tools: %{}
        )

      summary
    end

    test "outside confinement with a result: the error carries the result's usage and spend",
         %{root: root} do
      stdout = File.read!(@sample)

      assert {:error, {:outside_confinement, _}} =
               ClaudeCLI.parse(%{stdout: stdout, stderr: ""}, root)

      {:ok, %Response{usage: from_result}} = ClaudeCLI.parse(%{stdout: stdout, stderr: ""})

      assert {:error, {:with_usage, {:outside_confinement, paths}, usage}} =
               ClaudeCLI.build_response(%{stdout: stdout, stderr: ""}, root)

      assert Enum.any?(paths, &(&1 =~ "nota.txt"))
      assert usage == from_result

      summary = loop_spend(%{stdout: stdout, stderr: ""}, root)
      assert summary.outcome == :error
      assert deviation(summary.spent_usd, reported_cost(stdout)) < 0.01
    end

    test "timeout after assistant lines with usage: spend > 0, estimated from that usage", %{
      root: root
    } do
      partial = without_result(File.read!(@sample))

      {response, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ClaudeCLI.build_response(%{stdout: partial, stderr: "", reason: :timeout}, root)
        end)

      assert {:error, {:with_usage, :timeout, %Usage{} = usage}} = response

      # Two calls (two `message.id`s), each repeated once per block with the SAME usage: each
      # call counts once. Summing line by line would give 4 x 7021 + 2 x 494 = 29_072.
      assert usage.cache_write_tokens == 7_021 + 494
      assert usage.cache_read_tokens == 16_265 + 23_286
      assert usage.input_tokens == 10 + 8
      assert usage.output_tokens == 4 + 2
      assert usage.cache_ttl == :one_hour
      assert log =~ "estimated"

      summary = loop_spend(%{stdout: partial, stderr: "", reason: :timeout}, root)
      assert summary.outcome == :error
      assert summary.spent_usd > 0
      # The assistant lines' output_tokens is partial: the estimate is a floor.
      assert summary.spent_usd <= reported_cost(File.read!(@sample))
    end

    test "timeout with no line carrying usage: 0.0, with a warning", %{root: root} do
      system_only =
        File.read!(@sample)
        |> String.split("\n", trim: true)
        |> Enum.filter(&(Jason.decode!(&1)["type"] == "system"))
        |> Enum.join("\n")

      for stdout <- ["", system_only, text_event("no usage at all")] do
        output = %{stdout: stdout, stderr: "", reason: :timeout}

        {response, log} =
          ExUnit.CaptureLog.with_log(fn -> ClaudeCLI.build_response(output, root) end)

        assert response == {:error, :timeout}
        assert log =~ "timeout"
        assert log =~ "0.0"

        {summary, _log} = ExUnit.CaptureLog.with_log(fn -> loop_spend(output, root) end)
        assert summary.outcome == :error
        assert summary.spent_usd == 0.0
        assert summary.usages == []
      end
    end

    test "timeout with the result already written: the result's usage counts, not the estimate",
         %{
           root: root
         } do
      stdout = File.read!(@sample)
      {:ok, %Response{usage: from_result}} = ClaudeCLI.parse(%{stdout: stdout, stderr: ""})

      assert {:error, {:with_usage, :timeout, ^from_result}} =
               ClaudeCLI.build_response(%{stdout: stdout, stderr: "", reason: :timeout}, root)
    end

    test "a quota hit is NOT wrapped: callers match {:error, {:quota, _}}", %{
      root: root
    } do
      assert {:error, {:quota, _reopens_at}} =
               ClaudeCLI.build_response(
                 %{stdout: "", stderr: "Claude AI usage limit reached"},
                 root
               )
    end

    test "an accepted real stream (no path outside the root) stays {:ok, %Response{}}, unwrapped",
         %{root: root} do
      assert {:ok, %Response{}} =
               ClaudeCLI.build_response(%{stdout: @real_haiku_stream, stderr: ""}, root)
    end

    test "real chat/2: the process writes assistant lines and hangs; the timeout counts them",
         %{root: root} do
      source = Path.join(root, "partial.jsonl")
      File.write!(source, without_result(File.read!(@sample)))
      Application.put_env(:factory, :claude_cli, print_and_hang(root, source))

      request = %Request{
        role: "builder",
        model: "haiku",
        messages: [%{role: :user, content: "hi"}]
      }

      assert {:error, {:with_usage, :timeout, %Usage{} = usage}} =
               ClaudeCLI.chat(request, root: root, timeout: 2_000)

      assert usage.cache_write_tokens == 7_021 + 494
      assert usage.cache_read_tokens == 16_265 + 23_286
    end

    # A fake executable that prints `source` byte for byte and HANGS until the timeout.
    defp print_and_hang(root, source) do
      if windows_cli?() do
        script = Path.join(root, "hang-#{System.unique_integer([:positive])}.ps1")
        source_ps1 = String.replace(source, "/", "\\")

        File.write!(script, """
        $in = [IO.File]::OpenRead('#{source_ps1}')
        $out = [Console]::OpenStandardOutput()
        $in.CopyTo($out)
        $out.Flush()
        $in.Close()
        Start-Sleep -Seconds 30
        """)

        ~s(powershell -NoProfile -ExecutionPolicy Bypass -File "#{String.replace(script, "/", "\\")}")
      else
        script = Path.join(root, "hang-#{System.unique_integer([:positive])}.sh")
        File.write!(script, "#!/bin/sh\ncat \"#{source}\"\nsleep 30\n")
        File.chmod!(script, 0o755)
        script
      end
    end
  end
end
