(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xenops_helpers

module D = Debug.Make(struct let name = "xenstore_watch" end)
open D

exception Watch_overflow

let _introduceDomain = "@introduceDomain"
let _releaseDomain = "@releaseDomain"

module IntMap = Map.Make(struct type t = int let compare = compare end)
module IntSet = Set.Make(struct type t = int let compare = compare end)

module type WATCH_ACTIONS = sig
	val watch_token : int -> string
	val interesting_paths_for_domain : int -> string -> string list
	val watch_fired : Xenctrl.handle -> string -> Xenctrl.domaininfo IntMap.t -> IntSet.t -> unit
	val unmanaged_domain : int -> string -> bool
	val found_running_domain : int -> string -> unit
	val domain_appeared : Xenctrl.handle -> int -> unit
	val domain_disappeared : Xenctrl.handle -> int -> unit
end

let watch xs token path =
	debug "xenstore watch path=%s token=%s" path token;
	Xs.watch xs path token

let unwatch xs token path =
	try
		debug "xenstore unwatch path=%s token=%s" path token;
		Xs.unwatch xs path token
	with Xs_protocol.Enoent _ ->
		debug "xenstore unwatch %s threw Xs_protocol.Enoent" path

module WatchXenstore = functor(Actions: WATCH_ACTIONS) -> struct

	let list_domains xc =
		let dis = Xenctrl.domain_getinfolist xc 0 in
		let ids = List.map (fun x -> x.Xenctrl.domid) dis in
		List.fold_left (fun map (k, v) -> IntMap.add k v map) IntMap.empty (List.combine ids dis)

	let domain_looks_different a b = match a, b with
		| None, Some _ -> true
		| Some _, None -> true
		| None, None -> false
		| Some a', Some b' ->
			let open Xenctrl in
			a'.shutdown <> b'.shutdown
			|| (a'.shutdown && b'.shutdown && (a'.shutdown_code <> b'.shutdown_code))

	let list_different_domains a b =
		let c = IntMap.merge (fun _ a b -> if domain_looks_different a b then Some () else None) a b in
		List.map fst (IntMap.bindings c)

	let watch_xenstore client =
		let xc = Xenctrl.interface_open () in
		try
		  let domains = ref IntMap.empty in
		  let watches = ref IntSet.empty in
		  let uuids = ref IntMap.empty in
		  
		  let add_watches_for_domain xs domid uuid =
		    debug "Adding watches for: domid %d" domid;
                    Actions.domain_appeared xc domid;
		    let token = Actions.watch_token domid in
		    List.iter (watch xs token) (Actions.interesting_paths_for_domain domid uuid);
		    uuids := IntMap.add domid uuid !uuids;
		    watches := IntSet.add domid !watches in
		  
		  let remove_watches_for_domain xs domid =
		    debug "Removing watches for: domid %d" domid;
                    Actions.domain_disappeared xc domid;
		    let token = Actions.watch_token domid in
		    if IntMap.mem domid !uuids then begin
		      let uuid = IntMap.find domid !uuids in
		      List.iter (unwatch xs token) (Actions.interesting_paths_for_domain domid uuid);
		      watches := IntSet.remove domid !watches;
		      uuids := IntMap.remove domid !uuids;
		    end in
		  
		  let look_for_different_domains () =
		    let domains' = list_domains xc in
		    let different = list_different_domains !domains domains' in
		    Xs.immediate client
		      (fun xs ->
			List.iter
			  (fun domid ->
			    let open Xenctrl in
			    debug "Domain %d may have changed state" domid;
			    (* The uuid is either in the new domains map or the old map. *)
			    let di = IntMap.find domid (if IntMap.mem domid domains' then domains' else !domains) in
			    let id = Uuid.string_of_uuid (Uuid.uuid_of_int_array di.handle) in
			    if Actions.unmanaged_domain domid id
			    then begin
			      debug "However domain %d is not managed by us: ignoring" domid;
			      if IntMap.mem domid !uuids then begin
				debug "Cleaning-up the remaining watches for: domid %d" domid;
				remove_watches_for_domain xs domid;
			      end;
			    end else begin
			      Actions.found_running_domain domid id;
			      (* A domain is 'running' if we know it has not shutdown *)
			      let running = IntMap.mem domid domains' && (not (IntMap.find domid domains').shutdown) in
			      match IntSet.mem domid !watches, running with
			      | true, true -> () (* still running, nothing to do *)
			      | false, false -> () (* still offline, nothing to do *)
			      | false, true ->
				add_watches_for_domain xs domid id
			      | true, false ->
				remove_watches_for_domain xs domid
			    end
			  ) different;
			domains := domains')
		  in
		  
		  let process_one_watch (path, token) =
		    if path = _introduceDomain || path = _releaseDomain
		    then look_for_different_domains ()
		    else 
		      Actions.watch_fired xc path !domains !watches in
		  
		  let register_for_watches () =
		    Xs.immediate client
		      (fun xs ->
                        Xs.set_watch_callback client (process_one_watch);
                        Xs.watch xs _introduceDomain "";
                        Xs.watch xs _releaseDomain "") in
		  
                  debug "Starting xenstore watch thread";
                  register_for_watches ()
		    
		with e ->
		  debug "Caught exception attempting to watch xenstore: %s" (Printexc.to_string e);
		  Xenctrl.interface_close xc;
		  raise e

	let rec create_watcher_thread client =
	  try
	    watch_xenstore client;
	  with e -> 
	    debug "watch_xenstore thread raised: %s" (Printexc.to_string e);
	    debug "watch_xenstore thread backtrace: %s" (Printexc.get_backtrace ());
	    Thread.delay 5.;
	    create_watcher_thread client

end