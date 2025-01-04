# Variables
SHADER_SRC = sauce/shader/shader.glsl
SHADER_OUT = sauce/shader/shader.odin
ODIN_SRC = sauce
SHDC = ./sokol-shdc
ODIN = odin

# Targets
.PHONY: all clean

all: build

# Generate the shader.odin file
shader:
	$(SHDC) -i $(SHADER_SRC) -o $(SHADER_OUT) -l hlsl5:wgsl:glsl430 -f sokol_odin

# Build the Odin project
build: shader
	$(ODIN) build $(ODIN_SRC) -debug

# Clean up generated files (optional, modify as needed)
clean:
	rm -f $(SHADER_OUT)

