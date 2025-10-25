# Like GNU `make`, but `just` rustier.
# https://just.systems/
# run `just` from this directory to see available commands

alias i := install
alias b := build
alias r := run
alias c := clean

# Get the number of cores
CORES := if os() == "macos" { `sysctl -n hw.ncpu` } else if os() == "linux" { `nproc` } else { "1" }

# The container name.
TARGET := "build-qemu-wasm64"
QEMU_REPO_DIR := "external/qemu-wasm"
# # The container network name.
# NETWORK_NAME := ros
# # The base container image based on your architecture.
QEMU_BUILD_CONTAINER := "build-qemu-base-wasm64"

# Default command when 'just' is run without arguments
default:
  @just --list

# Install the virtual environment and pre-commit hooks
install:
  @echo "Installing..."

# Build the project
build:
  @echo "Building..."
  @echo "Building Docker environment..."
  docker build --progress=plain -t {{QEMU_BUILD_CONTAINER}} \
    --build-arg TARGET_CPU=wasm64 --build-arg WASM64_MEMORY64=2 \
    - < {{QEMU_REPO_DIR}}/tests/docker/dockerfiles/emsdk-wasm-cross.docker
  docker build --progress=plain -t {{TARGET}} \
    --build-arg QEMU_BASE_IMAGE={{QEMU_BUILD_CONTAINER}} \
    -f Dockerfile .
  @echo "Compiling QEMU with Wasm TCG backend..."
  docker exec {{QEMU_BUILD_CONTAINER}} bash -c "cd /build && emconfigure /qemu/configure --cpu=wasm64 --enable-wasm64-32bit-address-limit --static --disable-tools --target-list=x86_64-softmmu && emmake make -j{{CORES}}"

# Run a package
run:
  @echo "Running..."

# Remove build artifacts and non-essential files
clean:
  @echo "Cleaning..."
  docker rm -f {{TARGET}} 2>/dev/null || true
  docker rm -f {{QEMU_BUILD_CONTAINER}} 2>/dev/null || true
