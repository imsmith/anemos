defmodule Anemos.Runtime.Modules.Policy do
  @moduledoc """
  `[POLICY::unload "id"]` — a policy that removes another.

  Registered as `POLICY` in every `Anemos.Runtime`. This is the gated way
  to unload: the rule that calls it came through `Anemos.Runtime.load/3`
  and whatever authority stands there, so a signed policy can retire
  another by name without `unload/2` needing an authority of its own
  (A-81).

  The unload is asked for, not done on the spot: the verb runs inside the
  dispatcher, which is the process that has to do the removing. It is
  carried out as soon as the dispatch that asked for it has finished.
  """

  use Anemos.Module, name: "POLICY"

  verb :unload, fn
    [id], %{_runtime: runtime} when is_binary(id) and id != "" ->
      Task.start(fn -> Anemos.Runtime.unload(runtime, id) end)
      {:ok, %{unload_requested: id}}

    [_id], _context ->
      {:error, :not_in_a_runtime}

    _args, _context ->
      {:error, :unload_takes_one_policy_name}
  end
end
