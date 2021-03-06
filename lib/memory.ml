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
module Log = Log.Make(struct let section = "memory" end)

type t = {
  root   : string;
  values : (SHA.t, Value.t) Hashtbl.t;
  refs   : (Reference.t, SHA.Commit.t) Hashtbl.t;
  mutable head : Reference.head_contents option;
}

let root t =
  t.root

let stores = Hashtbl.create 1024

let create ?root () =
  let root = match root with
    | None   -> "root"
    | Some r -> r in
  let t =
    try Hashtbl.find stores root
    with Not_found ->
      let t = {
        root;
        values  = Hashtbl.create 1024;
        refs    = Hashtbl.create 8;
        head    = None;
      } in
      Hashtbl.add stores root t;
      t in
  return t

let clear t =
  Hashtbl.remove stores t.root;
  return_unit

let write t value =
  let inflated = Misc.with_buffer (fun buf -> Value.add_inflated buf value) in
  let sha1 = SHA.of_string inflated in
  try
    let _ = Hashtbl.find t.values sha1 in
    return sha1
  with Not_found ->
    Log.infof "Writing %s" (SHA.to_hex sha1);
    Hashtbl.add t.values sha1 value;
    return sha1

let write_pack t pack =
  let pack = Pack.to_pic pack in
  Misc.list_iter_p (fun (sha1, p) ->
      let v = Packed_value.PIC.to_value p in
      write t v >>= fun sha2 ->
      if SHA.(sha1 <> sha2) then failwith "Git_memory.write_pack";
      return_unit
    ) pack
  >>= fun () ->
  return (Pack.keys pack)

let keys t =
  Hashtbl.fold (fun k _ l -> k :: l) t []

let list t =
  return (keys t.values)

let read t sha1 =
  try return (Some (Hashtbl.find t.values sha1))
  with Not_found -> return_none

let mem t sha1 =
  return (Hashtbl.mem t.values sha1)

let read_exn t sha1 =
  read t sha1 >>= function
  | None   -> fail Not_found
  | Some v -> return v

let type_of t sha1 =
  read t sha1 >>= function
  | None   -> return_none
  | Some v -> return (Some (Value.type_of v))

let contents t =
  Log.debugf "contents";
  list t >>= fun sha1s ->
  Lwt_list.map_s (fun sha1 ->
      read_exn t sha1 >>= fun value ->
      return (sha1, value)
    ) sha1s

let dump t =
  contents t >>= fun contents ->
  List.iter (fun (sha1, value) ->
      let typ = Value.type_of value in
      Printf.eprintf "%s %s\n" (SHA.to_hex sha1) (Object_type.to_string typ)
    ) contents;
  return_unit

let references t =
  return (keys t.refs)

let mem_reference t ref =
  return (Hashtbl.mem t.refs ref)

let read_reference t ref =
  Log.infof "Reading %s" (Reference.pretty ref);
  try return (Some (Hashtbl.find t.refs ref))
  with Not_found -> return_none

let read_head t =
  Log.infof "Reading HEAD";
  return t.head

let remove_reference t ref =
  Hashtbl.remove t.refs ref;
  return_unit

let read_reference_exn t ref =
  read_reference t ref >>= function
  | None   -> fail Not_found
  | Some s -> return s

let write_head t c =
  Log.infof "Writing HEAD";
  t.head <- Some c;
  return_unit

let write_reference t ref sha1 =
  Log.infof "Writing %s" (Reference.pretty ref);
  Hashtbl.replace t.refs ref sha1;
  return_unit

let read_cache _t =
  failwith "Memory.read_cache: TODO"

let write_cache _t _head =
  failwith "Memory.update_cache: TODO"
