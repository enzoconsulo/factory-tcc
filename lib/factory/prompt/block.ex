defmodule Factory.Prompt.Block do
  @moduledoc """
  One block of the prompt prefix, with its cache-breakpoint flag and deterministic
  serialization.

  Order and cache marking are properties of the block, not of whoever assembles the prefix.
  """

  @typedoc "The block's place in the prefix order."
  @type kind :: :tools | :doctrine | :index | :task

  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t(),
          cache_breakpoint: boolean()
        }

  defstruct [:kind, :text, cache_breakpoint: false]

  # The order is imposed by the cache: one changed byte invalidates everything AFTER it, so
  # the most stable block comes first.
  @order %{tools: 0, doctrine: 1, index: 2, task: 3}

  @doc "Position of the kind in the assembly order. Lower is more stable."
  @spec position(kind()) :: non_neg_integer()
  def position(kind), do: Map.fetch!(@order, kind)

  @doc "The kinds, from most stable to most volatile."
  @spec kinds() :: [kind()]
  def kinds, do: [:tools, :doctrine, :index, :task]

  @doc """
  Creates a block from any term, serialized DETERMINISTICALLY.

  Maps and keyword lists become text with SORTED keys: Elixir maps do not promise a stable
  iteration order, and a single misplaced key changes the prefix bytes and misses the cache.
  """
  @spec new(kind(), term(), keyword()) :: t()
  def new(kind, content, opts \\ []) do
    %__MODULE__{
      kind: kind,
      text: serialize(content),
      cache_breakpoint: Keyword.get(opts, :cache_breakpoint, kind != :task)
    }
  end

  @doc "Serializes a term stably: collections are always sorted."
  @spec serialize(term()) :: String.t()
  def serialize(text) when is_binary(text), do: text

  def serialize(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{serialize(value)}" end)
  end

  def serialize(list) when is_list(list) do
    if Keyword.keyword?(list) and list != [] do
      list |> Map.new() |> serialize()
    else
      Enum.map_join(list, "\n", &serialize/1)
    end
  end

  def serialize(other), do: to_string(other)
end
