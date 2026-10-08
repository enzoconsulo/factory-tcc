defmodule Factory.Prompt.Prefix do
  @moduledoc """
  Builds the STABLE part of the request — the main cost lever.

  Cache reads already dominate input tokens; what remains expensive is cache WRITES, since
  every dispatch is a new session. Writes only turn into reads if the prefix is byte-for-byte
  identical across dispatches. The order is imposed by the API cache:

      1. tools      (identical across dispatches of the same role)  <- cache breakpoint
      2. doctrine   (fixed role text)                               <- cache breakpoint
      3. index      (the code map)                                  <- cache breakpoint
      4. task       (always changes)                                   no breakpoint

  One changed byte invalidates everything AFTER it, so the most stable part comes first.

  The minimum cacheable size is per model and not monotonic:

  | model | minimum |
  |---|---|
  | `opus-5` | 512 |
  | `sonnet-5` | 1024 |
  | `haiku-4.5` | 4096 |

  A prefix below the minimum silently does not cache. `build/2` therefore warns — it does not
  refuse, because a short prefix is inefficient, not invalid.
  """

  require Logger

  alias Factory.Prompt.Block

  @max_breakpoints 4

  @minimums %{"opus-5" => 512, "sonnet-5" => 1024, "haiku-4.5" => 4096}
  @default_minimum 1024

  # A rough estimate (~4 characters per token), used only to decide whether to warn; the real
  # count comes from the API response.
  @chars_per_token 4

  @typedoc "The built prefix, ready for the adapter."
  @type t :: %{
          blocks: [Block.t()],
          text: String.t(),
          cache_breakpoints: non_neg_integer(),
          estimated_tokens: non_neg_integer(),
          cacheable: boolean()
        }

  @doc "The model's minimum cacheable size, or a conservative default for unknown models."
  @spec min_cacheable(String.t()) :: pos_integer()
  def min_cacheable(model), do: Map.get(@minimums, model, @default_minimum)

  @doc "The maximum number of cache breakpoints per request, imposed by the API."
  @spec max_breakpoints() :: pos_integer()
  def max_breakpoints, do: @max_breakpoints

  @doc """
  Builds the prefix from its parts, in stable order, with cache breakpoints marked.

  Parts is a keyword list with `:tools`, `:doctrine`, `:index` and `:task`; a missing part
  produces no block. Extra blocks come only through the explicit `:blocks` option.
  """
  @spec build(String.t(), keyword()) :: t()
  def build(model, parts) do
    blocks =
      Block.kinds()
      |> Enum.flat_map(&kind_blocks(parts, &1))
      |> Kernel.++(Keyword.get(parts, :blocks, []))
      |> Enum.sort_by(&Block.position(&1.kind))
      |> limit_breakpoints()

    text = Enum.map_join(blocks, "\n\n", & &1.text)
    tokens = estimate_tokens(text)
    minimum = min_cacheable(model)

    warn_if_short(model, tokens, minimum)

    %{
      blocks: blocks,
      text: text,
      cache_breakpoints: Enum.count(blocks, & &1.cache_breakpoint),
      estimated_tokens: tokens,
      cacheable: tokens >= minimum
    }
  end

  # ONE block per kind: a list value is content (e.g. the tools) serialized into one block.
  defp kind_blocks(parts, kind) do
    case Keyword.get(parts, kind) do
      nil -> []
      content -> [Block.new(kind, content)]
    end
  end

  # The API rejects more than four breakpoints. Extra marks are removed from the MOST VOLATILE
  # blocks: a breakpoint is worth more at the end of a long stable stretch.
  defp limit_breakpoints(blocks) do
    marked = Enum.count(blocks, & &1.cache_breakpoint)

    if marked <= @max_breakpoints do
      blocks
    else
      excess = marked - @max_breakpoints

      {new_blocks, _} =
        blocks
        |> Enum.reverse()
        |> Enum.map_reduce(excess, fn
          %Block{cache_breakpoint: true} = block, remaining when remaining > 0 ->
            {%{block | cache_breakpoint: false}, remaining - 1}

          block, remaining ->
            {block, remaining}
        end)

      Enum.reverse(new_blocks)
    end
  end

  @doc "Token estimate, ~4 characters each. An estimate, not a count."
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text), do: div(byte_size(text), @chars_per_token)

  defp warn_if_short(_model, tokens, minimum) when tokens >= minimum, do: :ok

  defp warn_if_short(model, tokens, minimum) do
    Logger.warning(
      "prefix of ~#{tokens} tokens is BELOW the minimum cacheable size of #{model}, which is " <>
        "#{minimum}. It will not be cached and the API does not say so: the write is paid and " <>
        "the read never comes. Either the prefix grows or this role should not run on #{model}."
    )

    :ok
  end
end
