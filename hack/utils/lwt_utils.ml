open Hh_core

let select
    (read_fds : Unix.file_descr list)
    (write_fds : Unix.file_descr list)
    (exn_fds : Unix.file_descr list)
    (timeout : float)
    : (Unix.file_descr list * Unix.file_descr list * Unix.file_descr list) Lwt.t =
  let make_task
      ~(fds : Unix.file_descr list)
      ~(condition : Lwt_unix.file_descr -> bool)
      ~(wait_f : Lwt_unix.file_descr -> unit Lwt.t)
      : (Unix.file_descr list, Unix.file_descr list) result Lwt.t
      =
    try%lwt
      let fds = List.map fds ~f:Lwt_unix.of_unix_file_descr in
      let%lwt () = Lwt.pick (List.map fds ~f:wait_f) in
      let actionable_fds = fds
        |> List.filter ~f:condition
        |> List.map ~f:Lwt_unix.unix_file_descr
      in
      Lwt.return (Ok actionable_fds)
    with _ ->
      (* Although we gather a list of exceptional file descriptors here, it
      happens that no call site of `Unix.select` in the codebase has checked
      this list, so we could in theory just return any list (or not return any
      exceptional file descriptors at all). *)
      let exceptional_fds = List.filter exn_fds
        ~f:(fun fd -> List.mem fds fd) in
      Lwt.return (Error exceptional_fds)
  in

  let read_task =
    let%lwt readable_fds = make_task
      ~fds:read_fds
      ~condition:Lwt_unix.readable
      ~wait_f:Lwt_unix.wait_read
    in
    match readable_fds with
    | Ok fds -> Lwt.return (fds, [], [])
    | Error fds -> Lwt.return ([], [], fds)
  in
  let write_task =
    let%lwt writeable_fds = make_task
      ~fds:write_fds
      ~condition:Lwt_unix.writable
      ~wait_f:Lwt_unix.wait_write
    in
    match writeable_fds with
    | Ok fds -> Lwt.return ([], fds, [])
    | Error fds -> Lwt.return ([], [], fds)
  in

  let tasks = [
    read_task;
    write_task;
  ] in
  let tasks =
    if timeout > 0.0
    then
      let timeout_task =
        let%lwt () = Lwt_unix.sleep timeout in
        Lwt.return ([], [], [])
      in
      timeout_task :: tasks
    else
      failwith "Timeout <= 0 not implemented"
  in
  Lwt.pick tasks

let with_context ~enter ~exit ~do_ =
  enter ();
  let result =
    try%lwt
      let%lwt result = do_ () in
      Lwt.return result
    with e ->
      exit ();
      raise e
  in
  exit ();
  result

let wrap_non_reentrant_section
    ~(name: string)
    ~(lock: bool ref)
    ~(f : unit -> 'a Lwt.t)
    : 'a Lwt.t =
  let wrapped_f () =
    let () =
      if !lock
      then failwith (Printf.sprintf
        ("Function '%s' was called more than once in parallel (e.g. with Lwt), "
         ^^ "but it is marked as non-reentrant. Serialize your calls to '%s'.")
         name
         name)
    in
    with_context
      ~enter:(fun () -> lock := true)
      ~exit:(fun () -> lock := false)
      ~do_:f
  in
  let%lwt result = wrapped_f () in
  Lwt.return result
