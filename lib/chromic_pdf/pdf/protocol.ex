# SPDX-License-Identifier: Apache-2.0

defmodule ChromicPDF.Protocol do
  @moduledoc false

  require Logger
  alias ChromicPDF.Connection.JsonRPC

  # A protocol is a sequence of JsonRPC calls and responses/notifications.
  #
  # * It is created for each client request.
  # * It's goal is to fulfill the client request.
  # * A protocol's `steps` queue is a list of functions. When it is empty, the protocol is done.
  # * Besides, a protocol has a `state` map of arbitrary values.

  @type message :: JsonRPC.message()
  @type dispatch :: (JsonRPC.call() -> JsonRPC.call_id())

  @type state :: map()
  @type error :: {:error, term()}
  @type step :: call_step() | await_step() | output_step()

  # A protocol knows three types of steps: calls, awaits, and output.
  # * The call step is a protocol call to send to the browser. Multiple call steps in sequence
  #   are executed sequentially until the next await step is found.
  # * Await steps are steps that try to match on messages received from the browser. When a
  #   message is matched, the await step is removed from the queue. Multiple await steps in
  #   sequence are matched **out of order** as messages from the browser are often received out
  #   of order as well, from different OS processes.
  # * The output step is a simple function executed at the end of a protocol to send the protocol
  #   result back to the client (using the `result_fun`), applying a mapper function before. If
  #   no output step is defined in a protocol, the client is not sent a reply.

  @type call_fun :: (state(), dispatch() -> state() | error())
  @type call_step :: {:call, call_fun()}

  @type await_fun :: (state(), message() -> :no_match | {:match, state()} | error())
  @type await_step :: {:await, await_fun()}

  @type output_fun :: (state() -> any())
  @type output_step :: {:output, output_fun()}

  @type result :: {:ok, any()} | {:error, term()}
  @type result_fun :: (result() -> any())

  @callback increment_session_use_count?() :: boolean()
  @callback new(keyword()) :: __MODULE__.t()
  @callback new(JsonRPC.session_id(), keyword()) :: __MODULE__.t()

  @type t :: %__MODULE__{
          steps: [step()],
          state: state(),
          result_fun: result_fun() | nil
        }

  @enforce_keys [:steps, :state, :result_fun]
  defstruct [:steps, :state, :result_fun]

  @spec new([step()], state()) :: __MODULE__.t()
  def new(steps, initial_state \\ %{}) do
    %__MODULE__{
      steps: steps,
      state: initial_state,
      result_fun: nil
    }
  end

  @spec init(__MODULE__.t(), result_fun(), dispatch()) :: __MODULE__.t()
  def init(%__MODULE__{} = protocol, result_fun, dispatch) do
    advance(%{protocol | result_fun: result_fun}, dispatch)
  end

  defp advance(%__MODULE__{state: {:error, error}, result_fun: result_fun} = protocol, _dispatch) do
    result_fun.({:error, error})
    %{protocol | steps: []}
  end

  defp advance(%__MODULE__{steps: []} = protocol, _dispatch), do: protocol
  defp advance(%__MODULE__{steps: [{:await, _fun} | _rest]} = protocol, _dispatch), do: protocol

  defp advance(%__MODULE__{steps: [{:call, fun} | rest], state: state} = protocol, dispatch) do
    state = fun.(state, dispatch)
    advance(%{protocol | steps: rest, state: state}, dispatch)
  end

  defp advance(
         %__MODULE__{steps: [{:output, output_fun} | rest], state: state, result_fun: result_fun} =
           protocol,
         dispatch
       ) do
    result_fun.({:ok, output_fun.(state)})
    advance(%{protocol | steps: rest}, dispatch)
  end

  @spec run(__MODULE__.t(), JsonRPC.message(), dispatch()) :: __MODULE__.t()
  def run(protocol, msg, dispatch) do
    warn_on_inspector_crash!(msg)

    protocol
    |> test(msg)
    |> advance(dispatch)
  end

  defp test(%__MODULE__{steps: steps, state: state} = protocol, msg) do
    {awaits, rest} = Enum.split_while(steps, fn {type, _fun} -> type == :await end)

    case do_test(awaits, [], state, msg) do
      {:error, error} -> %{protocol | steps: [], state: {:error, error}}
      {new_head, new_state} -> %{protocol | steps: new_head ++ rest, state: new_state}
    end
  end

  defp do_test([], acc, state, _msg), do: {acc, state}

  defp do_test([{:await, fun} | rest], acc, state, msg) do
    case fun.(state, msg) do
      :no_match -> do_test(rest, acc ++ [{:await, fun}], state, msg)
      {:match, new_state} -> {acc ++ rest, new_state}
      {:error, error} -> {:error, error}
    end
  end

  @spec finished?(__MODULE__.t()) :: boolean()
  def finished?(%__MODULE__{steps: []}), do: true
  def finished?(%__MODULE__{}), do: false

  defp warn_on_inspector_crash!(msg) do
    if match?(%{"method" => "Inspector.targetCrashed"}, msg) do
      Logger.error("""
      ChromicPDF received an 'Inspector.targetCrashed' message.

      This means an active Chrome tab has died and your current operation is going to time out.

      Known causes:

      1) External URLs in `<link>` tags in the header/footer templates cause Chrome to crash.
      2) Shared memory exhaustion can cause Chrome to crash. Depending on your environment, the available shared memory at /dev/shm may be too small for your use-case. This may especially affect you if you run ChromicPDF in a container, as, for instance, the Docker runtime provides only 64 MB to containers by default. Pass --disable-dev-shm-usage as a Chrome flag to use /tmp for this purpose instead (via the `chrome_args` option), or increase the amount of shared memory available to the container (see --shm-size for Docker).
      """)
    end
  end

  defimpl Inspect do
    @filtered "[FILTERED]"

    @allowed_values %{
      result_fun: true,
      steps: true,
      state: %{
        :capture_screenshot => %{
          "format" => true,
          "quality" => true,
          "clip" => true,
          "fromSurface" => true,
          "captureBeyondViewport" => true
        },
        :print_to_pdf => %{
          "landscape" => true,
          "displayHeaderFooter" => true,
          "printBackground" => true,
          "scale" => true,
          "paperWidth" => true,
          "paperHeight" => true,
          "marginTop" => true,
          "marginBottom" => true,
          "marginLeft" => true,
          "marginRight" => true,
          "pageRanges" => true,
          "preferCSSPageSize" => true
        },
        :source_type => true,
        "sessionId" => true,
        :wait_for => true,
        :evaluate => true,
        :size => true,
        :init_timeout => true,
        :timeout => true,
        :offline => true,
        :disable_scripts => true,
        :max_session_uses => true,
        :session_pool => true,
        :no_sandbox => true,
        :discard_stderr => true,
        :chrome_args => true,
        :chrome_executable => true,
        :ignore_certificate_errors => true,
        :ghostscript_pool => true,
        :on_demand => true,
        :__protocol__ => true
      }
    }

    def inspect(%ChromicPDF.Protocol{} = protocol, opts) do
      protocol
      |> Map.from_struct()
      |> filter(@allowed_values)
      |> then(fn map -> struct!(ChromicPDF.Protocol, map) end)
      |> Inspect.Any.inspect(opts)
    end

    defp filter(map, allowed) when is_map(map) and is_map(allowed) do
      Map.new(map, fn {key, value} ->
        case Map.get(allowed, key) do
          nil -> {key, @filtered}
          true -> {key, value}
          nested when is_map(nested) -> {key, filter(value, nested)}
        end
      end)
    end
  end
end
