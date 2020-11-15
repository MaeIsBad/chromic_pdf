defmodule ChromicPDF do
  @moduledoc """
  ChromicPDF is a fast HTML-to-PDF/A renderer based on Chrome & Ghostscript.

  ## Usage

  ### Start

  Start ChromicPDF as part of your supervision tree:

      def MyApp.Application do
        def start(_type, _args) do
          children = [
            # other apps...
            {ChromicPDF, chromic_pdf_opts()}
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end

        defp chromic_pdf_opts do
          []
        end
      end

  ### Print a PDF or PDF/A

      ChromicPDF.print_to_pdf({:url, "file:///example.html"}, output: "output.pdf")

  See `ChromicPDF.print_to_pdf/2` and `ChromicPDF.convert_to_pdfa/2`.

  ## Options

  ### Worker pools

  ChromicPDF spawns two worker pools, the session pool and the ghostscript pool. By default, it
  will create as many sessions (browser tabs) as schedulers are online, and allow the same number
  of concurrent Ghostscript processes to run. To change these options, you can pass configuration
  to the supervisor. Please note that these are non-queueing worker pools. If you intend to max
  them out, you will need a job queue as well.

      defp chromic_pdf_opts do
        [
          session_pool: [size: 3]
          ghostscript_pool: [size: 10]
        ]
      end

  ### Automatic session restarts to avoid memory drain

  By default, ChromicPDF will restart sessions within the Chrome process after 1000 operations.
  This helps to prevent infinite growth in Chrome's memory consumption. The "max age" of a session
  can be configured with the `:max_session_uses` option.

      defp chromic_pdf_opts do
        [max_session_uses: 1000]
      end

  ## Security Considerations

  Before adding a browser to your application's (perhaps already long) list of dependencies, you
  may want consider the security hints below.

  ### Escape user-supplied data

  Make sure to escape any user-provided data with something like [`Phoenix.HTML.html_escape`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.html#html_escape/1).
  Chrome is designed to make displaying HTML pages relatively safe, in terms of preventing
  undesired access of a page to the host operating system. However, the attack surface of your
  application is still increased. Running this in a containerized application with a small RPC
  interface creates an additional barrier (and has other benefits).

  ### Running in offline mode

  For some apparent security bonus, browser targets can be spawned in "offline mode" (using the
  DevTools command [`Network.emulateNetworkConditions`](https://chromedevtools.github.io/devtools-protocol/tot/Network#method-emulateNetworkConditions).
  Chrome targets with network conditions set to `offline` can't resolve any external URLs (e.g.
  `https://`), neither entered as navigation URL nor contained within the HTML body.

      def chromic_pdf_opts do
        [offline: true]
      end

  ### Chrome Sandbox

  By default, ChromicPDF will run Chrome targets in a sandboxed OS process. If you absolutely
  must run Chrome as root, you can turn of its sandbox by passing the `no_sandbox: true` option.

      defp chromic_pdf_opts do
        [no_sandbox: true]
      end

  ## Debugging Chrome errors

  Chrome's stderr logging is silently discarded to not obscure your logfiles. In case you would
  like to take a peek, add the `discard_stderr: false` option.

      defp chromic_pdf_opts do
        [discard_stderr: false]
      end

  ## Starting & stopping Chrome on demand

  ChromicPDF tries its best to clean up after itself by closing external Chrome processes on
  shutdown. Unfortunately it is not possible to perform a graceful shutdown when a BEAM instance
  is killed with the Ctrl+C abort mechanism (see issue [#56](https://github.com/bitcrowd/chromic_pdf/issues/56)).

  In case you habitually end your development server with Ctrl+C, you should consider enabling "On
  Demand" mode which disables the session pool, and instead starts and stops Chrome instances as
  needed.

      defp chromic_pdf_opts do
        [on_demand: true]
      end

  To enable it only for development, you can load the option from the application environment.

      # config/config.exs
      config :my_app, ChromicPDF, on_demand: false

      # config/dev.exs
      config :my_app, ChromicPDF, on_demand: true

      # application.ex
      @chromic_pdf_opts Application.compile_env!(:my_app, ChromicPDF)
      defp chromic_pdf_opts do
        @chromic_pdf_opts ++ [... other opts ...]
      end

  Be aware that each print job will have an increased runtime (plus about 0.5s) due to the added
  Chrome boot time cost.

  ## Telemetry support

  To provide insights into PDF and PDF/A generation performance, ChromicPDF executes the
  following telemetry events:

  * `[:chromic_pdf, :print_to_pdf, :start | :stop | exception]`
  * `[:chromic_pdf, :capture_screenshot, :start | :stop | :exception]`
  * `[:chromic_pdf, :convert_to_pdfa, :start | :stop | exception]`

  Please see [`:telemetry.span/3`](https://hexdocs.pm/telemetry/telemetry.html#span-3) for
  details on their payloads, and [`:telemetry.attach/4`](https://hexdocs.pm/telemetry/telemetry.html#attach-4)
  for how to attach to them.

  Each of the corresponding functions accepts a `telemetry_metadata` option which is passed to
  the attached event handler. This can, for instance, be used to mark events with custom tags such
  as the type of the print document.

      ChromicPDF.print_to_pdf(..., telemetry_metadata: %{template: "invoice"})

  The `print_to_pdfa` function emits both the `print_to_pdf` and `convert_to_pdfa` event series,
  in that order.

  ## How it works

  ### PDF Printing

  * ChromicPDF spawns an instance of Chromium/Chrome (an OS process) and connects to its
    "DevTools" channel via file descriptors.
  * The Chrome process is supervised and the connected processes will automatically recover if it
    crashes.
  * A number of "targets" in Chrome are spawned, 1 per worker process in the `SessionPool`. By
    default, ChromicPDF will spawn each session in a new browser context (i.e., a profile).
  * When a PDF print is requested, a session will instruct its assigned "target" to navigate to
    the given URL, then wait until it receives a "frameStoppedLoading" event, and proceed to call
    the `printToPDF` function.
  * The printed PDF will be sent to the session as Base64 encoded chunks.

  ### PDF/A Conversion

  * To convert a PDF to a PDF/A-3, ChromicPDF uses the [ghostscript](https://ghostscript.com/)
    utility.
  * Since it is required to embed a color scheme into PDF/A files, ChromicPDF ships with a copy
    of the royalty-free [`eciRGB_V2`](http://www.eci.org/) scheme by the European Color
    Initiative. If you need to be able a different color scheme, please open an issue.
  """

  use ChromicPDF.Supervisor
end
