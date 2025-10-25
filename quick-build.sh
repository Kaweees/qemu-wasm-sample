#!/bin/bash

# QEMU Wasm TCG Backend Build Script
# This script automates the entire process of building QEMU with Wasm TCG backend support

set -e  # Exit on any error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_REPO_DIR="${SCRIPT_DIR}/qemu-wasm"
QEMU_BUILD_CONTAINER="build-qemu-wasm64"
BUILD_OPTION="1"  # Default to Option 1 (wasm64), can be overridden with --option2
SERVE_PORT="8888"
OUTPUT_DIR="/tmp/test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
QEMU Wasm TCG Backend Build Script

Usage: $0 [OPTIONS]

OPTIONS:
    --option1          Build for wasm64 (default)
    --option2          Build for wasm64 with wasm32 compatibility
    --clean            Clean up containers and temporary files
    --help             Show this help message

EXAMPLES:
    $0                 # Build with Option 1 (wasm64)
    $0 --option2       # Build with Option 2 (wasm64 with wasm32 compatibility)
    $0 --clean         # Clean up everything

This script will:
1. Clone the qemu-wasm repository if not present
2. Build the Docker environment
3. Compile QEMU with Wasm TCG backend
4. Bundle guest assets
5. Set up the web server

EOF
}

# Clean up function
cleanup() {
    log_info "Cleaning up..."

    # Stop and remove container if it exists
    if docker ps -q -f name=${QEMU_BUILD_CONTAINER} | grep -q .; then
        log_info "Stopping container ${QEMU_BUILD_CONTAINER}..."
        docker stop ${QEMU_BUILD_CONTAINER} || true
    fi

    if docker ps -aq -f name=${QEMU_BUILD_CONTAINER} | grep -q .; then
        log_info "Removing container ${QEMU_BUILD_CONTAINER}..."
        docker rm ${QEMU_BUILD_CONTAINER} || true
    fi

    # Remove Docker images
    log_info "Removing Docker images..."
    docker rmi build-qemu-wasm64 build-qemu-base-wasm64 2>/dev/null || true
    docker rmi build-qemu-wasm64l build-qemu-base-wasm64l 2>/dev/null || true

    # Clean up temporary files
    log_info "Cleaning up temporary files..."
    rm -rf ${OUTPUT_DIR} 2>/dev/null || true

    log_success "Cleanup completed!"
    exit 0
}

# Build Docker environment
build_docker_env() {
    log_info "Building Docker environment..."

    if [ "${BUILD_OPTION}" = "2" ]; then
        log_info "Building for wasm64 with wasm32 compatibility (Option 2)..."
        QEMU_BUILD_CONTAINER="build-qemu-wasm64l"
        docker build --progress=plain -t build-qemu-base-wasm64l \
            --build-arg TARGET_CPU=wasm64 --build-arg WASM64_MEMORY64=2 \
            - < ${QEMU_REPO_DIR}/tests/docker/dockerfiles/emsdk-wasm-cross.docker
        docker build --progress=plain -t build-qemu-wasm64l \
            --build-arg QEMU_BASE_IMAGE=build-qemu-base-wasm64l \
            -f Dockerfile .
    else
        log_info "Building for wasm64 (Option 1)..."
        docker build --progress=plain -t build-qemu-base-wasm64 \
            --build-arg TARGET_CPU=wasm64 --build-arg WASM64_MEMORY64=1 \
            - < ${QEMU_REPO_DIR}/tests/docker/dockerfiles/emsdk-wasm-cross.docker
        docker build --progress=plain -t build-qemu-wasm64 \
            --build-arg QEMU_BASE_IMAGE=build-qemu-base-wasm64 \
            -f Dockerfile .
    fi

    log_success "Docker environment built"
}

# Start build container
start_build_container() {
    log_info "Starting build container..."

    # Stop existing container if it exists
    if docker ps -q -f name=${QEMU_BUILD_CONTAINER} | grep -q .; then
        docker stop ${QEMU_BUILD_CONTAINER}
    fi
    if docker ps -aq -f name=${QEMU_BUILD_CONTAINER} | grep -q .; then
        docker rm ${QEMU_BUILD_CONTAINER}
    fi

    # Start new container
    if [ "${BUILD_OPTION}" = "2" ]; then
        IMAGE_NAME="build-qemu-wasm64l"
    else
        IMAGE_NAME="build-qemu-wasm64"
    fi

    docker run --rm --init -d --name ${QEMU_BUILD_CONTAINER} \
        -v ${QEMU_REPO_DIR}:/qemu/:ro \
        ${IMAGE_NAME}

    log_success "Build container started"
}

