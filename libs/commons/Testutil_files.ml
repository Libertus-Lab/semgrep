(*
   Utilities for creating, scanning, and deleting a hierarchy
   of test files.
*)
open Fpath_.Operators
open Printf

type t =
  | Dir of string * t list
  | File of string * string
  | Symlink of string * string

(* if you prefer a curried syntax *)
let file name : t = File (name, "")
let dir name entries : t = Dir (name, entries)
let symlink name dest : t = Symlink (name, dest)

let get_name = function
  | Dir (name, _)
  | File (name, _)
  | Symlink (name, _) ->
      name

let rec sort xs =
  List_.map sort_one xs
  |> List.sort (fun a b -> String.compare (get_name a) (get_name b))

and sort_one x =
  match x with
  | Dir (name, xs) -> Dir (name, sort xs)
  | File _
  | Symlink _ ->
      x

(* List the paths of regular files.
   Sorry, the implementation below with fold_left is a little tricky. *)
let flatten ?(root = Fpath.v ".") ?(include_dirs = false) files =
  let rec flatten acc files = List.fold_left flatten_one acc files
  and flatten_one (acc, dir) file =
    match file with
    | Dir (name, entries) ->
        let path = dir / name in
        let acc = if include_dirs then path :: acc else acc in
        let acc, _last_dir = flatten (acc, path) entries in
        (acc, dir)
    | File (name, _contents) ->
        let file = dir / name in
        (file :: acc, dir)
    | Symlink (name, _dest) ->
        let file = dir / name in
        (file :: acc, dir)
  in
  let acc, _dir = flatten ([], root) files in
  List.rev acc
  |> (* remove the leading "./" *)
  List_.map Fpath.normalize

let rec write root files = List.iter (write_one root) files

and write_one root file =
  match file with
  | Dir (name, entries) ->
      let dir = root / name in
      if not (USys.file_exists !!dir) then UUnix.mkdir !!dir 0o777;
      write dir entries
  | File (name, contents) ->
      let path = root / name |> Fpath.to_string in
      UFile.Legacy.write_file ~file:path contents
  | Symlink (name, dest) ->
      let path = root / name |> Fpath.to_string in
      let dest_path = Fpath.v dest |> Fpath.to_string in
      UUnix.symlink dest_path path

let get_dir_entries path =
  let dir = UUnix.opendir (Fpath.to_string path) in
  Common.protect
    ~finally:(fun () -> Unix.closedir dir)
    (fun () ->
      let acc = ref [] in
      try
        while true do
          acc := Unix.readdir dir :: !acc
        done;
        assert false
      with
      | End_of_file ->
          List.rev !acc
          |> List.filter (function
               | ".."
               | "." ->
                   false
               | _ -> true))

let read root =
  let rec read path =
    let name = Fpath.basename path in
    match (UUnix.lstat (Fpath.to_string path)).st_kind with
    | S_DIR ->
        let names = get_dir_entries path in
        Dir (name, List_.map (fun name -> read (path / name)) names)
    | S_REG -> File (name, UFile.Legacy.read_file (Fpath.to_string path))
    | S_LNK -> Symlink (name, UUnix.readlink (Fpath.to_string path))
    | _other ->
        failwith
          ("Testutil_files.read: unsupported file type: " ^ Fpath.to_string path)
  in
  match (UUnix.stat (Fpath.to_string root)).st_kind with
  | S_DIR ->
      let names = get_dir_entries root in
      List_.map (fun name -> read (root / name)) names
  | _other ->
      failwith
        ("Testutil_files.read: root must be a directory: "
       ^ Fpath.to_string root)

let is_dir path =
  match (UUnix.lstat (Fpath.to_string path)).st_kind with
  | S_DIR -> true
  | _ -> false

let is_file path =
  match (UUnix.lstat (Fpath.to_string path)).st_kind with
  | S_REG -> true
  | _ -> false

