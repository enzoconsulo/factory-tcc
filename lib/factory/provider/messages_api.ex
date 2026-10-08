defmodule Factory.Provider.MessagesAPI do
  @moduledoc """
  Provider that talks HTTP directly to the Anthropic Messages API, with explicit control of
  prompt-cache breakpoints and TTL.

  It uses plain `Req` instead of an SDK because the factory must decide, request by request,
  where to place cache breakpoints and which TTL to ask for; a convenience layer hides
  exactly that. Cache writes are a large share of the input bill, since every dispatch is a
  new session writing a new prefix.

  The body order is imposed by the API: `tools -> system -> messages`. Changing one byte
  invalidates everything after it, so `cache_control` goes on the LAST block of each stable
  band, with `ttl: "1h"` (writes cost 2.0x instead of 1.25x but survive the minutes a
  verifier's battery takes). Three pitfalls are handled:

    1. **20-block window.** A breakpoint looks back at most 20 blocks for a previous entry;
       long tool-use turns would silently miss the cache, so an intermediate breakpoint is
       placed every 15 messages.
    2. **Identical parallel requests do not share cache.** In a fan-out, send one, wait, then
       the rest.
    3. **Per-task instructions** go as a `system` message INSIDE `messages`, never by editing
       the top-level `system`, which would invalidate the cached history.

  The gain is checked by `cache_read_input_tokens` in the response: zero on repeated requests
  with the same prefix means a silent invalidator somewhere.

  `ANTHROPIC_API_KEY` is read only here, and only at call time; a test enforces that no
  other module reads it. **This provider costs real money**, unlike `ClaudeCLI`, which runs
  on the subscription.
  """

  @behaviour Factory.Provider

  alias Factory.Provider.Block
  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage

  @url "https://api.anthropic.com/v1/messages"
  @version "2023-06-01"
  @max_breakpoints 4
  @block_window 15

  @doc "Window between intermediate cache breakpoints, below the API's 20."
  @spec block_window() :: pos_integer()
  def block_window, do: @block_window

  @impl Factory.Provider
  def chat(%Request{} = request, opts) do
    body = build(request, opts)

    case post(body, opts) do
      {:ok, %{status: 200, body: response}} -> {:ok, translate(response)}
      {:ok, %{status: 429, body: body}} -> {:error, {:quota, reopens_at(body)}}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the request body. Public so tests can inspect it without network access.
  """
  @spec build(Request.t(), keyword()) :: map()
  def build(%Request{} = request, opts \\ []) do
    %{
      model: request.model,
      max_tokens: Keyword.get(opts, :max_tokens, 8_192),
      tools: tools(request),
      system: system(request),
      messages: messages(request, opts)
    }
  end

  # Band 1: tools, identical across dispatches of the same role.
  defp tools(%Request{tools: []}), do: []

  defp tools(%Request{tools: tools}) do
    tools
    |> Enum.map(fn
      %{} = tool ->
        tool

      name ->
        %{name: to_string(name), description: to_string(name), input_schema: %{type: "object"}}
    end)
    |> mark_last()
  end

  # Bands 2 and 3: doctrine and index, as `system` blocks; only the last gets a breakpoint.
  defp system(%Request{prefix: []}), do: []

  defp system(%Request{prefix: blocks}) do
    blocks
    |> Enum.map(fn %Block{} = block -> %{type: "text", text: block.text} end)
    |> mark_last()
  end

  defp mark_last([]), do: []

  defp mark_last(blocks) do
    {head, [last]} = Enum.split(blocks, -1)
    head ++ [Map.put(last, :cache_control, %{type: "ephemeral", ttl: "1h"})]
  end

  defp messages(%Request{messages: messages}, opts) do
    messages
    |> Enum.map(&translate_message/1)
    |> insert_instruction(Keyword.get(opts, :task_instruction))
    |> mark_intermediates(available_breakpoints(messages))
  end

  defp translate_message(%{role: role, content: content}) do
    %{role: api_role(role), content: content}
  end

  defp translate_message(other), do: other

  defp api_role(:assistant), do: "assistant"
  defp api_role(:user), do: "user"
  defp api_role(:system), do: "system"
  defp api_role(other), do: to_string(other)

  defp insert_instruction(messages, nil), do: messages

  defp insert_instruction(messages, instruction) do
    messages ++ [%{role: "system", content: instruction}]
  end

  defp mark_intermediates(messages, 0), do: messages

  defp mark_intermediates(messages, available) do
    total = length(messages)

    if total <= @block_window do
      messages
    else
      apply_breakpoints(messages, intermediate_positions(total, available))
    end
  end

  defp apply_breakpoints(messages, positions) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      if index in positions, do: mark_message(message), else: message
    end)
  end

  defp intermediate_positions(total, available) do
    @block_window
    |> Stream.iterate(&(&1 + @block_window))
    |> Stream.take_while(&(&1 < total))
    |> Enum.take(available)
    |> MapSet.new()
  end

  # The API allows 4 breakpoints; the stable bands take precedence over intermediates.
  defp available_breakpoints(_messages), do: max(@max_breakpoints - 2, 0)

  defp mark_message(%{content: content} = message) when is_binary(content) do
    %{
      message
      | content: [
          %{type: "text", text: content, cache_control: %{type: "ephemeral", ttl: "1h"}}
        ]
    }
  end

  defp mark_message(%{content: content} = message) when is_list(content) do
    %{message | content: mark_last(content)}
  end

  defp mark_message(message), do: message

  defp post(body, opts) do
    request =
      [
        url: @url,
        json: body,
        headers: headers(),
        receive_timeout: Keyword.get(opts, :timeout, 600_000)
      ]
      |> Keyword.merge(Keyword.take(opts, [:plug, :req]))
      |> Req.new()

    Req.post(request)
  end

  defp headers do
    [
      {"x-api-key", System.get_env("ANTHROPIC_API_KEY") || ""},
      {"anthropic-version", @version},
      {"content-type", "application/json"}
    ]
  end

  defp translate(%{"content" => content} = response) do
    %Response{
      blocks: Enum.map(content, &translate_block/1),
      stop_reason: stop_reason(response["stop_reason"]),
      usage: usage(response["usage"] || %{})
    }
  end

  defp translate(_other), do: %Response{blocks: [], stop_reason: :refusal, usage: %Usage{}}

  defp translate_block(%{"type" => "text", "text" => text}), do: %{type: :text, text: text}

  defp translate_block(%{"type" => "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block["id"],
      name: block["name"],
      arguments: block["input"] || %{}
    }
  end

  defp translate_block(other), do: %{type: :unknown, raw: other}

  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("refusal"), do: :refusal
  defp stop_reason(_), do: :end_turn

  defp usage(raw) do
    %Usage{
      input_tokens: number(raw["input_tokens"]),
      cache_write_tokens: number(raw["cache_creation_input_tokens"]),
      cache_read_tokens: number(raw["cache_read_input_tokens"]),
      output_tokens: number(raw["output_tokens"]),
      # Unlike the CLI, the TTL is known here: we asked for it.
      cache_ttl: :one_hour
    }
  end

  defp number(value) when is_integer(value), do: value
  defp number(_), do: 0

  defp reopens_at(%{"error" => %{"resets_at" => value}}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp reopens_at(_body), do: nil
end
