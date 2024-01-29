module ServiceMap = Map.Make (String)

type service = H2.Reqd.t -> Grpc.Message.codec -> unit
type t = Grpc.Message.codec list * service ServiceMap.t

(*  TODO: pass in *)
(* let supported_codecs = *)
(*   [ Grpc.Message.gzip ~level:4 (); Grpc.Message.identity ] *)
(* in *)

let v ?(codecs = [ Grpc.Message.identity ]) () = (codecs, ServiceMap.empty)

let add_service ~name ~service (codecs, services) =
  (codecs, ServiceMap.add name service services)

let unsupported_decoder reqd =
  H2.Reqd.respond_with_string reqd
    (H2.Response.create
       ~headers:
         (H2.Headers.of_list
            [
              ( "grpc-status",
                Grpc.Status.(Unimplemented |> int_of_code |> string_of_int) );
              ("grpc-accept-encoding", "identity");
              ("grpc-message", "Unsupported compression type");
            ])
       `OK)
    ""

let handle_request (codecs, t) reqd =
  let request = H2.Reqd.request reqd in
  let respond_with code =
    H2.Reqd.respond_with_string reqd (H2.Response.create code) ""
  in
  let route ~(codec : Grpc.Message.codec) () =
    let parts = String.split_on_char '/' request.target in
    if List.length parts > 1 then
      (* allow for arbitrary prefixes *)
      let service_name = List.nth parts (List.length parts - 2) in
      let service = ServiceMap.find_opt service_name t in
      match service with
      | Some service -> service reqd codec
      | None -> respond_with `Not_found
    else respond_with `Not_found
  in
  match request.meth with
  | `POST -> (
      match H2.Headers.get request.headers "content-type" with
      | Some s ->
          if String.starts_with ~prefix:"application/grpc" s then
            match H2.Headers.get request.headers "grpc-encoding" with
            | None | Some "gzip" | Some "identity" -> (
                match H2.Headers.get request.headers "grpc-accept-encoding" with
                | None -> route ~codec:Grpc.Message.identity ()
                | Some encodings -> (
                    let encodings = String.split_on_char ',' encodings in
                    let codec =
                      encodings
                      |> List.find_map (fun name ->
                             codecs
                             |> List.find_map
                                  (fun (codec : Grpc.Message.codec) ->
                                    if codec.name = name then Some codec
                                    else None))
                    in
                    match codec with
                    | Some codec -> route ~codec ()
                    | None -> unsupported_decoder reqd))
            | Some _ ->
                (* TODO: not sure if there is a specific way to handle this in grpc *)
                respond_with `Bad_request
          else respond_with `Unsupported_media_type
      | None -> respond_with `Unsupported_media_type)
  | _ -> respond_with `Not_found

module Rpc = struct
  type unary = string -> Grpc.Status.t * string option
  type client_streaming = string Seq.t -> Grpc.Status.t * string option
  type server_streaming = string -> (string -> unit) -> Grpc.Status.t

  type bidirectional_streaming =
    string Seq.t -> (string -> unit) -> Grpc.Status.t

  type t =
    | Unary of unary
    | Client_streaming of client_streaming
    | Server_streaming of server_streaming
    | Bidirectional_streaming of bidirectional_streaming

  let bidirectional_streaming ~f reqd (codec : Grpc.Message.codec) =
    let body = H2.Reqd.request_body reqd in
    let request_reader, request_writer = Seq.create_reader_writer () in
    let response_reader, response_writer = Seq.create_reader_writer () in
    Connection.grpc_recv_streaming body request_writer codec.decoder;
    let status_promise, status_notify = Eio.Promise.create () in
    Eio.Fiber.both
      (fun () ->
        let respond = Seq.write response_writer in
        let status = f request_reader respond in
        Seq.close_writer response_writer;
        Eio.Promise.resolve status_notify status)
      (fun () ->
        try
          Connection.grpc_send_streaming reqd response_reader status_promise
            codec
        with exn ->
          (* https://github.com/anmonteiro/ocaml-h2/issues/175 *)
          Eio.traceln "%s" (Printexc.to_string exn))

  let client_streaming ~f reqd =
    bidirectional_streaming reqd ~f:(fun requests respond ->
        let status, response = f requests in
        (match response with None -> () | Some response -> respond response);
        status)

  let server_streaming ~f reqd =
    bidirectional_streaming reqd ~f:(fun requests respond ->
        match Seq.read_and_exhaust requests with
        | None -> Grpc.Status.(v OK)
        | Some request -> f request respond)

  let unary ~f reqd =
    bidirectional_streaming reqd ~f:(fun requests respond ->
        match Seq.read_and_exhaust requests with
        | None -> Grpc.Status.(v OK)
        | Some request ->
            let status, response = f request in
            (match response with
            | None -> ()
            | Some response -> respond response);
            status)
end

module Service = struct
  module RpcMap = Map.Make (String)

  type t = Rpc.t RpcMap.t

  let v () = RpcMap.empty
  let add_rpc ~name ~rpc t = RpcMap.add name rpc t

  let handle_request (t : t) reqd decoder =
    let request = H2.Reqd.request reqd in
    let respond_with code =
      H2.Reqd.respond_with_string reqd (H2.Response.create code) ""
    in
    let parts = String.split_on_char '/' request.target in
    if List.length parts > 1 then
      let rpc_name = List.nth parts (List.length parts - 1) in
      let rpc = RpcMap.find_opt rpc_name t in
      match rpc with
      | Some rpc -> (
          match rpc with
          | Unary f -> Rpc.unary ~f reqd decoder
          | Client_streaming f -> Rpc.client_streaming ~f reqd decoder
          | Server_streaming f -> Rpc.server_streaming ~f reqd decoder
          | Bidirectional_streaming f ->
              Rpc.bidirectional_streaming ~f reqd decoder)
      | None -> respond_with `Not_found
    else respond_with `Not_found
end