# Compile QEMU
compile_qemu() {
    log_info "Compiling QEMU with Wasm TCG backend..."

    if [ "${BUILD_OPTION}" = "2" ]; then
        log_info "Using Option 2 configuration (wasm64 with wasm32 compatibility)..."
        docker exec ${QEMU_BUILD_CONTAINER} bash -c "
            cd /build &&
            emconfigure /qemu/configure --cpu=wasm64 --enable-wasm64-32bit-address-limit --static --disable-tools --target-list=x86_64-softmmu &&
            emmake make -j\$(nproc)
        "
    else
        log_info "Using Option 1 configuration (wasm64)..."
        docker exec ${QEMU_BUILD_CONTAINER} bash -c "
            cd /build &&
            emconfigure /qemu/configure --cpu=wasm64 --static --disable-tools --target-list=x86_64-softmmu &&
            emmake make -j\$(nproc)
        "
    fi

    log_success "QEMU compilation completed"
}

# Bundle guest assets
bundle_assets() {
    log_info "Bundling guest assets..."

    docker exec ${QEMU_BUILD_CONTAINER} bash -c "
        cd /build &&
        mkdir -p pack &&
        cp /images/kernel.img pack/ &&
        cp /images/rootfs.bin pack/ &&
        cp -r /qemu/pc-bios/* pack/ &&
        /emsdk/upstream/emscripten/tools/file_packager.py qemu-system-x86_64.data --preload pack > load.js
    "

    log_success "Guest assets bundled"
}

# Set up web server
setup_web_server() {
    log_info "Setting up web server..."

    # Create output directory
    mkdir -p ${OUTPUT_DIR}/htdocs/

    # Copy generated files
    log_info "Copying generated files..."
    docker cp ${QEMU_BUILD_CONTAINER}:/build/qemu-system-x86_64.js ${OUTPUT_DIR}/htdocs/out.js

    for f in qemu-system-x86_64.wasm qemu-system-x86_64.data load.js; do
        docker cp ${QEMU_BUILD_CONTAINER}:/build/${f} ${OUTPUT_DIR}/htdocs/
    done

    # Copy sample files
    cp ${SCRIPT_DIR}/samples/{index.html,module.js} ${OUTPUT_DIR}/htdocs/
    cp ${SCRIPT_DIR}/samples/cc.conf ${OUTPUT_DIR}/

    # Start web server
    log_info "Starting web server on port ${SERVE_PORT}..."
    docker run --rm -d -p 127.0.0.1:${SERVE_PORT}:80 \
        --name qemu-wasm-server \
        -v "${OUTPUT_DIR}/htdocs:/usr/local/apache2/htdocs/:ro" \
        -v "${OUTPUT_DIR}/cc.conf:/usr/local/apache2/conf/extra/cc.conf:ro" \
        --entrypoint=/bin/sh httpd -c 'echo "Include conf/extra/cc.conf" >> /usr/local/apache2/conf/httpd.conf && httpd-foreground'

    log_success "Web server started"
    log_success "QEMU is now available at: http://localhost:${SERVE_PORT}"
}

# Main execution
main() {
    log_info "Starting QEMU Wasm TCG Backend Build Process"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --option1)
                BUILD_OPTION="1"
                shift
                ;;
            --option2)
                BUILD_OPTION="2"
                shift
                ;;
            --clean)
                cleanup
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    log_info "Using build option: ${BUILD_OPTION}"

    # Execute build steps
    build_docker_env
    start_build_container
    compile_qemu
    bundle_assets
    setup_web_server

    log_success "Build process completed successfully!"
    log_info "You can now access QEMU at: http://localhost:${SERVE_PORT}"
    log_info "To stop the web server, run: docker stop qemu-wasm-server"
    log_info "To clean up everything, run: $0 --clean"
}

# Run main function with all arguments
main "$@"