let is_symlink path =
  match (UUnix.lstat (Fpath.to_string path)).st_kind with
  | S_LNK -> true
  | _ -> false

let mkdir ?(root = USys.getcwd () |> Fpath.v) path =
  if Fpath.is_rel root then
    invalid_arg
      (sprintf "Testutil_files.mkdir: root must be an absolute path: %s"
         (Fpath.to_string root));
  let rec mkdir path =
    let abs_path = root // path in
    let str = Fpath.to_string abs_path in
    if not (USys.file_exists str) then (
      let parent = Fpath.parent path in
      mkdir parent;
      UUnix.mkdir str 0o777)
  in
  let root_s = Fpath.to_string root in
  if not (USys.file_exists root_s) then
    failwith ("Testutil_files.mkdir: root folder doesn't exist: " ^ root_s);
  mkdir path

let with_chdir dir f =
  let dir_s = Fpath.to_string dir in
  let orig = UUnix.getcwd () in
  Common.protect
    ~finally:(fun () -> UUnix.chdir orig)
    (fun () ->
      UUnix.chdir dir_s;
      f ())

let init_rng = lazy (URandom.self_init ())

let create_tempdir () =
  let rec loop n =
    if n > 10 then
      failwith "Can't create a temporary test folder with a random name";
    let name = sprintf "test-%x" (URandom.bits ()) in
    let path = Filename.concat (UFilename.get_temp_dir_name ()) name in
    if USys.file_exists path then loop (n + 1)
    else (
      UUnix.mkdir path 0o777;
      Fpath.v path)
  in
  Lazy.force init_rng;
  loop 1

let remove path =
  let rec remove path =
    let path_s = Fpath.to_string path in
    match (UUnix.lstat path_s).st_kind with
    | S_DIR ->
        let names = get_dir_entries path in
        List.iter (fun name -> remove (path / name)) names;
        UUnix.rmdir path_s
    | _other -> USys.remove path_s
  in
  if USys.file_exists (Fpath.to_string path) then remove path

let with_tempdir ?(persist = false) ?(chdir = false) func =
  let dir = create_tempdir () in
  Common.protect
    ~finally:(fun () -> if not persist then remove dir)
    (fun () -> if chdir then with_chdir dir (fun () -> func dir) else func dir)

let with_tempfiles ?persist ?chdir files func =
  with_tempdir ?persist ?chdir (fun root ->
      (* files are automatically deleted as part of the cleanup done by
         'with_tempdir'. *)
      write root files;
      func root)

let print_files files =
  flatten files |> List.iter (fun path -> UPrintf.printf "%s\n" !!path)

let with_tempfiles_verbose (files : t list) func =
  with_tempdir ~chdir:true (fun root ->
      let files = sort files in
      UPrintf.printf "Input files:\n";
      print_files files;
      write root files;
      (* Nice listing of the real file tree.
            old: Don't care if the 'tree' command is unavailable.
            new: Having the same output on all platform matters because we
            now compare the output of tests against expectations. The version
            of 'tree' in CI seems to be ignoring '-a'.
            TODO: remove permanently or implement our own version of 'tree'.
         USys.command (Printf.sprintf "tree -a '%s'" !!root) |> ignore;
      *)
      func root)

let () =
  Testo.test "Testutil_files" (fun () ->
      with_tempdir ~chdir:true (fun root ->
          assert (read root = []);
          assert (read (Fpath.v ".") = []);
          let tree =
            [
              File ("a", "hello");
              File ("b", "yo");
              Symlink ("c", "a");
              Dir ("d", [ File ("e", "42"); Dir ("empty", []) ]);
            ]
          in
          write root tree;
          let tree2 = read root in
          assert (sort tree2 = sort tree);

          let paths = flatten tree |> Fpath_.to_strings in
          List.iter UStdlib.print_endline paths;
          assert (paths = [ "a"; "b"; "c"; "d/e" ])))
