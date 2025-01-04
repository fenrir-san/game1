
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
      ols
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
      shellHook = ''zsh; 
      export QT_FONT_DPI=96
      export GDK_SCALE=1
      export GDK_DPI_SCALE=1
      export SDL_VIDEODRIVER=wayland
      export WAYLAND_DISPLAY=wayland-1
      exit;'';
    };
  };
}
