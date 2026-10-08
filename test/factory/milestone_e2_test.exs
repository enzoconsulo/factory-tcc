defmodule Factory.MilestoneE2Test do
  @moduledoc """
  Proof of the E2 milestone: the whole suite runs without network, without quota and without
  an API key. It tests an impossibility, so it keeps running forever: a milestone proved once
  and forgotten becomes false with the first new dependency.

  The guarantee is "nothing leaves the machine during the suite", not "there is no HTTP
  library":

    * every `Req` request goes to a Plug that raises (`Factory.NoNetwork`);
    * only the network owner (`MessagesAPI`) may reference `Req`, and no production file
      opens sockets by hand;
    * exactly ONE module reads credentials (`MessagesAPI`), and the credential variables are
      not even set in the suite's environment;
    * the configured adapters are the fakes, and no embedding model library is loadable.
  """

  use ExUnit.Case, async: true

  doctest Factory.Source

  alias Factory.Embedder
  alias Factory.Provider

  # Independent HTTP clients that no adapter uses. `Finch` and `Mint` are Req's transport.
  @foreign_clients [HTTPoison, Tesla]
  @foreign_apps [:hackney, :gun, :ibrowse, :httpoison, :tesla]

  # The only module allowed to read credentials: exclusivity is the guarantee.
  @network_owner "lib/factory/provider/messages_api.ex"

  # Modules allowed to speak HTTP (reference `Req`). They all run under the raising double.
  @network_owners [@network_owner]

  defp production_sources, do: Path.wildcard("lib/**/*.ex")

  # Code only: an environment variable cited in prose documents, it does not read.
  defdelegate strip(text), to: Factory.Source
  defdelegate code_only(file), to: Factory.Source

  describe "no network: nothing LEAVES the machine" do
    test "Req runs with a double for the whole suite" do
      assert Code.ensure_loaded?(Req), "Req is a dependency and should be available"

      assert Application.get_env(:req, :default_options)[:plug] == Factory.NoNetwork,
             """
             Req is not in test mode. Without it, a misconfigured adapter would make a REAL
             call during `mix test`, spending money and breaking this milestone silently.
             """
    end

    test "the global double RAISES instead of answering" do
      assert_raise RuntimeError, ~r/tried to LEAVE during the test suite/, fn ->
        Req.get!(url: "https://api.anthropic.com/v1/messages")
      end
    end

    test "no foreign HTTP client is loadable" do
      for module <- @foreign_clients do
        refute Code.ensure_loaded?(module),
               "#{inspect(module)} is available, and no adapter of this system uses it."
      end
    end

    test "no foreign HTTP client application is running" do
      running = Enum.map(Application.started_applications(), fn {name, _, _} -> name end)

      for app <- @foreign_apps do
        refute app in running, "application #{app} is running during the suite."
      end
    end

    test "only the HTTP adapters reference Req" do
      pattern = ~r/(?<![A-Za-z0-9_.])Req(?![A-Za-z0-9_])/

      for file <- production_sources(), file not in @network_owners do
        refute Regex.match?(pattern, File.read!(file)),
               "#{file} references Req. Only the network owners may: #{inspect(@network_owners)}."
      end
    end

    test "no production source opens a socket by hand" do
      for file <- production_sources(), forbidden <- ~w[gen_tcp httpc inets] do
        refute Regex.match?(~r/:#{forbidden}\b/, code_only(file)),
               "#{file} uses :#{forbidden}"
      end
    end

    test "the reference detector works and does not pass on empty input" do
      pattern = ~r/(?<![A-Za-z0-9_.])Req(?![A-Za-z0-9_])/

      assert Regex.match?(pattern, "Req.post!(url)")
      refute Regex.match?(pattern, "%Request{}")
      assert production_sources() != [], "the source list cannot be empty"
    end
  end

  describe "no quota and no API key" do
    test "EXACTLY ONE module reads environment variables" do
      readers = Enum.filter(production_sources(), &(code_only(&1) =~ "System.get_env"))

      assert readers == [@network_owner],
             "environment variable read outside the network adapter: #{inspect(readers)}"
    end

    test "EXACTLY ONE module cites ANTHROPIC_API_KEY in code" do
      readers = Enum.filter(production_sources(), &(code_only(&1) =~ "ANTHROPIC_API_KEY"))

      assert readers == [@network_owner]
    end

    test "no production source contains a literal secret" do
      # "sk-ant-" is the shape of an Anthropic key; searched in the WHOLE file, docs included.
      for file <- production_sources() do
        refute File.read!(file) =~ "sk-ant-", "#{file} contains a literal secret (sk-ant-)"
      end

      # "Bearer " is a header scheme: network owners build it from a configured key, so they
      # are exempt from this check only.
      for file <- production_sources(), file not in @network_owners do
        refute File.read!(file) =~ "Bearer ", "#{file} contains a literal secret (Bearer )"
      end
    end

    test "credential variables are not set in the suite's environment" do
      for variable <- ~w[ANTHROPIC_API_KEY OPENAI_API_KEY] do
        assert System.get_env(variable) == nil,
               "#{variable} is set. The suite must not even be able to spend quota."
      end
    end

    test "the docstring filter works and does not pass on empty input" do
      with_code = "defmodule X do\n  System.get_env(\"API_KEY\")\nend"
      prose_only = "defmodule X do\n  @moduledoc \"\"\"\n  runs without API_KEY\n  \"\"\"\nend"

      assert strip(with_code) =~ "API_KEY"
      refute strip(prose_only) =~ "API_KEY"
    end
  end

  describe "the suite's adapters are the doubles" do
    test "the configured provider is Fake" do
      assert Provider.configured() == Factory.Provider.Fake
    end

    test "the configured embedder is Fake" do
      assert Embedder.configured() == Factory.Embedder.Fake
    end

    test "no embedding model library is loaded" do
      for module <- [Bumblebee, Nx, EXLA, Axon] do
        refute Code.ensure_loaded?(module),
               "#{inspect(module)} is available. The target profile is 8 GB of RAM, and the " <>
                 "local model is optional (FACTORY_EMBEDDER_LOCAL=1)."
      end
    end
  end
end
