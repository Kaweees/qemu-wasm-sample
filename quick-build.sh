#!/bin/bash

# Quick QEMU Wasm Build Script
# Simplified version for quick builds

set -e

echo "🚀 Quick QEMU Wasm Build Script"
echo "================================"

# Configuration
QEMU_REPO_DIR="./qemu-wasm"
QEMU_BUILD_CONTAINER="build-qemu-wasm64"
QEMU_SERVER_CONTAINER="qemu-wasm-server"
OUTPUT_DIR="/tmp/test"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up containers..."
    docker stop ${QEMU_BUILD_CONTAINER} 2>/dev/null || true
    docker rm ${QEMU_BUILD_CONTAINER} 2>/dev/null || true
    docker stop ${QEMU_SERVER_CONTAINER} 2>/dev/null || true
    docker rm ${QEMU_SERVER_CONTAINER} 2>/dev/null || true
}

# Set trap to cleanup on script exit
trap cleanup EXIT

# Check if qemu-wasm exists, if not clone it
if [ ! -d "${QEMU_REPO_DIR}" ]; then
    echo "📥 Cloning qemu-wasm repository..."
    git clone https://github.com/ktock/qemu-wasm.git "${QEMU_REPO_DIR}"
    cd "${QEMU_REPO_DIR}"
    git checkout wasm64-tcg-b
    cd ..
fi

# Set QEMU_REPO environment variable
export QEMU_REPO="$(pwd)/qemu-wasm"

echo "🐳 Building Docker environment..."
docker build --progress=plain -t build-qemu-base-wasm64 \
    --build-arg TARGET_CPU=wasm64 --build-arg WASM64_MEMORY64=1 \
    - < ${QEMU_REPO}/tests/docker/dockerfiles/emsdk-wasm-cross.docker

docker build --progress=plain -t build-qemu-wasm64 \
    --build-arg QEMU_BASE_IMAGE=build-qemu-base-wasm64 \
    -f Dockerfile .

echo "🏗️ Starting build container..."
# Clean up any existing containers before starting
cleanup
docker run --rm --init -d --name ${QEMU_BUILD_CONTAINER} \
    -v ${QEMU_REPO}:/qemu/ build-qemu-wasm64

echo "⚙️ Compiling QEMU..."
docker exec ${QEMU_BUILD_CONTAINER} bash -c "
    cd /build &&
    emconfigure /qemu/configure --cpu=wasm64 --static --disable-tools --target-list=x86_64-softmmu &&
    emmake make -j\$(nproc)
"

echo "📦 Bundling guest assets..."
docker exec ${QEMU_BUILD_CONTAINER} bash -c "
    cd /build &&
    mkdir -p pack &&
    cp /images/kernel.img pack/ &&
    cp /images/rootfs.bin pack/ &&
    cp -r /qemu/pc-bios/* pack/ &&
    /emsdk/upstream/emscripten/tools/file_packager.py qemu-system-x86_64.data --preload pack > load.js
"

echo "🌐 Setting up web server..."
mkdir -p ${OUTPUT_DIR}/htdocs/
docker cp ${QEMU_BUILD_CONTAINER}:/build/qemu-system-x86_64.js ${OUTPUT_DIR}/htdocs/out.js

for f in qemu-system-x86_64.wasm qemu-system-x86_64.data load.js; do
    docker cp ${QEMU_BUILD_CONTAINER}:/build/${f} ${OUTPUT_DIR}/htdocs/
done

cp ./samples/{index.html,module.js} ${OUTPUT_DIR}/htdocs/
cp ./samples/cc.conf ${OUTPUT_DIR}/

echo "🚀 Starting web server on localhost:8888..."
docker run --rm -d -p 127.0.0.1:8888:80 \
    --name ${QEMU_SERVER_CONTAINER} \
    -v "${OUTPUT_DIR}/htdocs:/usr/local/apache2/htdocs/:ro" \
    -v "${OUTPUT_DIR}/cc.conf:/usr/local/apache2/conf/extra/cc.conf:ro" \
    --entrypoint=/bin/sh httpd -c 'echo "Include conf/extra/cc.conf" >> /usr/local/apache2/conf/httpd.conf && httpd-foreground'

echo "✅ Build completed!"
echo "🌐 QEMU is now available at: http://localhost:8888"
echo "🛑 To stop the server: docker stop ${QEMU_SERVER_CONTAINER}"
