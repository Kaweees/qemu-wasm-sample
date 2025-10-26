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
IMAGE_NAME := "build-qemu-wasm64"
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
  docker build --progress=plain -t {{QEMU_BUILD_CONTAINER}} --build-arg TARGET_CPU=wasm64 --build-arg WASM64_MEMORY64=1 - < {{QEMU_REPO_DIR}}/tests/docker/dockerfiles/emsdk-wasm-cross.docker
  docker build --progress=plain -t {{IMAGE_NAME}} --build-arg QEMU_BASE_IMAGE={{QEMU_BUILD_CONTAINER}} -f Dockerfile .
  @echo "Starting build container..."
  docker run --rm --init -d --name {{QEMU_BUILD_CONTAINER}} -v $(pwd)/{{QEMU_REPO_DIR}}:/qemu/:ro {{IMAGE_NAME}}
  @echo "Configuring and compiling QEMU with Wasm TCG backend..."
  docker exec {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /build && emconfigure /qemu/configure --cpu=wasm64 --static --disable-tools --target-list=x86_64-softmmu -Dcoroutine_backend=ucontext && emmake make -j{{CORES}}"
  @echo "Bundling guest assets..."
  docker exec {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /build && mkdir -p pack && cp /images/kernel.img pack/ && cp /images/rootfs.bin pack/ && cp -r /qemu/pc-bios/* pack/ && /emsdk/upstream/emscripten/tools/file_packager.py qemu-system-x86_64.data --preload pack > load.js"
  @echo "Setting up web server..."
  docker exec {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /build && mkdir -p /tmp/test/htdocs/ && cp qemu-system-x86_64.js /tmp/test/htdocs/out.js && cp qemu-system-x86_64.wasm /tmp/test/htdocs/ && cp qemu-system-x86_64.data /tmp/test/htdocs/ && cp load.js /tmp/test/htdocs/ && cp -r /qemu/pc-bios/* /tmp/test/htdocs/"
# cp ./samples/index.html /tmp/test/htdocs/
# cp ./samples/module.js /tmp/test/htdocs/
# cp ./samples/cc.conf /tmp/test/htdocs/


web:
  @echo "Creating public directory..."
  mkdir -p public
  cp ./samples/index.html public/
  cp ./samples/module.js public/
  cp ./samples/cc.conf public/
  docker cp {{QEMU_BUILD_CONTAINER}}:/build/qemu-system-x86_64.js public/out.js
  docker cp {{QEMU_BUILD_CONTAINER}}:/build/qemu-system-x86_64.wasm public/
  docker cp {{QEMU_BUILD_CONTAINER}}:/build/qemu-system-x86_64.data public/
  docker cp {{QEMU_BUILD_CONTAINER}}:/build/load.js public/
  docker cp {{QEMU_BUILD_CONTAINER}}:/qemu/pc-bios/ public/

# Start the web server
serve:
  @echo "Starting web server..."
  docker run --rm -d -p 127.0.0.1:8888:80 \
       -v "/tmp/test/htdocs:/usr/local/apache2/htdocs/:ro" \
       -v "/tmp/test/cc.conf:/usr/local/apache2/conf/extra/cc.conf:ro" \
       --entrypoint=/bin/sh httpd -c 'echo "Include conf/extra/cc.conf" >> /usr/local/apache2/conf/httpd.conf && httpd-foreground'
  @echo "You can now access QEMU at: http://localhost:8888"
# docker exec -d {{QEMU_BUILD_CONTAINER}} /bin/bash -c "cd /tmp/test/htdocs && python3 -m http.server 8888"

# Run a package
run:
  @echo "Running..."

# Remove build artifacts and non-essential files
clean:
  @echo "Cleaning..."
  rm -rf public
  # Stop and remove the build container
  docker stop {{QEMU_BUILD_CONTAINER}} 2>/dev/null || true
  docker rm -f {{QEMU_BUILD_CONTAINER}} 2>/dev/null || true
  # Clean up any containers using port 8888
  docker ps -q --filter "publish=8888" | xargs -r docker stop 2>/dev/null || true
  docker ps -aq --filter "publish=8888" | xargs -r docker rm 2>/dev/null || true
  # Remove images
  docker rmi {{IMAGE_NAME}} 2>/dev/null || true
  docker rmi {{QEMU_BUILD_CONTAINER}} 2>/dev/null || true
  # Clean up any dangling images
  docker image prune -f 2>/dev/null || true
