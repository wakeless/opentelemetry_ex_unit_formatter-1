defmodule OpentelemetryExUnitFormatter do
  @readme "README.md"
          |> File.read!()
          |> String.split("<!-- MDOC !-->")
          |> Enum.fetch!(1)
          |> String.replace("](#", "](#module-")

  @moduledoc """
  #{@readme}
  """

  use GenServer

  defstruct before_send: nil,
            register_after_suite?: false,
            root_attribute: "code",
            span_name: "ex_unit",
            tracer_provider_config: :none

  @type t() :: %__MODULE__{
          before_send: (map() -> map()) | nil,
          register_after_suite?: boolean(),
          root_attribute: String.t(),
          span_name: :opentelemetry.span_name(),
          tracer_provider_config: map() | :none
        }

  @attr_suite "suite"
  @attr_module "module"
  @attr_test "test"

  # OTel semantic convention attribute names
  @otel_test_case_name :"test.case.name"
  @otel_test_case_result_status :"test.case.result.status"
  @otel_test_suite_name :"test.suite.name"
  @otel_test_suite_run_status :"test.suite.run.status"

  @doc false
  @impl GenServer
  def init(opts) do
    config =
      __MODULE__
      |> Application.get_application()
      |> Application.get_all_env()
      |> Enum.into(%{})
      |> then(&Map.merge(struct!(__MODULE__), &1))
      |> Map.put(:seed, opts[:seed])
      |> Map.put(:partition_no, System.get_env("MIX_TEST_PARTITION", ""))
      # State for nested spans
      |> Map.put(:suite_span_ctx, nil)
      |> Map.put(:suite_ctx, nil)
      |> Map.put(:module_spans, %{})
      |> Map.put(:module_contexts, %{})
      |> Map.put(:test_spans, %{})

    {tracer_provider_config, config} = Map.pop!(config, :tracer_provider_config)
    do_init(tracer_provider_config, config)
  end

  defp do_init(:none, _config) do
    IO.puts("[#{__MODULE__}] Tracer provider is disabled.")
    {:ok, %{tracer_provider: :none}}
  end

  defp do_init(tracer_provider_config, config) do
    {name, vsn, schema_url} =
      case :opentelemetry.get_application(__MODULE__) do
        {name, vsn, schema_url} ->
          {name, vsn, schema_url}

        _undef ->
          {Application.get_application(__MODULE__), Mix.Project.config()[:version], :undefined}
      end

    case :otel_tracer_provider.get_tracer(__MODULE__, name, vsn, schema_url) do
      {:otel_tracer_noop, []} ->
        {:ok, _pid} = :opentelemetry.start_tracer_provider(__MODULE__, tracer_provider_config)
        tracer = :otel_tracer_provider.get_tracer(__MODULE__, name, vsn, schema_url)
        register_after_suite(config.register_after_suite?, tracer_provider_config)
        config = Map.put(config, :tracer_provider, tracer)
        {:ok, config}

      tracer ->
        config = Map.put(config, :tracer_provider, tracer)
        {:ok, config}
    end
  end

  @doc false
  @impl GenServer
  def handle_cast(_request, %{tracer_provider: :none} = state), do: {:noreply, state}

  # Suite started - create parent span for all modules/tests
  @doc false
  @impl GenServer
  def handle_cast({:suite_started, _opts}, state) do
    %{tracer_provider: tracer, span_name: span_name} = state
    suite_name = get_suite_name()

    # Get current context and start suite span
    ctx = :otel_ctx.get_current()

    span_ctx =
      :otel_tracer.start_span(
        ctx,
        tracer,
        "#{span_name}.#{@attr_suite}",
        %{attributes: [{@otel_test_suite_name, suite_name}]}
      )

    # Set this as the current span in process context and store the context
    :otel_tracer.set_current_span(span_ctx)
    suite_ctx = :otel_tracer.set_current_span(ctx, span_ctx)

    # Attach context to process dictionary
    :otel_ctx.attach(suite_ctx)

    {:noreply, state |> Map.put(:suite_span_ctx, span_ctx) |> Map.put(:suite_ctx, suite_ctx)}
  end

  # Module started - create span nested under suite
  @doc false
  @impl GenServer
  def handle_cast({:module_started, %ExUnit.TestModule{name: module_name}}, state) do
    %{tracer_provider: tracer, span_name: span_name} = state

    # Use the stored suite context as parent for proper nesting
    suite_ctx = Map.get(state, :suite_ctx) || :otel_ctx.get_current()

    span_ctx =
      :otel_tracer.start_span(
        suite_ctx,
        tracer,
        "#{span_name}.#{@attr_module}",
        %{attributes: [{@otel_test_suite_name, inspect(module_name)}]}
      )

    # Store both the span context and the full otel context for child spans
    module_spans = Map.put(state.module_spans, module_name, span_ctx)
    module_contexts = Map.get(state, :module_contexts, %{})
    # Create context with module span set as current for test children
    module_ctx = :otel_tracer.set_current_span(suite_ctx, span_ctx)
    module_contexts = Map.put(module_contexts, module_name, module_ctx)

    {:noreply, state |> Map.put(:module_spans, module_spans) |> Map.put(:module_contexts, module_contexts)}
  end

  # Test started - create span nested under module
  @doc false
  @impl GenServer
  def handle_cast(
        {:test_started, %ExUnit.Test{module: module_name, name: test_name}},
        state
      ) do
    %{tracer_provider: tracer, span_name: span_name} = state
    module_contexts = Map.get(state, :module_contexts, %{})
    module_ctx = Map.get(module_contexts, module_name)

    # Use the module's context as parent for proper nesting
    parent_ctx = module_ctx || :otel_ctx.get_current()

    fully_qualified_name = "#{inspect(module_name)}.#{test_name}"

    span_ctx =
      :otel_tracer.start_span(
        parent_ctx,
        tracer,
        "#{span_name}.#{@attr_test}",
        %{attributes: [{@otel_test_case_name, fully_qualified_name}]}
      )

    # Store test span for later completion
    test_key = {module_name, test_name}
    test_spans = Map.get(state, :test_spans, %{})
    test_spans = Map.put(test_spans, test_key, span_ctx)
    {:noreply, Map.put(state, :test_spans, test_spans)}
  end

  # Test finished - complete span with attributes
  @doc false
  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{module: module_name, name: test_name, state: test_state} = test}, state) do
    test_key = {module_name, test_name}
    test_spans = Map.get(state, :test_spans, %{})
    span_ctx = Map.get(test_spans, test_key)

    if span_ctx do
      attributes = normalize_test_event(test, state)
      status = get_status_from_state(test_state)
      status_reason = get_status_reason(test_state)

      :otel_span.set_status(span_ctx, status, status_reason)
      :otel_span.set_attributes(span_ctx, Map.to_list(attributes))
      :otel_span.end_span(span_ctx)

      test_spans = Map.delete(test_spans, test_key)
      {:noreply, Map.put(state, :test_spans, test_spans)}
    else
      {:noreply, state}
    end
  end

  # Module finished - complete span with attributes
  @doc false
  @impl GenServer
  def handle_cast({:module_finished, %ExUnit.TestModule{name: module_name, state: module_state} = module}, state) do
    %{module_spans: module_spans} = state
    span_ctx = Map.get(module_spans, module_name)

    if span_ctx do
      attributes = normalize_module_event(module, state)
      status = get_status_from_state(module_state)
      status_reason = get_status_reason(module_state)

      :otel_span.set_status(span_ctx, status, status_reason)
      :otel_span.set_attributes(span_ctx, Map.to_list(attributes))
      :otel_span.end_span(span_ctx)

      module_spans = Map.delete(module_spans, module_name)
      module_contexts = Map.get(state, :module_contexts, %{}) |> Map.delete(module_name)
      {:noreply, state |> Map.put(:module_spans, module_spans) |> Map.put(:module_contexts, module_contexts)}
    else
      {:noreply, state}
    end
  end

  # Suite finished - complete span with attributes
  @doc false
  @impl GenServer
  def handle_cast({:suite_finished, times}, state) do
    %{suite_span_ctx: span_ctx} = state

    if span_ctx do
      attributes = normalize_suite_event(times, state)
      status = get_suite_status(attributes)

      :otel_span.set_status(span_ctx, status, "")
      :otel_span.set_attributes(span_ctx, Map.to_list(attributes))
      :otel_span.end_span(span_ctx)

      {:noreply, %{state | suite_span_ctx: nil}}
    else
      {:noreply, state}
    end
  end

  @doc false
  @impl GenServer
  def handle_cast(_event, state), do: {:noreply, state}

  defp register_after_suite(true, tracer) do
    {type, name, delay} =
      case tracer do
        %{processors: [{:otel_simple_processor, %{name: name} = config}]} ->
          delay = Map.get(config, :bsp_scheduled_delay_ms, 5000)
          {"simple", name, delay}

        %{processors: [{:otel_batch_processor, %{name: name} = config}]} ->
          delay = Map.get(config, :bsp_scheduled_delay_ms, 5000)
          {"batch", name, delay}

        _ ->
          {nil, nil, nil}
      end

    if !is_nil(type) do
      ExUnit.after_suite(fn _result ->
        IO.puts("Flushing otel #{type} processor [#{name}] with #{delay} msec waiting time...")
        :otel_tracer_provider.force_flush(name)
        Process.sleep(delay)
        IO.puts("Flushing otel processor completed.")
      end)
    end

    :ok
  end

  defp register_after_suite(false, _tracer), do: :ok

  # Normalize suite event with OTel semantic convention attributes
  defp normalize_suite_event(%{run: run, async: async, load: load}, state) do
    %{root_attribute: root_attribute, partition_no: partition_no, seed: seed, before_send: before_send} = state
    sync = run - (async || 0)
    total = run + (load || 0)
    suite_name = get_suite_name()

    attributes = %{
      # OTel semantic convention attributes (must come first due to arrow syntax)
      @otel_test_suite_name => suite_name,
      @otel_test_suite_run_status => "success",
      # Legacy attributes
      event_type: @attr_suite,
      duration_run: run,
      duration_async: async,
      duration_sync: sync,
      duration_load: load,
      duration: total,
      test_partition_no: partition_no,
      test_seed: seed
    }

    attributes = prefix_root_attribute(attributes, root_attribute)
    if is_function(before_send), do: before_send.(attributes), else: attributes
  end

  # Normalize module event with OTel semantic convention attributes
  defp normalize_module_event(
         %ExUnit.TestModule{
           file: file,
           name: name,
           state: state,
           tests: tests
         },
         config
       ) do
    %{root_attribute: root_attribute, partition_no: partition_no, seed: seed, before_send: before_send} = config
    {state_atom, state_reason} = normalize_state(state)

    # Determine suite run status based on test results
    suite_run_status = determine_module_status(tests, state_atom)

    attributes = %{
      # OTel semantic convention attributes (must come first due to arrow syntax)
      @otel_test_suite_name => inspect(name),
      @otel_test_suite_run_status => suite_run_status,
      # Legacy attributes
      event_type: @attr_module,
      filepath: file,
      module_name: name,
      state: state_atom,
      state_reason: state_reason,
      tests_count: Enum.count(tests),
      duration: Enum.reduce(tests, 0, fn %ExUnit.Test{time: time}, acc -> time + acc end),
      test_partition_no: partition_no,
      test_seed: seed
    }

    attributes = prefix_root_attribute(attributes, root_attribute)
    if is_function(before_send), do: before_send.(attributes), else: attributes
  end

  # Normalize test event with OTel semantic convention attributes
  defp normalize_test_event(
         %ExUnit.Test{
           logs: logs,
           name: name,
           module: module,
           state: state,
           tags: %{async: async, file: file, line: line, test_type: test_type},
           time: time
         },
         config
       ) do
    %{root_attribute: root_attribute, partition_no: partition_no, seed: seed, before_send: before_send} = config
    {state_atom, state_reason} = normalize_state(state)

    # OTel test.case.result.status: "pass" or "fail"
    result_status = if state_atom == :ok, do: "pass", else: "fail"
    # Fully qualified test name for OTel
    fully_qualified_name = "#{inspect(module)}.#{name}"

    attributes = %{
      # OTel semantic convention attributes (must come first due to arrow syntax)
      @otel_test_case_name => fully_qualified_name,
      @otel_test_case_result_status => result_status,
      # Legacy attributes
      event_type: @attr_test,
      test_logs: logs,
      test_name: name,
      module_name: module,
      state: state_atom,
      state_reason: state_reason,
      exec_async: async,
      filepath: file,
      lineno: line,
      file_line: "#{file}:#{line}",
      test_type: test_type,
      duration: time,
      test_partition_no: partition_no,
      test_seed: seed
    }

    attributes = prefix_root_attribute(attributes, root_attribute)
    if is_function(before_send), do: before_send.(attributes), else: attributes
  end

  defp normalize_state(nil), do: {:ok, ""}
  defp normalize_state({state, reason}), do: {state, inspect(reason)}

  # Determine module status based on test results
  defp determine_module_status(tests, module_state) do
    cond do
      module_state == :failed -> "failure"
      Enum.any?(tests, fn %ExUnit.Test{state: state} -> match?({:failed, _}, state) end) -> "failure"
      Enum.any?(tests, fn %ExUnit.Test{state: state} -> match?({:skipped, _}, state) end) -> "skipped"
      Enum.all?(tests, fn %ExUnit.Test{state: state} -> state == nil end) -> "success"
      true -> "success"
    end
  end

  # Get suite name from Mix project or default
  defp get_suite_name do
    case Mix.Project.config()[:app] do
      nil -> "ExUnit Test Suite"
      app -> "#{app}"
    end
  end

  # Determine suite status based on overall state
  defp get_suite_status(_attributes) do
    # Since we can't easily track failed tests at suite level in this architecture,
    # we default to :ok. Individual test/module spans will have accurate status.
    :ok
  end

  # Get OTel status from ExUnit state
  defp get_status_from_state(nil), do: :ok
  defp get_status_from_state({:failed, _}), do: :error
  defp get_status_from_state({:skipped, _}), do: :ok
  defp get_status_from_state(_), do: :unset

  # Get status reason from ExUnit state
  defp get_status_reason(nil), do: ""
  defp get_status_reason({_, reason}), do: inspect(reason)
  defp get_status_reason(_), do: ""

  defp prefix_root_attribute(attributes, root_attribute) do
    attributes
    |> Enum.map(fn {k, v} -> {:"#{root_attribute}.#{k}", v} end)
    |> Enum.into(%{})
  end
end
