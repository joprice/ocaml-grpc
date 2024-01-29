type decoder = string -> (string, string) result
type encoder = string -> (string, string) result
type codec = { name : string; encoder : encoder; decoder : decoder }

val make : string -> string
(** [make s] encodes a string as a gRPC message. *)

val extract : Buffer.t -> decoder -> string option
(** [extract b] attempts to extract a gRPC message from [b]. *)

val extract_all : (string -> unit) -> Buffer.t -> decoder -> unit
(** [extract_all f b] extracts and calls [f] on all gRPC messages from [b]. *)

val gzip : ?level:int -> unit -> codec
val identity : codec
