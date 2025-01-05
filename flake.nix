
{
  description = "The Sauce";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: 
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in
  {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
      sokol
      odin
      alsa-lib
      mesa
      libglvnd
      xorg.libXcursor
      xorg.libXi
      xorg.libX11
      xorg.libXrandr
      xorg.libXinerama
      xorg.xrandr
      xorg.xdpyinfo
      ];
      shellHook = ''
      export PATH="/home/fenrir/Documents/language_servers/ols:$PATH";
      zsh; 
      exit;'';
    };
  };
}
