defmodule Anemos.Runtime.Watcher do
  @moduledoc """
  Keeps a directory of `*.rule` files deployed into a runtime.

  Each file is a policy, named by its path relative to the directory. Saving
  a file deploys it over the running version; deleting it unloads it. See
  `Anemos.Runtime.load/3` for what a deploy keeps and what it replaces.

      {Anemos.Runtime, name: :anemos, watch: "/etc/anemos/policies"}

  or, under your own supervisor, after the runtime:

      {Anemos.Runtime.Watcher, runtime: :anemos, dir: "/etc/anemos/policies"}

  ## A file that does not load

  The version already running keeps running. The failure is logged once for
  that content and held for `status/1`; the next save tries again. A file
  caught half-written is this case, and corrects itself on the next pass.

  ## Signatures

  `<file>.sig`, if present, is passed to the load authority as the detached
  signature (see `Anemos.Runtime.LoadAuthority.Signed`). Replacing it counts
  as a change to the policy. It holds one signature, Base64, so it serves a
  policy with a single declared signer; one that declares several has to be
  loaded through `Anemos.Runtime.load/3`.

  ## Options

    * `:runtime` — the `Anemos.Runtime` name (required)
    * `:dir` — the directory to watch, searched recursively (required)
    * `:interval_ms` — how often to look, default 1000; `:manual` to look
      only when `scan/1` is called
    * `:name` — process registration name (optional)
  """

  use GenServer

  require Logger

  @type status :: :ok | {:partial, [Anemos.Runtime.load_failure()]} | {:error, term()}

  @doc "Starts a watcher. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Looks at the directory now and deploys what changed."
  @spec scan(GenServer.server()) :: :ok
  def scan(watcher), do: GenServer.call(watcher, :scan, :infinity)

  @doc "The outcome of the last deploy of every policy file present."
  @spec status(GenServer.server()) :: %{String.t() => status()}
  def status(watcher), do: GenServer.call(watcher, :status)

  @impl true
  def init(opts) do
    state = %{
      runtime: Keyword.fetch!(opts, :runtime),
      dir: Keyword.fetch!(opts, :dir),
      interval: Keyword.get(opts, :interval_ms, 1_000),
      # policy id => {content digest, status}
      seen: %{}
    }

    {:ok, state, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state), do: {:noreply, state |> pass() |> tick()}

  @impl true
  def handle_call(:scan, _from, state), do: {:reply, :ok, pass(state)}

  def handle_call(:status, _from, state) do
    {:reply, Map.new(state.seen, fn {id, {_digest, status}} -> {id, status} end), state}
  end

  @impl true
  def handle_info(:scan, state), do: {:noreply, state |> pass() |> tick()}

  defp tick(%{interval: :manual} = state), do: state

  defp tick(state) do
    Process.send_after(self(), :scan, state.interval)
    state
  end

  # ponytail: reads every policy file each pass. Fine for a directory of
  # policies; swap the poll for an inotify source when the count makes it not.
  defp pass(state) do
    present =
      state.dir
      |> Path.join("**/*.rule")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, state.dir), &1})

    seen =
      Enum.reduce(present, state.seen, fn {id, path}, seen ->
        with {:ok, source} <- File.read(path),
             signature = read_signature(path),
             digest = :crypto.hash(:sha256, [source, 0, signature || ""]),
             false <- match?({^digest, _}, Map.get(seen, id)) do
          Map.put(seen, id, {digest, deploy(state.runtime, id, source, signature)})
        else
          # Unchanged, or gone between the listing and the read.
          _ -> seen
        end
      end)

    {kept, gone} = Map.split(seen, Map.keys(present))

    Enum.each(gone, fn {id, _} ->
      Logger.info("[anemos] policy #{id} removed, unloading")
      _ = Anemos.Runtime.unload(state.runtime, id)
    end)

    %{state | seen: kept}
  end

  defp read_signature(path) do
    case File.read(path <> ".sig") do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  defp deploy(runtime, id, source, signature) do
    opts = [policy: id] ++ if(signature, do: [authorization: %{signature: signature}], else: [])

    case Anemos.Runtime.load(runtime, source, opts) do
      :ok ->
        Logger.info("[anemos] policy #{id} deployed")
        :ok

      {:partial, failures} = partial ->
        Logger.warning(
          "[anemos] policy #{id} deployed with #{length(failures)} inert declaration(s)"
        )

        partial

      {:error, reason} = error ->
        # A parse message names a line; a refusal is an ErrorStruct whose
        # message names the authority. Neither carries the source.
        Logger.error(
          "[anemos] policy #{id} not deployed, previous version kept: #{describe(reason)}"
        )

        error
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason), do: Anemos.Redact.summarize(reason)
end
