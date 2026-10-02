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

  The version already running keeps running. The failure is logged once and
  held for `status/1`. It is tried again on every pass, because what stopped
  it may not be in the file: a rule name still held by a file that is about
  to lose it, a feed handler the host has not registered yet. A file caught
  half-written is this case too, and corrects itself on the next pass.

  ## A directory that is not there

  Nothing is unloaded. A missing directory is not an empty one.

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

  alias Anemos.Runtime.StateTable

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
    runtime = Keyword.fetch!(opts, :runtime)
    dir = Keyword.fetch!(opts, :dir)
    table = StateTable.name_for(runtime)

    state = %{
      runtime: runtime,
      dir: dir,
      interval: Keyword.get(opts, :interval_ms, 1_000),
      table: if(:ets.whereis(table) == :undefined, do: nil, else: table),
      missing?: false,
      # policy id => {content digest, status}
      seen: %{}
    }

    # What a previous watcher of this directory deployed is still deployed —
    # the policy store outlives us both. Starting from nothing would forget
    # a file that was deleted while no watcher was running.
    {:ok, %{state | seen: StateTable.get(state.table, {:watcher, dir}, %{})}, {:continue, :scan}}
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

  # A directory that is not there is not an empty directory. Unmounted,
  # renamed mid-deploy, or not created yet: none of them means "unload
  # everything", which is what an empty listing would be taken for.
  defp pass(state) do
    cond do
      File.dir?(state.dir) ->
        scan_dir(%{state | missing?: false})

      state.missing? ->
        state

      true ->
        Logger.warning(
          "[anemos] watched path #{state.dir} is not a directory; leaving what is deployed alone"
        )

        %{state | missing?: true}
    end
  end

  # ponytail: reads every policy file each pass. Fine for a directory of
  # policies; swap the poll for an inotify source when the count makes it not.
  defp scan_dir(state) do
    present =
      state.dir
      |> Path.join("**/*.rule")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, state.dir), &1})

    # A policy this watcher deployed that is no longer loaded — unloaded
    # by hand, or by a rule — is forgotten here, so the file deploys again
    # on this pass. The file is the policy; what was done behind the
    # watcher's back does not outlast its next look.
    loaded = MapSet.new(Anemos.Runtime.policies(state.runtime), & &1.id)

    seen =
      Map.reject(state.seen, fn {id, {_digest, status}} ->
        status == :ok and not MapSet.member?(loaded, id)
      end)

    # Unloads first. A renamed file, or a rule moved to another file, is a
    # deploy of a name the old policy still holds until it is gone.
    {kept, gone} = Map.split(seen, Map.keys(present))

    Enum.each(gone, fn {id, _} ->
      Logger.info("[anemos] policy #{id} removed, unloading")
      _ = Anemos.Runtime.unload(state.runtime, id)
    end)

    seen =
      Enum.reduce(present, kept, fn {id, path}, seen ->
        case File.read(path) do
          {:ok, source} ->
            signature = read_signature(path)
            digest = :crypto.hash(:sha256, [source, 0, signature || ""])
            Map.put(seen, id, visit(state.runtime, id, source, signature, digest, seen[id]))

          # Gone between the listing and the read; the next pass unloads it.
          {:error, _} ->
            seen
        end
      end)

    :ok = StateTable.put(state.table, {:watcher, state.dir}, seen)
    %{state | seen: seen}
  end

  # Deployed and unchanged: nothing to do.
  defp visit(_runtime, _id, _source, _signature, digest, {digest, :ok} = entry)
       when is_binary(digest),
       do: entry

  # Everything else is deployed: a new or changed file, and also an
  # unchanged one that did not fully load last time. What stopped it may
  # have been outside the file — a name another policy held, a feed handler
  # not registered yet — so it is tried again each pass, and reported only
  # when the outcome changes.
  defp visit(runtime, id, source, signature, digest, previous) do
    opts = [policy: id] ++ if(signature, do: [authorization: %{signature: signature}], else: [])
    entry = {digest, Anemos.Runtime.load(runtime, source, opts)}
    if entry != previous, do: report(id, elem(entry, 1))
    entry
  end

  defp read_signature(path) do
    case File.read(path <> ".sig") do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  defp report(id, :ok), do: Logger.info("[anemos] policy #{id} deployed")

  defp report(id, {:partial, failures}) do
    Logger.warning("[anemos] policy #{id} deployed with #{length(failures)} inert declaration(s)")
  end

  # A parse message names a line and may quote the token it stopped at; a
  # refusal names the authority or the policy that holds the name. This is
  # the author's own text going to the author's own log.
  defp report(id, {:error, reason}) do
    Logger.error("[anemos] policy #{id} not deployed, previous version kept: #{describe(reason)}")
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason), do: Anemos.Redact.summarize(reason)
end
