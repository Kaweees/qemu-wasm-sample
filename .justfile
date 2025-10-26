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
QEMU_REPO_DIR := "external/qemu-wasm"
# # The base container image
QEMU_BUILD_CONTAINER := "build-qemu-base-wasm64"
IMAGE_NAME := "build-qemu-wasm64l"
OUTPUT_DIR := "/tmp/test"

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
  docker build --progress=plain -t {{QEMU_BUILD_CONTAINER}} --build-arg TARGET_CPU=wasm64 --build-arg WASM64_MEMORY64=2 - < {{QEMU_REPO_DIR}}/tests/docker/dockerfiles/emsdk-wasm-cross.docker
  docker build --progress=plain -t {{IMAGE_NAME}} --build-arg QEMU_BASE_IMAGE={{QEMU_BUILD_CONTAINER}} -f Dockerfile .
  @echo "Starting build container..."
  docker run --rm --init -d --name {{QEMU_BUILD_CONTAINER}} -v $(pwd)/{{QEMU_REPO_DIR}}:/qemu/:ro {{IMAGE_NAME}}
  @echo "Configuring and compiling QEMU with Wasm TCG backend..."
  docker exec {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /build && emconfigure /qemu/configure --cpu=wasm64 --enable-wasm64-32bit-address-limit --static --disable-tools --disable-docs --target-list=x86_64-softmmu && emmake make -j{{CORES}}"
  @echo "Bundling guest assets..."
  docker exec {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /build && mkdir -p pack && cp /images/kernel.img pack/ && cp /images/rootfs.bin pack/ && cp -r /qemu/pc-bios/* pack/ && /emsdk/upstream/emscripten/tools/file_packager.py qemu-system-x86_64.data --preload pack > load.js"
  @echo "Setting up web server..."
  docker exec {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /build && mkdir -p /tmp/test/htdocs/ && cp qemu-system-x86_64.js /tmp/test/htdocs/out.js && cp qemu-system-x86_64.wasm /tmp/test/htdocs/ && cp qemu-system-x86_64.data /tmp/test/htdocs/ && cp load.js /tmp/test/htdocs/ && cp -r /qemu/pc-bios/* /tmp/test/htdocs/"
  cp ./samples/index.html /tmp/test/htdocs/
  cp ./samples/module.js /tmp/test/htdocs/
  cp ./samples/cc.conf /tmp/test/
  @echo "Starting web server..."
  docker run --rm -d -p 127.0.0.1:8888:80 \
       -v "/tmp/test/htdocs:/usr/local/apache2/htdocs/:ro" \
       -v "/tmp/test/cc.conf:/usr/local/apache2/conf/extra/cc.conf:ro" \
       --entrypoint=/bin/sh httpd -c 'echo "Include conf/extra/cc.conf" >> /usr/local/apache2/conf/httpd.conf && httpd-foreground'

# @echo "Starting web server..."
# docker exec -d {{QEMU_BUILD_CONTAINER}} bash -c "cd /tmp/test/htdocs && python3 -m http.server 8888"
# @echo "You can now access QEMU at: http://localhost:8888"

# Start the web server (if build is already done)
serve:
  @echo "Starting web server..."
  docker exec -d {{QEMU_BUILD_CONTAINER}} bash -c "cd /tmp/test/htdocs && python3 -m http.server 8888"
  @echo "You can now access QEMU at: http://localhost:8888"

# Run a package
run:
  @echo "Running..."

# Remove build artifacts and non-essential files
clean:
  @echo "Cleaning..."
  docker rm -f {{IMAGE_NAME}} 2>/dev/null || true
  docker rm -f {{QEMU_BUILD_CONTAINER}} 2>/dev/null || true
