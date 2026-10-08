defmodule Factory.Embedder do
  @moduledoc """
  The embedding contract. The local embedding model is the only heavy piece of the design,
  so embedding is an adapter:

    * `Factory.Embedder.Fake` — deterministic hash vectors; what the test suite always uses.

  `embed/1` always takes a batch: ingestion embeds a whole project history at once.

  ## Documents vs queries

  Some embedding models need different prefixes for indexed documents and for search queries.
  `embed/1` is the document path. The query path is the optional callback `embed_query/1`;
  adapters without per-kind prefixes skip it and `embed_query/2` falls back to `embed/1`.
  """

  @doc """
  Embeds a batch of texts. Output order follows input order; every vector has exactly
  `dimensions/0` positions.
  """
  @callback embed(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}

  @doc "How many positions each vector of this adapter has."
  @callback dimensions() :: pos_integer()

  @doc """
  Embeds a batch of search queries (same shape as `embed/1`, with the query prefix).
  Optional: `Factory.Embedder.embed_query/2` falls back to `embed/1` when it is missing.
  """
  @callback embed_query(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}

  @optional_callbacks embed_query: 1

  @doc "The configured embedder, or `Factory.Embedder.Fake` (the default used by the suite)."
  @spec configured() :: module()
  def configured do
    Application.get_env(:factory, :embedder, Factory.Embedder.Fake)
  end

  @doc "Embeds with the configured embedder."
  @spec embed([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed(texts), do: configured().embed(texts)

  @doc "The dimensions of the configured embedder."
  @spec dimensions() :: pos_integer()
  def dimensions, do: configured().dimensions()

  @doc """
  Embeds search queries with `embedder` (default `configured/0`), using its optional
  `embed_query/1` when exported and `embed/1` otherwise.

  `Code.ensure_loaded?/1` runs first because `function_exported?/3` returns false for a module
  not yet loaded, and in tests code is loaded on demand.
  """
  @spec embed_query([String.t()], module()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_query(texts, embedder \\ configured()) do
    if Code.ensure_loaded?(embedder) and function_exported?(embedder, :embed_query, 1) do
      embedder.embed_query(texts)
    else
      embedder.embed(texts)
    end
  end
end
