{
  description = "A modular gRPC library";

  inputs = {
    # nixpkgs = {
    #   url = "github:sternenseemann/nixpkgs/ppx_deriving-5.1";
    # };
    nixpkgs = {
      url = "github:nix-ocaml/nix-overlays";
    };
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      with nixpkgs.legacyPackages.${system}.appendOverlays [
        (self: super: {
          ocamlPackages = super.ocaml-ng.ocamlPackages_5_1;
        })
      ];
      # let
      #   h2-src = fetchFromGitHub {
      #     owner = "jeffa5";
      #     repo = "ocaml-h2";
      #     rev = "36bd7bfa46fb0eb2bce184413f663a46a5e0dd3b";
      #     sha256 = "sha256-8vsRpx0JVN6KHOVfKit6LhlQqGTO1ofRhfyDgJ7dGz0=";
      #   };
      #
      #   hpack = ocamlPackages.buildDunePackage {
      #     pname = "hpack";
      #     version = "0.2.0";
      #     src = h2-src;
      #     useDune2 = true;
      #     buildInputs = (with ocamlPackages; [ angstrom faraday ]);
      #   };
      #
      #   h2 = ocamlPackages.buildDunePackage {
      #     pname = "h2";
      #     version = "0.7.0";
      #     src = h2-src;
      #     useDune2 = true;
      #     buildInputs = (with ocamlPackages; [ hpack result httpaf psq base64 ]);
      #   };
      # in
      rec {
        packages = rec {
          grpc =
            ocamlPackages.buildDunePackage {
              pname = "grpc";
              version = "0.1.0";
              src = self;
              useDune2 = true;
              doCheck = true;
              buildInputs = (with ocamlPackages; [
                ocaml-protoc-plugin
                uri
                h2
                ppx_deriving
              ]);
            };

          grpc-lwt =
            ocamlPackages.buildDunePackage {
              pname = "grpc-lwt";
              version = "0.1.0";
              src = self;
              useDune2 = true;
              doCheck = true;
              buildInputs = (with ocamlPackages; [ ocaml-protoc lwt stringext h2 grpc ]);
            };
        };

        defaultPackage = packages.grpc;

        devShells.default = mkShell {
          inputsFrom = [
            packages.grpc
          ];
          nativeBuildInputs = [
            protobuf
            pkg-config
          ];
          buildInputs = with ocamlPackages; [
            ocaml
            m4
            nixpkgs-fmt
            rnix-lsp
            ppx_jane
            h2-lwt-unix
            core_unix
            ppx_deriving_yojson
            ppx_deriving_yojson
            conduit-lwt-unix
            h2-async
            h2-eio
            #bechamel-notty
          ];

          #shellHook = ''
          #  eval $(opam env)
          #'';
        };
      });
}
