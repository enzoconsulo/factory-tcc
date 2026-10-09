defmodule Factory.EmbedderTest do
  @moduledoc """
  Tests the `Factory.Embedder.embed_query/1,2` facade: it uses the adapter's OPTIONAL
  `embed_query/1` callback when exported, and falls back to `embed/1` otherwise.
  `async: false` because some tests change the global `:embedder` application env.
  """

  use ExUnit.Case, async: false

  alias Factory.Embedder

  # Exports the optional callback; distinct vectors show which function was called.
  defmodule WithPerTypePrefix do
    @moduledoc false
    @behaviour Factory.Embedder

    @impl true
    def dimensions, do: 4

    @impl true
    def embed(texts), do: {:ok, Enum.map(texts, fn _ -> [1.0, 0.0, 0.0, 0.0] end)}

    @impl true
    def embed_query(texts), do: {:ok, Enum.map(texts, fn _ -> [0.0, 1.0, 0.0, 0.0] end)}
  end

  defmodule WithoutPerTypePrefix do
    @moduledoc false
    @behaviour Factory.Embedder

    @impl true
    def dimensions, do: 4

    @impl true
    def embed(texts), do: {:ok, Enum.map(texts, fn _ -> [0.0, 0.0, 1.0, 0.0] end)}
  end

  defp configure_embedder(module) do
    previous = Application.get_env(:factory, :embedder)
    Application.put_env(:factory, :embedder, module)

    on_exit(fn ->
      if previous do
        Application.put_env(:factory, :embedder, previous)
      else
        Application.delete_env(:factory, :embedder)
      end
    end)
  end

  describe "embed_query/2 — optional callback per adapter" do
    test "uses the adapter's embed_query/1 when exported" do
      {:ok, vectors} = Embedder.embed_query(["term"], WithPerTypePrefix)
      assert vectors == [[0.0, 1.0, 0.0, 0.0]]
    end

    test "falls back to embed/1 when the adapter does not export embed_query/1" do
      {:ok, vectors} = Embedder.embed_query(["term"], WithoutPerTypePrefix)
      assert vectors == [[0.0, 0.0, 1.0, 0.0]]
    end
  end

  describe "embed_query/1 — uses the configured embedder" do
    test "delegates to configured/0 when the adapter has the callback" do
      configure_embedder(WithPerTypePrefix)

      {:ok, vectors} = Embedder.embed_query(["term"])
      assert vectors == [[0.0, 1.0, 0.0, 0.0]]
    end

    test "delegates to configured/0 and falls back to embed/1 without the callback" do
      configure_embedder(WithoutPerTypePrefix)

      {:ok, vectors} = Embedder.embed_query(["term"])
      assert vectors == [[0.0, 0.0, 1.0, 0.0]]
    end
  end
end
