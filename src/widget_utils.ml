let get_selectors config =
  Otoml.Helpers.find_strings_opt config ["selector"] |> Option.to_result ~none:"Missing required option \"selector\""

let no_container_action selectors =
  Logs.debug @@ fun m -> m "Page has no elements matching selectors \"%s\", nowhere to insert the snippet"
    (selectors |> String.concat " ")

