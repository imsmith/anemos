linkdef virt-9-tuple to mesh.table do
    |> action
    |> publish mesh.table
    |> subscribe mesh.table
    |> report all as event on channel.${SELF_ID} 
end