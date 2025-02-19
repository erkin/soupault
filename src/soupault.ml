open Soupault_common
open Defaults

module FU = FileUtil
module FP = FilePath

(* Result monad *)
let (>>=) = Stdlib.Result.bind
let (let*) = (>>=)

let mkdir dir =
  (* Note: FileUtil.mkdir returns success if the directory
     already exists, this is why it's not checked before creation. *)
  try Ok (FU.mkdir ~parent:true dir)
  with FileUtil.MkdirError e -> Error e

(*** Logging setup ***)

let get_color_style () =
  (* Most Windows terminals don't support ANSI colors at all,
     so we automatically disable it on that platform.
     If there's a good way to test if the terminal actually supports it,
     then this check can be made more granular.
   *)
  if Sys.win32 then `None else
  (* See https://no-color.org/
     All command-line software which outputs text with ANSI color added
     should check for the presence of a NO_COLOR environment variable that, when present
     (regardless of its value), prevents the addition of ANSI color.
   *)
  let no_color = Sys.getenv_opt "NO_COLOR" |> Option.is_some in
  (* Logs always go to stderr, so we don't check stdout. *)
  let interactive = Unix.isatty (Unix.descr_of_out_channel stderr) in
  if interactive && (not no_color) then `Ansi_tty else `None 

let color_level ppf l =
  let app_style = `Cyan in
  let err_style = `Red in
  let warn_style = `Yellow in
  let info_style = `Green in
  let debug_style = `Blue in
  let f ppf style l =
    Fmt.pf ppf "%a" Fmt.(styled style string)
      (Logs.level_to_string (Some l) |> String.uppercase_ascii)
  in
  let l = if Option.is_none l then Logs.App else Option.get l in
  match l with
  | Logs.App ->
    f ppf app_style l
  | Logs.Error ->
    f ppf err_style l
  | Logs.Warning ->
    f ppf warn_style l
  | Logs.Info ->
    f ppf info_style l
  | Logs.Debug ->
    f ppf debug_style l

(* Omit the executable name from the logs, the user knows already *)
let pp_header ppf (l, h) =
  match h with
  | None -> if l = Logs.App then () else Format.fprintf ppf "[%a] " color_level (Some l)
  | Some h -> Format.fprintf ppf "[%s] " h

let log_reporter = Logs.format_reporter ~pp_header:pp_header  ()

let setup_logging verbose debug =
  let level =
    if debug then Logs.Debug
    else if verbose then Logs.Info
    else Logs.Warning
  in
  let style = get_color_style () in
  Logs.set_level (Some level);
  Fmt_tty.setup_std_outputs ~style_renderer:style ();
  Logs.set_reporter log_reporter;
  (* Enable exception tracing if debug=true *)
  if debug then Printexc.record_backtrace true

(*** Filesystem stuff ***)
let (+/) left right =
    FP.concat left right

let list_dirs path =
    FU.ls path |> FU.filter FU.Is_dir

let make_build_dir build_dir =
  if (FU.test FU.Exists build_dir) then Ok () else
  let () = Logs.info @@ fun m -> m "Build directory \"%s\" does not exist, creating" build_dir in
  mkdir build_dir

(** Produces a target directory name for the page.

    If clean URLs are used, then a subdirectory matching the page name
    should be created inside the section directory, unless the page is
    a section index page.
    E.g. "site/foo.html" becomes "build/foo/index.html" to provide
    a clean URL.

    If clean URLs are not used, only section dirs are created.
 *)
let make_page_dir_name settings target_dir page_name =
  if (page_name = settings.index_page) || (not settings.clean_urls) then target_dir
  else target_dir +/ page_name

let load_html settings soupault_config hooks page_file =
  let load_file preprocessor page_file =
    try
    match preprocessor with
    | None -> Ok (Soup.read_file page_file)
    | Some prep ->
      let prep_cmd = Printf.sprintf "%s %s" prep (Filename.quote page_file) in
      let () = Logs.info @@ fun m -> m "Calling preprocessor \"%s\" on page %s" (String.escaped prep) page_file in
      Process_utils.get_program_output prep_cmd
    with Sys_error e -> Error e
  in
  let ext = Utils.get_extension page_file in
  let preprocessor = List.assoc_opt ext settings.preprocessors in
  let* page_source = load_file preprocessor page_file in
  let pre_parse_hook = Hashtbl.find_opt hooks "pre-parse" in
  let* page_source =
    match pre_parse_hook with
    | Some (file_name, source_code, hook_config) ->
      if Hooks.hook_should_run settings hook_config "pre-parse" page_file then
        let () = Logs.info @@ fun m -> m "Running the \"pre-parse\" hook on page %s" page_file in
        Hooks.run_pre_parse_hook settings soupault_config hook_config file_name source_code page_file page_source
      else Ok page_source
    | None -> Ok page_source
  in
  (* As of lambdasoup 0.7.2, Soup.parse never fails, only returns empty element trees. *)
  Ok (Soup.parse page_source)

let run_render_hook settings config hooks env soup =
  let hook = Hashtbl.find_opt hooks "render" in
  match hook with
  | Some (file_name, source_code, hook_config) ->
    if not (Hooks.hook_should_run settings hook_config "render" env.page_file)
    then Ok None
    else
      let () = Logs.info @@ fun m -> m "Running the \"render\" hook on page %s" env.page_file in
      let* page_source = Hooks.run_render_hook
        settings config hook_config file_name source_code env soup
      in Ok (Some page_source)
  | None -> Ok None

let render_html_builtin settings soup =
  let print_html = if settings.pretty_print_html then Soup.pretty_print else Soup.to_string in
  if settings.keep_doctype then
    begin
      let html_str = print_html soup in
      (* If we are given an empty page, then adding doctype makes no sense, we just return an empty string. *)
      if String.length html_str = 0 then "" else
      let has_doctype =
        (<>) 0 (Re.matches (Re.Perl.compile_pat ~opts:[`Caseless] "^(<!DOCTYPE[^>]*>)") html_str |> List.length)
      in
      (* Can the page be an invalid, incomplete HTML? Of course it can,
         but if the user chose to force a doctype, it's their responsibilty.
       *)
      if not has_doctype then
        let doctype = settings.doctype |> String.trim in
        doctype ^ html_str
      else html_str
    end
  else
    begin
      (* If we are to discard the original doctype and completely replace it,
         we need to remove the original one.

         XXX: As of lambdasoup 0.7.2, there's no way to delete the doctype "element"
         (which isn't actually an element anyway),
         so we extract the <html> from the document tree,
         and prepend a doctype to it.
         That is, if the document even has <html> to begin with--see below. *)
      let doctype = settings.doctype |> String.trim in
      let html = Soup.select_one "html" soup in
      match html with
      | Some html ->
        let html_str = print_html html in
        doctype ^ html_str
      | None ->
        (* This may happen if a page (in postprocessor mode)
           or a page template (in generator mode)
           is incomplete.
           At the moment soupault doesn't prohibit invalid HTML,
           so we need to handle this case.
         *)
        let () = Logs.warn @@ fun m -> m "Page has no <HTML> element, not setting doctype" in
        print_html soup
    end

let render_html settings config hooks env soup =
  let res = run_render_hook settings config hooks env soup in
  match res with
  | Ok (Some page_source) -> Ok page_source
  | Ok None -> Ok (render_html_builtin settings soup)
  | Error _ as e -> e

let include_content action selector html content =
  let element = Soup.select_one selector html in
  match element with
  | Some element -> Ok (Html_utils.insert_element (Some action) element content)
  | None ->
    Error (Printf.sprintf "No element in the template matches selector \"%s\", nowhere to insert the content"
           selector)

let make_page settings page_file content =
  (* If generator mode is off, treat everything like a complete page *)
  if not settings.generator_mode then Ok content else
  let page_wrapper_elem = Soup.select_one settings.complete_page_selector content in
  (* If page file appears to be a complete page rather than a page body,
     just return it *)
  match page_wrapper_elem with
  | Some _ ->
    let () =
      if settings.generator_mode then
      Logs.debug @@ fun m -> m "File appears to be a complete page, not using the page template"
      (* in HTML processor mode that's implied *)
    in Ok content
  | None ->
    let tmpl = List.find_opt
      (fun t -> (Path_options.page_included settings t.template_path_options settings.site_dir page_file) = true)
      settings.page_templates
    in
    let html, content_selector, content_action = (match tmpl with
      | None ->
        let () = Logs.info @@ fun m -> m "Using the default template for page %s" page_file in
        (Soup.parse settings.default_template_source,
         Some settings.default_content_selector,
         Some settings.default_content_action)
      | Some t ->
        let () = Logs.info @@ fun m -> m "Using template \"%s\" for page %s" t.template_name page_file in
        (Soup.parse t.template_data,
         t.template_content_selector,
         t.template_content_action))
    in
    let content_selector = Option.value ~default:settings.default_content_selector content_selector in
    let content_action = Option.value ~default:settings.default_content_action content_action in
    let* () = include_content content_action content_selector html content in
    Ok html

(* Widget processing *)
let rec process_widgets env settings ws wh config soup =
  match ws with
  | [] -> Ok ()
  | w :: ws' ->
    begin
      let open Widgets in
      let widget = Hashtbl.find wh w in
      if not (widget_should_run settings w widget settings.build_profiles settings.site_dir env.page_file)
      then (process_widgets env settings ws' wh config soup) else
      let () = Logs.info @@ fun m -> m "Processing widget %s on page %s" w env.page_file in
      let res =
        try widget.func env widget.config soup
        with 
        | Soupault_error s -> Error s
        | Config.Config_error s -> Error s
      in
      (* In non-strict mode, widget processing errors are tolerated *)
      match res, settings.strict with
      | Ok _, _ -> process_widgets env settings ws' wh config soup
      | Error _ as err, true -> err
      | Error msg, false ->
        let () = Logs.warn @@ fun m -> m "Processing widget \"%s\" failed: %s" w msg in
        process_widgets env settings ws' wh config soup
    end

(** Removes index page's parent dir from its navigation path

    When clean URLs are used, the "navigation path" as in the path
    before the page doesn'a match the "real" path for index pages,
    and if you try to use it for breadcrumbs for example,
    section index pages will have links to themselves,
    since the parent of foo/bar/index.html is technically "bar".
    The only way to deal with it I could find is to remove the
    last parent if the page is an index page.
 *)
let fix_nav_path settings path page_name =
  if page_name = settings.index_page then Utils.drop_tail path
  else path

let make_page_url settings nav_path orig_path target_dir page_file =
  let orig_page_file_name = FP.basename page_file in
  let target_page =
    if settings.clean_urls then target_dir |> FP.basename
    else orig_page_file_name
  in
  let path =
    if ((FP.chop_extension orig_page_file_name) = settings.index_page) then orig_path
    else (List.append nav_path [target_page])
  in
  (* URL path should be absolute *)
  String.concat "/" path |> Printf.sprintf "/%s"

(** Decide on the page file name.

    If clean URLs are used, it's always <target_dir>/<settings.index_file>

    If clean URLs are not used, then the base file name is preserved.
    The extension, however, is set to settings.default_extension,
    unless it's in the settings.keep_extensions list.

    The reason for this extension juggling is that people may use page preprocessors
    but not use clean URLs, without extension mangling they will end up
    with pages like build/about.md that have HTML inside despit their name.
    In short, that's what Jekyll et al. always did to non-blog pages.
 *)
let make_page_file_name settings page_file target_dir =
  if settings.clean_urls then (target_dir +/ settings.index_file) else
  let page_file = FP.basename page_file in
  let extension = Utils.get_extension page_file in
  let page_file =
    if Utils.in_list settings.keep_extensions extension then page_file
    else FP.add_extension (FP.chop_extension page_file) settings.default_extension
  in target_dir +/ page_file

let save_html settings soupault_config hooks env page_source =
  let save_hook = Hashtbl.find_opt hooks "save" in
  match save_hook with
  | Some (file_name, source_code, hook_config) ->
    if Hooks.hook_should_run settings hook_config "save" env.page_file then
      let () = Logs.info @@ fun m -> m "Running the \"save\" hook on page %s" env.page_file in
      Hooks.run_save_hook settings soupault_config hook_config file_name source_code env page_source
    else Utils.write_file env.target_file page_source
  | None ->
    let () = Logs.info @@ fun m -> m "Writing generated page to %s" env.target_file in
    Utils.write_file env.target_file page_source

let extract_metadata settings soupault_config hooks env html =
  (* Metadata is only extracted from non-index pages *)
  if not (Autoindex.index_extraction_should_run settings env.page_file) then (Ok None) else
  let entry = Autoindex.get_entry settings env html in
  let post_index_hook = Hashtbl.find_opt hooks "post-index" in
  match post_index_hook with
  | Some (file_name, source_code, hook_config) ->
    if not (Hooks.hook_should_run settings hook_config "post-index" env.page_file) then (Ok (Some entry)) else
    (* Let the post-index hook update the fields *)
    let* index_fields =
      let () = Logs.info @@ fun m -> m "Running the \"post-index\" hook on page %s" env.page_file in
      Hooks.run_post_index_hook settings soupault_config hook_config file_name source_code env html entry.fields
    in
    Ok (Some {entry with fields=index_fields})
  | None -> Ok (Some entry)

let run_pre_process_hook settings config hooks page_file target_dir target_file content =
  let pre_process_hook = Hashtbl.find_opt hooks "pre-process" in
  match pre_process_hook with
  | Some (file_name, source_code, hook_config) ->
    if not (Hooks.hook_should_run settings hook_config "pre-process" page_file)
    then Ok (target_dir, target_file, content)
    else
      let () = Logs.info @@ fun m -> m "Running the \"pre-process\" hook on page %s" page_file in
      Hooks.run_pre_process_hook
        settings config hook_config file_name source_code page_file target_dir target_file content
  | None -> Ok (target_dir, target_file, content)

(* Check if index insertion should be done and log the reason if not *)
let index_insertion_should_run settings index page_name =
  let aux settings page_name =
    if not settings.index then Some "indexing is disabled in the configuration" else
    if settings.index_only then Some "running in the index-only mode" else
    if (page_name <> settings.index_page) then Some (Printf.sprintf "page name does not match %s" settings.index_page) else
    if index = [] then Some "index is empty" else None
  in
  match (aux settings page_name) with
  | None -> true
  | Some msg ->
    let () = Logs.debug @@ fun m -> m "Not inserting index data: %s" msg in
    false

(** Processes a page:

    1. Adjusts the path to account for index vs non-index page difference
       in setups using clean URLs
    2. Reads a page file and inserts the content into the template,
       unless it's a complete page
    3. Updates the global index if necessary
    4. Runs the page through widgets
    5. Inserts the index section into the page if it's an index page
    6. Saves the processed page to file
  *)
let process_page page_data index index_hash widgets hooks config settings =
  let (page_file, page_content, nav_path) = (page_data.page_file_path, page_data.page_content, page_data.page_nav_path) in
  let () = Logs.info @@ fun m -> m "Processing page %s" page_file in
  let* content =
    match page_content with
    | None ->
      (* This is a real page that actually exists on disk. *)
      load_html settings config hooks page_file
    | Some content ->
      (* This is a "fake" paginated index or taxonomy page created by an index processor. *)
      Ok (Soup.parse content)
  in
  let page_name = FP.basename page_file |> FP.chop_extension in
  let orig_path = nav_path in
  let nav_path = fix_nav_path settings nav_path page_name in
  let target_dir = make_page_dir_name settings (Utils.concat_path orig_path) page_name |> FP.concat settings.build_dir in
  let target_file = make_page_file_name settings page_file target_dir in
  let* (target_dir, target_file, content) =
    run_pre_process_hook settings config hooks page_file target_dir target_file content
  in
  let page_url = make_page_url settings nav_path orig_path target_dir page_file in
  let env = {
    nav_path = nav_path;
    page_url = page_url;
    page_file = page_file;
    target_dir = target_dir;
    target_file = target_file;
    site_index = index;
    site_index_hash = index_hash;
    settings = settings;
  }
  in
  let* html = make_page settings page_file content in
  (* Section index injection always happens before any widgets have run *)
  let* new_pages =
    (* Section index is inserted only in index pages *)
    if not (index_insertion_should_run settings index page_name) then Ok []
    else let () = Logs.info @@ fun m -> m "Inserting section index into page %s" page_file in
    Autoindex.insert_indices env config html
  in
  let before_index, after_index, widget_hash = widgets in
  let* () = process_widgets env settings before_index widget_hash config html in
  (* Index extraction *)
  let* index_entry = extract_metadata settings config hooks env html in
  if settings.index_only then Ok (index_entry, new_pages) else
  let* () = process_widgets env settings after_index widget_hash config html in
  let* () = mkdir target_dir in
  let* html_str = render_html settings config hooks env html in
  let* () = save_html settings config hooks env html_str in
  Ok (index_entry, new_pages)

(* Monadic wrapper for process_page that can either return or ignore errors  *)
let process_page index index_hash widgets hooks config settings page_data =
  let res =
    try process_page page_data index index_hash widgets hooks config settings
    with Soupault_error msg -> Error msg
  in
  match res with
    Ok _ as res -> res
  | Error msg ->
    let msg = Printf.sprintf "Could not process page %s: %s" page_data.page_file_path msg in
    if settings.strict then Error msg else 
    let () = Logs.warn @@ fun m -> m "%s" msg in
    Ok (None, [])

(* Option parsing and initialization *)

type soupault_action = DoActualWork | InitProject | ShowVersion | ShowDefaultConfig | ShowEffectiveConfig

let get_args settings =
  (* Due to a workaround, we are going to parse argument twice:
     first to find out if we actually need to do anything but printing a version or help,
     second time to override config file options with command line ones if needed.

     The Arg module has a global state: Arg.current that hold the index of the last processed argument.
     We need to reset it to zero to make the function usable more than once.
   *)
  let () = Arg.current := 0 in
  let actions = ref [] in
  let sr = ref settings in
  let args = Arg.align [
    ("--init", Arg.Unit (fun () -> actions := (InitProject :: !actions)), " Set up basic directory structure");
    ("--verbose", Arg.Unit (fun () -> sr := {!sr with verbose=true}), " Verbose output");
    ("--debug", Arg.Unit (fun () -> sr := {!sr with debug=true}), " Debug output");
    ("--strict", Arg.Bool (fun s -> sr := {!sr with strict=s}), "<true|false>  Stop on page processing errors or not");
    ("--site-dir", Arg.String (fun s -> sr := {!sr with site_dir=s}), "<DIR>  Directory with input files");
    ("--build-dir", Arg.String (fun s -> sr := {!sr with build_dir=s}), "<DIR>  Output directory");
    ("--profile", Arg.String (fun s -> sr := {!sr with build_profiles=(s :: !sr.build_profiles)}), "<NAME>  Build profile (you can give this option more than once)");
    ("--index-only", Arg.Unit (fun () -> sr := {!sr with index_only=true}), " Extract site index without generating pages");
    ("--force", Arg.Unit (fun () -> sr := {!sr with force=true}), " Force generating all target files");
    ("--show-default-config", Arg.Unit (fun () -> actions := (ShowDefaultConfig :: !actions)), " Print the default config and exit");
    ("--show-effective-config", Arg.Unit (fun () -> actions := (ShowEffectiveConfig :: !actions)), " Print the effective config (user-defined and default options) and exit");
    ("--version", Arg.Unit (fun () -> actions := (ShowVersion :: !actions)), " Print version and exit")
  ]
  in
  let usage = Printf.sprintf "Usage: %s [OPTIONS]" Sys.argv.(0) in
  let () = Arg.parse args (fun _ -> ()) usage in
  match !actions with
  | [] -> Ok (DoActualWork, !sr)
  | [a] -> Ok (a, !sr)
  | _ ->
    (* This function is first called at a point when the logger isn't setup yet,
       so we need to the the plain old print to tell the user about errors. *)
    let () =
      print_endline "Error: Incorrect comand line option combination.";
      print_endline "Please specify only one of --version, --help, --show-default-config, or --show-effective-config";
      print_endline "To build your website, simply run soupault without any options."
    in
    exit 1

let check_project_dir settings =
  let () =
    if (not (FU.test FU.Exists settings.default_template)) && settings.generator_mode then
    (* Don't make this fatal just yet, because:
         a) either it will blow up very soon after anyway, when soupault gets to the first page
         b) or ther user specified a custom template for every path.
     *)
    Logs.warn @@ fun m -> m "Default template is required in generator mode, but template file \"%s\" does not exist."
      settings.default_template
  in let () =
    if (not (FU.test FU.Is_dir settings.site_dir))
    then begin
      (* Absense of a site dir likely means someone is running soupault in a completely wrong dir. *)
      Logs.err @@ fun m -> m "Site directory \"%s\" does not exist!" settings.site_dir;
      Logs.err @@ fun m -> m "You can use %s --init to initialize a basic project." Sys.argv.(0);
      exit 1
    end
  in ()

let find_config_file () =
  let conf_exists = Sys.file_exists Defaults.config_file in
  let alt_conf_exists = Sys.file_exists Defaults.config_file_alt in
  match conf_exists, alt_conf_exists with
  | true, false -> Ok Defaults.config_file
  | false, true -> Ok Defaults.config_file_alt
  | true, true ->
    let () = Logs.warn @@ fun m -> m "Both %s and %s files exist, using %s"
      Defaults.config_file Defaults.config_file_alt Defaults.config_file
    in Ok Defaults.config_file
  | false, false ->
      let () =
        Logs.err @@ fun m -> m "Could not find either %s or %s in the current directory."
          Defaults.config_file Defaults.config_file_alt;
        Logs.err @@ fun m -> m "Make sure you are in a soupault project directory or specify configuration file location in \
          %s environment variable." Defaults.config_path_env_var
      in
      Error "Cannot proceed without a configuration file."

let initialize () =
  let () = Random.self_init () in
  let settings = Defaults.default_settings in
  let () = setup_logging settings.verbose settings.debug in
  let* config_file =
    try Ok (Unix.getenv Defaults.config_path_env_var)
    with Not_found -> find_config_file ()
  in
  let* config = Config.read_config config_file in
  (* First, populate the settings from the config file data. *)
  let* settings = Config.update_settings settings config in
  (* Then override options from it with values from command line arguments, if there are any. *)
  let* (_, settings) = get_args settings in
  (* Update the log level from the config and arguments  *)
  let () = setup_logging settings.verbose settings.debug in
  let () = check_project_dir settings in
  let* config = Ok (config |> Option.get) in
  (* Inject defaults and updated values back into the TOML config
     to make the complete effective settings available to plugins. *)
  let config = Config.inject_defaults settings config in
  let* plugins = Plugins.get_plugins settings (Some config) in
  let* widgets = Widgets.get_widgets settings (Some config) plugins settings.index_extract_after_widgets in
  let* hooks = Hooks.get_hooks config in
  let* default_template_str =
    if settings.generator_mode then Utils.get_file_content settings.default_template
    else Ok ""
  in
  let settings = {settings with default_template_source=default_template_str} in
  let () =
    begin
      if not settings.generator_mode then
        Logs.info @@ fun m -> m "Running in HTML processor mode, not using page templates";
      if settings.index_only && not (settings.index && (settings.dump_json <> None)) then
        Logs.warn @@ fun m -> m "--index-only is useless without index=true and dump_json options in the config!";
      if settings.build_dir = "" then
      (* Treating build_dir="" as "build in the current dir" wasn't a part of the design.
         I suppose it should be disabled in 2.0.
       *)
      Logs.warn @@ fun m -> m "Build directory is set to empty string, using current working directory for output"
    end
  in
  if settings.site_dir = "" then (Error "site_dir must be a directory path, not an empty string")
  else (Ok (config, widgets, hooks, settings))

let dump_index_json settings index =
  match settings.dump_json with
  | None -> Ok ()
  | Some f ->
    try Ok (Soup.write_file f @@ Autoindex.json_string_of_entries index)
    with Sys_error e -> Error e

let check_version settings =
  match settings.soupault_version with
  | None -> ()
  | Some v ->
    try
      let res = Utils.require_version v in
      if res then () else begin
        Printf.printf "According to settings.soupault_version, this configuration file is for soupault %s\n" v;
        Printf.printf "You are running soupault version %s, older than required\n" Defaults.version_string;
        Printf.printf "To proceed, upgrade soupault to at least %s, or (at your own risk) \
          remove the soupault_version option from your configuration\n" v;
        exit 1
      end
    with Failure msg -> begin
      Printf.printf "Could not check configuration compatibility with running soupault version: %s\n" msg;
      print_endline "Maybe your settings.soupault_version option is malformed?\n";
      exit 1
    end

let process_page_files index_hash widgets hooks config settings files =
  Utils.fold_left
    (fun acc p ->
      let ie = process_page [] index_hash widgets hooks config settings p in
       match ie with Ok (None, _) -> Ok acc | Ok (Some ie', _) -> Ok (ie' :: acc) | Error _ as err -> err)
    []
    files

let process_index_files index index_hash widgets hooks config settings files =
  Utils.fold_left
    (fun acc p ->
      let ie = process_page index index_hash widgets hooks config settings p in
       match ie with
       | Ok (_, []) -> Ok acc
       | Ok (_, new_pages) -> Ok (List.append new_pages acc)
       | Error _ as err -> err)
    []
    files

let main () =
  (* Parse the arguments to see if we have any real work to do, or it's --version or similar.
     If it's an action that doesn't rely on the config, we don't even need to read the config file.
     Worse yet, config reading errors will prevent us from executing the action.
   *)
  let* (action, settings) = get_args Defaults.default_settings in
  match action with
  | ShowVersion ->
    let () = Utils.print_version () in
    exit 0
  | ShowDefaultConfig ->
    let () = print_endline Project_init.default_config in
    exit 0
  | InitProject ->
    let () =
      if (settings.site_dir <> Defaults.default_settings.site_dir) ||
         (settings.build_dir <> Defaults.default_settings.build_dir)
      (* Logging is not set at up this point, it's done by `initialize ()`,
         so we use a "normal" print to emit a warning here. *)
      then print_string "Warning: --site-dir and --build-dir options are ignored by --project-init\n\n"
    in
    let () = Project_init.init Defaults.default_settings in
    exit 0
  | DoActualWork | ShowEffectiveConfig ->
    let* config, widgets, hooks, settings = initialize () in
    let () = check_version settings in
    if action = ShowEffectiveConfig then (Otoml.Printer.to_channel stdout config; exit 0) else
    let () = setup_logging settings.verbose settings.debug in
    let* () = make_build_dir settings.build_dir in
    let (page_files, index_files, asset_files) = Site_dir.get_site_files settings in
    (* If settings.process_pages_first is set, extract those pages and move them to the head of the list.
       For an empty list it would return the original list, but it would require traversing that list twice,
       so it's better to avoid it unless it's actually required. *)
    let* page_files =
      if settings.process_pages_first <> []
      then Site_dir.reorder_pages settings page_files
      else Ok page_files
    in
    let* () =
      if not settings.index_only
      then Utils.iter (fun (src, dst) -> Utils.cp [src] dst) asset_files
      else Ok ()
    in
    (* A bit of code duplication ahead, for now at least...

       The procedure for a run with [index.index_first=true] and without is slightly different.
       The purpose of [index_first=true] is to make the entire site metadata available to _all_ pages.
       Obviously, it can only be done by doing certain amount of work twice:
       at the very least, reading all pages, running widgets that aren't in [index.extract_after_widgets],
       and extracting fields.
     *)
    if settings.index_first then
      (* Creates a random-access version of the site index from a list of entries. *)
      let import_index_hash hash entries =
        List.iter (fun e -> Hashtbl.add hash e.index_entry_page_file e) entries 
      in
      (* The user wants the complete site metadata available to widgets/plugins on every page. *)
      begin
        (* Make a random-access hash table version of the index to provide an index entry to widgets and
           hooks for the page being processed. *)
        let index_hash = Hashtbl.create 1024 in
        (* Do just enough work to have all site metadata produced and extracted.
           [index_only=true] prevents [process_page] from rendering pages and writing them to disk,
           and also often (though not always) reduces the number of widgets that will run on each page.
         *)
        let* index = process_page_files index_hash widgets hooks config {settings with index_only=true} page_files in
        (* Sort entries according to the global settings so that widgets that use index data
           don't have to sort it themselves. *)
        let* index = Autoindex.sort_entries settings settings.index_sort_options index in
        let () = import_index_hash index_hash index in
       (* Since metadata extraction is already done and the complete site metadata should be available to all pages,
           content pages and section index pages should be treated the same.
           So we merge the lists of content and index pages back into one list
           and process it to generate the website.
         *)
        let all_files = List.append page_files index_files in
        (* Disable metadata extraction to avoid doing useless work, then process all pages.
           In practice, only index pages may produce new pages, but for simplicity we merge the lists
           because there's no harm in trying to collect generated pages from non-index pages,
           they will simply return empty lists.
         *)
        let settings = {settings with no_index_extraction=true} in
        let* new_pages = process_index_files index index_hash widgets hooks config settings all_files in
        (* Now process "fake" pages generated by index processors.
           Index processing must be disabled on them to prevent index processors from generating
           new "fake" pages from generated pages and creating infinite loops.
         *)
        let settings = {settings with index=false} in
        let* () = Utils.iter (process_page index index_hash widgets hooks config settings) new_pages in
        (* Finally, dump the index file, if requested. *)
        let* () = dump_index_json settings index in
        Ok ()
      end
    else
      (* The user only wants site metadata available to section index pages
         and doesn't want the performance penalty of processing anything twice.
       *)
      begin
        (* Since in the [index_first=false] mode non-index pages have no access to the site-wide index data,
           we simply give the [process_page] function an empty hash.
         *)
        let index_hash = Hashtbl.create 1 in
        (* Process normal pages and collect index data from them.
           The [process_page_files] function is not using the [index_hash] argument,
           it's only needed to keep its underlying [process_page] call well-typed,
           so we can safely give it an empty hash.
         *)
        let* index = process_page_files index_hash widgets hooks config settings page_files in
        (* Sort entries according to the global settings so that widgets that use index data
           don't have to sort it themselves. *)
        let* index = Autoindex.sort_entries settings settings.index_sort_options index in
        (* Now process the index pages, using previously collected index data.
           That will not produce new index data because extraction will not run,
           but index processors may generate new pages (e.g. pagination and taxonomies).
         *)
        let settings = {settings with no_index_extraction=true} in
        let* new_pages = process_index_files index index_hash widgets hooks config settings index_files in
        (* Now process "fake" pages generated by index processors.
           Index processing must be disabled on them to prevent index processors from generating
           new "fake" pages from generated pages and creating infinite loops.
         *)
        let settings = {settings with index=false} in
        let* () = Utils.iter (process_page index index_hash widgets hooks config settings) new_pages in
        (* Finally, dump the index file, if requested. *)
        let* () = dump_index_json settings index in
        Ok ()
      end

let () =
  let res = main () in
  match res with
  | Ok _ -> exit 0
  | Error e ->
    Logs.err @@ fun m -> m "%s" e;
    exit 1

