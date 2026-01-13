defmodule QuckChatRealtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :quckchat_realtime,
      version: "1.0.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {QuckChatRealtime.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.7.10"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_dashboard, "~> 0.8.2"},
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:cors_plug, "~> 3.0"},

      # Authentication
      {:guardian, "~> 2.3"},
      {:jose, "~> 1.11"},

      # Database
      {:ecto_sql, "~> 3.11"},
      {:myxql, "~> 0.6"},           # MySQL driver (for real-time queue only)
      {:mongodb_driver, "~> 1.2"},   # MongoDB Atlas (main data)
      {:castore, "~> 1.0"},          # SSL certificates for MongoDB Atlas

      # Redis for distributed state
      {:redix, "~> 1.3"},
      {:phoenix_pubsub_redis, "~> 3.0"},

      # Kafka for event streaming
      {:brod, "~> 3.16"},            # Kafka client
      {:kafka_ex, "~> 0.13"},        # Alternative Kafka client

      # HTTP Client
      {:finch, "~> 0.18"},
      {:req, "~> 0.4"},

      # Telemetry & Monitoring
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:prometheus_ex, "~> 3.0"},
      {:prometheus_plugs, "~> 1.1"},

      # Development
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["test"]
    ]
  end

  defp releases do
    [
      quckchat_realtime: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
