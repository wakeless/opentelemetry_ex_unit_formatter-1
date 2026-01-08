defmodule OpentelemetryExUnitFormatter.MixProject do
  use Mix.Project

  @source_url "https://github.com/Recruitee/opentelemetry_ex_unit_formatter"
  @version "0.1.0"

  def project do
    [
      app: :opentelemetry_ex_unit_formatter,
      version: @version,
      name: "OpentelemetryExUnitFormatter",
      description: "Opentelemetry instrumentation for `ExUnit.Formatter`.",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application(), do: []

  defp deps() do
    [
      {:credo, "~> 1.7.11", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.10", only: :test, runtime: false},
      {:opentelemetry, "~> 1.2"},
      {:opentelemetry_exporter, "~> 1.8", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs CHANGELOG.md README.md),
      maintainers: ["Recruitee", "Andrzej Magdziarz"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, Changelog: "#{@source_url}/blob/master/CHANGELOG.md"}
    ]
  end

  defp docs do
    [
      main: "OpentelemetryExUnitFormatter",
      source_url: @source_url,
      source_ref: "v#{@version}",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end
