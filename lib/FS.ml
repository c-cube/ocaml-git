(*
 * Copyright (c) 2013-2014 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Misc.OP
open Printf

module LogMake = Log.Make

module Log = LogMake(struct let section = "fs" end)

module type IO = sig
  val getcwd: unit -> string Lwt.t
  val realpath: string -> string Lwt.t
  val mkdir: string -> unit Lwt.t
  val remove: string -> unit Lwt.t
  val file_exists: string -> bool Lwt.t
  val directories: string -> string list Lwt.t
  val files: string -> string list Lwt.t
  val rec_files: string -> string list Lwt.t
  val read_file: string -> Cstruct.t Lwt.t
  val write_file: string -> Cstruct.t -> unit Lwt.t
  val chmod: string -> int -> unit Lwt.t
  val stat_info: string -> Cache.stat_info
end

module type S = sig
  include Store.S
  val create_file: string -> Tree.perm -> Blob.t -> unit Lwt.t
  val entry_of_file: ?root:string ->
    string -> Tree.perm -> Blob.t -> Cache.entry option Lwt.t
end

module Make (IO: IO) = struct

type t = string

let root t = t

let create ?root () =
  match root with
  | None   -> IO.getcwd ()
  | Some r ->
    IO.mkdir r >>= fun () ->
    IO.realpath r

let clear t =
  Log.infof "clear %s" t;
  IO.remove (sprintf "%s/.git" t)

(* Loose objects *)
module Loose = struct

  module Log = LogMake(struct let section = "fs-loose" end)

  let file root sha1 =
    let hex = SHA.to_hex sha1 in
    let prefix = String.sub hex 0 2 in
    let suffix = String.sub hex 2 (String.length hex - 2) in
    root / ".git" / "objects" / prefix / suffix

  let mem root sha1 =
    IO.file_exists (file root sha1)

  let read t sha1 =
    Log.debugf "read %s" (SHA.to_hex sha1);
    let file = file t sha1 in
    IO.file_exists file >>= function
    | false -> return_none
    | true  ->
      IO.read_file file >>= fun buf ->
      try
        let value = Value.input (Mstruct.of_cstruct buf) in
        return (Some value)
      with Zlib.Error _ ->
        fail (Zlib.Error (file, (Cstruct.to_string buf)))

  let write t value =
    Log.debugf "write";
    let inflated = Misc.with_buffer (fun buf -> Value.add_inflated buf value) in
    let sha1 = SHA.of_string inflated in
    let file = file t sha1 in
    IO.file_exists file >>= function
    | true  -> return sha1
    | false ->
      let deflated = Misc.deflate_cstruct (Cstruct.of_string inflated) in
      IO.write_file file deflated >>= fun () ->
      return sha1

  let list root =
    Log.debugf "Loose.list %s" root;
    let objects = root / ".git" / "objects" in
    IO.directories objects >>= fun objects ->
    let objects = List.map Filename.basename objects in
    let objects = List.filter (fun s -> (s <> "info") && (s <> "pack")) objects in
    Lwt_list.map_s (fun prefix ->
        let dir = root / ".git" / "objects" / prefix in
        IO.files dir >>= fun suffixes ->
        let suffixes = List.map Filename.basename suffixes in
        let objects = List.map (fun suffix ->
            SHA.of_hex (prefix ^ suffix)
          ) suffixes in
        return objects
      ) objects
    >>= fun files ->
    return (List.concat files)

end

module Packed = struct

  module Log = LogMake(struct let section = "fs-packed" end)

  let file root sha1 =
    let pack_dir = root / ".git" / "objects" / "pack" in
    let pack_file = "pack-" ^ (SHA.to_hex sha1) ^ ".pack" in
    pack_dir / pack_file

  let list root =
    Log.debugf "list %s" root;
    let packs = root / ".git" / "objects" / "pack" in
    IO.files packs >>= fun packs ->
    let packs = List.map Filename.basename packs in
    let packs = List.filter (fun f -> Filename.check_suffix f ".idx") packs in
    let packs = List.map (fun f ->
        let p = Filename.chop_suffix f ".idx" in
        let p = String.sub p 5 (String.length p - 5) in
        SHA.of_hex p
      ) packs in
    return packs

  let index root sha1 =
    let pack_dir = root / ".git" / "objects" / "pack" in
    let idx_file = "pack-" ^ (SHA.to_hex sha1) ^ ".idx" in
    pack_dir / idx_file

  let indexes = Hashtbl.create 1024

  let write_index t sha1 idx =
    let file = index t sha1 in
    if not (Hashtbl.mem indexes sha1) then Hashtbl.add indexes sha1 idx;
    IO.file_exists file >>= function
    | true  -> return_unit
    | false ->
      let buf = Buffer.create 1024 in
      Pack_index.add buf idx;
      IO.write_file file (Cstruct.of_string (Buffer.contents buf))

  let read_index t sha1 =
    Log.debugf "read_index %s" (SHA.to_hex sha1);
    try return (Hashtbl.find indexes sha1)
    with Not_found ->
      let file = index t sha1 in
      IO.file_exists file >>= function
      | true ->
        IO.read_file file >>= fun buf ->
        let buf = Mstruct.of_cstruct buf in
        let index = Pack_index.input buf in
        Hashtbl.add indexes sha1 index;
        return index
      | false ->
        Printf.eprintf "%s does not exist." file;
        fail (Failure "read_index")

  let keys = Hashtbl.create 1024

  let read_keys t sha1 =
    Log.debugf "read_keys %s" (SHA.to_hex sha1);
    try return (Hashtbl.find keys sha1)
    with Not_found ->
      begin
        try
          let i = Hashtbl.find indexes sha1 in
          let keys = SHA.Set.of_list (SHA.Map.keys i.Pack_index.offsets) in
          return keys
        with Not_found ->
          let file = index t sha1 in
          IO.file_exists file >>= function
          | true ->
            IO.read_file file >>= fun buf ->
            let keys = Pack_index.keys (Mstruct.of_cstruct buf) in
            return keys
          | false ->
            fail (Failure "Git_fs.Packed.read_keys")
      end >>= fun data ->
      Hashtbl.add keys sha1 data;
      return data

  let packs = Hashtbl.create 8

  let read_pack t sha1 =
    try return (Hashtbl.find packs sha1)
    with Not_found ->
      let file = file t sha1 in
      IO.file_exists file >>= function
      | true ->
        IO.read_file file  >>= fun buf ->
        read_index t sha1 >>= fun index ->
        let pack = Pack.Raw.input (Mstruct.of_cstruct buf) ~index:(Some index) in
        let pack = Pack.to_pic pack in
        Hashtbl.add packs sha1 pack;
        return pack
      | false ->
        Printf.eprintf "No file associated with the pack object %s.\n" (SHA.to_hex sha1);
        fail (Failure "read_file")

  let write_pack t sha1 pack =
    let file = file t sha1 in
    if not (Hashtbl.mem packs sha1) then  (
      let pack = Pack.to_pic pack in
      Hashtbl.add packs sha1 pack;
    );
    IO.file_exists file >>= function
    | true  -> return_unit
    | false ->
      let pack = Misc.with_buffer' (fun buf -> Pack.Raw.add buf pack) in
      IO.write_file file pack

  let mem_in_pack t pack_sha1 sha1 =
    Log.debugf "mem_in_pack %s:%s" (SHA.to_hex pack_sha1) (SHA.to_hex sha1);
    read_keys t pack_sha1 >>= fun keys ->
    return (SHA.Set.mem sha1 keys)

  let read_in_pack t pack_sha1 sha1 =
    Log.debugf "read_in_pack %s:%s"
      (SHA.to_hex pack_sha1) (SHA.to_hex sha1);
    mem_in_pack t pack_sha1 sha1 >>= function
    | false -> return_none
    | true  ->
      read_pack t pack_sha1 >>= fun pack ->
      return (Pack.read pack sha1)

  let values = Hashtbl.create 1024

  let read t sha1 =
    try return (Some (Hashtbl.find values sha1))
    with Not_found ->
      begin match Value.Cache.find sha1 with
        | Some str -> return (Some (Value.input_inflated (Mstruct.of_string str)))
        | None     ->
          list t >>= fun packs ->
          Lwt_list.fold_left_s (fun acc pack ->
              match acc with
              | Some v -> return (Some v)
              | None   -> read_in_pack t pack sha1
            ) None packs
      end >>= function
      | None   -> return_none
      | Some v ->
        ignore (Hashtbl.add values sha1 v);
        return (Some v)

  let mem t sha1 =
    list t >>= fun packs ->
    Lwt_list.fold_left_s (fun acc pack ->
        if acc then return acc
        else mem_in_pack t pack sha1
      ) false packs

end

let list t =
  Log.debugf "list";
  Loose.list t  >>= fun objects ->
  Packed.list t >>= fun packs   ->
  Misc.list_map_p (fun p -> Packed.read_keys t p) packs >>= fun keys ->
  let keys = List.fold_left SHA.Set.union (SHA.Set.of_list objects) keys in
  let keys = SHA.Set.to_list keys in
  return keys

let read t sha1 =
  Log.debugf "read %s" (SHA.to_hex sha1);
  Loose.read t sha1 >>= function
  | Some v -> return (Some v)
  | None   -> Packed.read t sha1

let read =
  let memo = Hashtbl.create 1024 in
  fun t k ->
    try Hashtbl.find memo k
    with Not_found ->
      let v = read t k in
      Hashtbl.add memo k v;
      v

let read_exn t sha1 =
  read t sha1 >>= function
  | Some v -> return v
  | None   ->
    Log.debugf "read_exn: Cannot read %s" (SHA.to_hex sha1);
    fail Not_found

let mem t sha1 =
  Loose.mem t sha1 >>= function
  | true  -> return true
  | false -> Packed.mem t sha1

let contents t =
  Log.debugf "contents";
  list t >>= fun sha1s ->
  Misc.list_map_p (fun sha1 ->
      read_exn t sha1 >>= fun value ->
      return (sha1, value)
    ) sha1s

let dump t =
  contents t >>= fun contents ->
  List.iter (fun (sha1, value) ->
      let typ = Value.type_of value in
      Printf.eprintf "%s %s\n" (SHA.to_hex sha1) (Object_type.to_string typ);
    ) contents;
  return_unit

let references t =
  let refs = t / ".git" / "refs" in
  IO.rec_files refs >>= fun files ->
  let n = String.length (t / ".git" / "") in
  let refs = List.map (fun file ->
      let ref = String.sub file n (String.length file - n) in
      Reference.of_raw ref
    ) files in
  return refs

let file_of_ref t ref =
  t / ".git" / Reference.to_raw ref

let mem_reference t ref =
  let file = file_of_ref t ref in
  IO.file_exists file

let remove_reference t ref =
  let file = file_of_ref t ref in
  catch
    (fun () -> IO.remove file)
    (fun _ -> return_unit)

let read_reference t ref =
  let file = file_of_ref t ref in
  Log.infof "Reading %s" file;
  IO.file_exists file >>= function
  | true ->
    IO.read_file file >>= fun hex ->
    let hex = String.trim (Cstruct.to_string hex) in
    return (Some (SHA.Commit.of_hex hex))
  | false ->
    return_none

let read_head t =
  let file = file_of_ref t Reference.head in
  Log.infof "Reading %s" file;
  IO.file_exists file >>= function
  | true ->
    IO.read_file file >>= fun str ->
    let str = Cstruct.to_string str in
    let contents = match Misc.string_split ~on:' ' str with
      | [sha1]  -> Reference.SHA (SHA.Commit.of_hex sha1)
      | [_;ref] -> Reference.Ref (Reference.of_raw ref)
      | _       -> failwith (sprintf "read_head: %s is not a valid HEAD contents" str)
    in
    return (Some contents)
  | false ->
    return None

let read_reference_exn t ref =
  read_reference t ref >>= function
  | Some s -> return s
  | None   ->
    Log.debugf "read_reference_exn: Cannot read %s" (Reference.pretty ref);
    fail Not_found

let write t value =
  Loose.write t value >>= fun sha1 ->
  Log.debugf "write -> %s" (SHA.to_hex sha1);
  return sha1

let write_pack t pack =
  Log.debugf "write_pack";
  let sha1 = Pack.Raw.sha1 pack in
  let index = Pack.Raw.index pack in
  Packed.write_pack t sha1 pack   >>= fun () ->
  Packed.write_index t sha1 index >>= fun () ->
  return (Pack.Raw.keys pack)

let write_reference t ref sha1 =
  let file = t / ".git" / Reference.to_raw ref in
  let contents = SHA.Commit.to_hex sha1 in
  IO.write_file file (Cstruct.of_string contents)

let write_head t = function
  | Reference.SHA sha1 -> write_reference t Reference.head sha1
  | Reference.Ref ref   ->
    let file = t / ".git" / "HEAD" in
    let contents = sprintf "ref: %s" (Reference.to_raw ref) in
    IO.write_file file (Cstruct.of_string contents)

type 'a tree =
  | Leaf of 'a
  | Node of (string * 'a tree) list

let iter fn t =
  let rec aux path = function
    | Leaf l -> fn (List.rev path) l
    | Node n ->
      Lwt_list.iter_p (fun (l, t) ->
          aux (l::path) t
        ) n in
  aux [] t

(* XXX: do not load the blobs *)
let load_filesystem t commit =
  Log.debugf "load_filesystem %s" (SHA.Commit.to_hex commit);
  let n = ref 0 in
  let rec aux (mode, sha1) =
    read_exn t sha1 >>= function
    | Value.Blob b   -> incr n; return (Leaf (mode, b))
    | Value.Commit c -> aux (`Dir, SHA.of_tree c.Commit.tree)
    | Value.Tag t    -> aux (mode, t.Tag.sha1)
    | Value.Tree t   ->
      Misc.list_map_p (fun e ->
          aux (e.Tree.perm, e.Tree.node) >>= fun t ->
          return (e.Tree.name, t)
        ) t
      >>= fun children ->
      return (Node children)
  in
  aux (`Dir, SHA.of_commit commit) >>= fun t ->
  return (!n, t)

let iter_blobs t ~f ~init =
  load_filesystem t init >>= fun (n, trie) ->
  let i = ref 0 in
  Log.debugf "iter_blobs %s" (SHA.Commit.to_hex init);
  iter (fun path (mode, blob) ->
      incr i;
      f (!i, n) (t :: path) mode blob
    ) trie

let create_file file mode blob =
  Log.debugf "create_file %s" file;
  let blob = Blob.to_raw blob in
  match mode with
  | `Link -> (* Lwt_unix.symlink file ??? *) failwith "TODO"
  | _     ->
    IO.write_file file (Cstruct.of_string blob) >>= fun () ->
    match mode with
    | `Exec -> IO.chmod file 0o755
    | _     -> return_unit

let cache_file t =
  t / ".git" / "index"

let read_cache t =
  IO.read_file (cache_file t) >>= fun buf ->
  let buf = Mstruct.of_cstruct buf in
  return (Cache.input buf)

let entry_of_file ?root file mode blob =
  Log.debugf "entry_of_file %s" file;
  begin
    IO.file_exists file >>= function
    | true  -> return_unit
    | false -> create_file file mode blob
  end >>= fun () ->
  begin match root with
    | None   -> IO.getcwd ()
    | Some r -> IO.realpath r
  end >>= fun root ->
  IO.realpath file >>= fun file ->
  try
    let id = Value.sha1 (Value.Blob blob) in
    let stats = IO.stat_info file in
    let stage = 0 in
    match Misc.string_chop_prefix ~prefix:(root / "") file with
    | None      -> failwith ("entry_of_file: " ^ file)
    | Some name ->
      let entry = { Cache.stats; id; stage; name } in
      return (Some entry)
  with Failure _ ->
    return_none

let write_cache t head =
  Log.debugf "write_cache %s" (SHA.Commit.to_hex head);
  let entries = ref [] in
  let all = ref 0 in
  iter_blobs t ~init:head ~f:(fun (i,n) path mode blob ->
      all := n;
      printf "\rChecking out files: %d%% (%d/%d), done.%!" Pervasives.(100*i/n) i n;
      let file = String.concat Filename.dir_sep path in
      Log.debugf "write_cache: blob:%s" file;
      entry_of_file ~root:t file mode blob >>= function
      | None   -> return_unit
      | Some e -> entries := e :: !entries; return_unit
    ) >>= fun () ->
  let cache = { Cache.entries = !entries; extensions = [] } in
  let buf = Buffer.create 1024 in
  Cache.add buf cache;
  IO.write_file (cache_file t) (Cstruct.of_string (Buffer.contents buf)) >>= fun () ->
  printf "\rChecking out files: 100%% (%d/%d), done.%!\n" !all !all;
  return_unit

end
