type decoder = string -> (string, string) result
type encoder = string -> (string, string) result
type codec = { name : string; encoder : encoder; decoder : decoder }

module Gzip = struct
  let encoder ~time ~level str =
    let i = De.bigstring_create De.io_buffer_size in
    let o = De.bigstring_create De.io_buffer_size in
    let w = De.Lz77.make_window ~bits:15 in
    let q = De.Queue.create 0x1000 in
    let r = Stdlib.Buffer.create 0x1000 in
    let p = ref 0 in
    (* TODO: is configuration meant to be reused? *)
    let time () = Int32.of_float (time ()) in
    let cfg = Gz.Higher.configuration Gz.Unix time in
    let refill buf =
      let len = min (String.length str - !p) De.io_buffer_size in
      Bigstringaf.blit_from_string str ~src_off:!p buf ~dst_off:0 ~len;
      p := !p + len;
      len
    in
    let flush buf len =
      let str = Bigstringaf.substring buf ~off:0 ~len in
      Stdlib.Buffer.add_string r str
    in
    Gz.Higher.compress ~w ~q ~level ~refill ~flush () cfg i o;
    Ok (Stdlib.Buffer.contents r)

  let decoder : decoder =
   fun str ->
    let i = De.bigstring_create De.io_buffer_size in
    let o = De.bigstring_create De.io_buffer_size in
    let r = Stdlib.Buffer.create 0x1000 in
    let p = ref 0 in
    let refill buf =
      let len = min (String.length str - !p) De.io_buffer_size in
      Bigstringaf.blit_from_string str ~src_off:!p buf ~dst_off:0 ~len;
      p := !p + len;
      len
    in
    let flush buf len =
      let str = Bigstringaf.substring buf ~off:0 ~len in
      Stdlib.Buffer.add_string r str
    in
    match Gz.Higher.uncompress ~refill ~flush i o with
    | Ok _metadata -> Ok (Stdlib.Buffer.contents r)
    | Error (`Msg err) -> Error err
end

let gzip ?(level = 4) () : codec =
  let time = Unix.gettimeofday in
  { name = "gzip"; decoder = Gzip.decoder; encoder = Gzip.encoder ~level ~time }

let identity : codec =
  { name = "identity"; decoder = Result.ok; encoder = Result.ok }

let make content =
  let content_len = String.length content in
  let payload = Bytes.create @@ (content_len + 1 + 4) in
  (* write compressed flag (uint8) *)
  Bytes.set payload 0 '\x00';
  (* write msg length (uint32 be) *)
  let length = String.length content in
  Bytes.set_uint16_be payload 1 (length lsr 16);
  Bytes.set_uint16_be payload 3 (length land 0xFFFF);
  (* write msg *)
  Bytes.blit_string content 0 payload 5 content_len;
  Bytes.to_string payload

(** [extract_message buf] extracts the grpc message starting in [buf]
    in the buffer if there is one *)
let extract_message decoder buf =
  if Buffer.length buf >= 5 then
    let compressed =
      (* A Compressed-Flag value of 1 indicates that the binary octet
         sequence of Message is compressed using the mechanism declared by
         the Message-Encoding header. A value of 0 indicates that no encoding
         of Message bytes has occurred. Compression contexts are NOT
         maintained over message boundaries, implementations must create a
         new context for each message in the stream. If the Message-Encoding
         header is omitted then the Compressed-Flag must be 0. *)
      (* encoded as 1 byte unsigned integer *)
      Buffer.get_u8 buf ~pos:0 == 1
    and length =
      (* encoded as 4 byte unsigned integer (big endian) *)
      Buffer.get_u32_be buf ~pos:1
    in
    if Buffer.length buf - 5 >= length then
      let data = Buffer.sub buf ~start:5 ~length |> Buffer.to_string in
      if compressed then
        match decoder data with
        | Ok data -> Some data
        | Error error -> failwith ("Failed decoding " ^ error)
      else Some data
    else None
  else None

(** [get_message_and_shift buf] tries to extract the first grpc message
    from [buf] and if successful shifts these bytes out of the buffer *)
let get_message_and_shift decoder buf =
  let message = extract_message decoder buf in
  match message with
  | None -> None
  | Some message ->
      let mlen = String.length message in
      Buffer.shift_left buf ~by:(5 + mlen);
      Some message

let extract buf decoder = get_message_and_shift decoder buf

let extract_all f buf decoder =
  let rec loop () =
    match extract buf decoder with
    | None -> ()
    | Some message ->
        f message;
        loop ()
  in
  loop ()
