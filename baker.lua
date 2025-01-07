return {
  build = {
    "./sokol-shdc -i ./sauce/shader/shader.glsl -o ./sauce/shader/shader.odin -l hlsl5:wgsl:glsl430 -f sokol_odin",
    "odin build sauce -debug -show-timings"
  },
  test = {"odin test main.odin"},
  clean = {"rm -rf build"},
  run = {"./sauce.bin"}
}
