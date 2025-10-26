#!/bin/bash

set -euo pipefail

# SOURCE=./src/
DEST=./out/
QEMU_WASM_REPO_V="external/qemu-wasm"
BUILD_CONTAINER_NAME=build-qemu-wasm-demo

mkdir -p "${DEST}"
ls "${DEST}"

# Convert to absolute path for Docker volume mount
QEMU_WASM_REPO_ABS="$(realpath "${QEMU_WASM_REPO_V}")"

# raspi demo
docker build -t buildqemu-tmp - < "${QEMU_WASM_REPO_V}/Dockerfile"
docker run --rm -d --name "${BUILD_CONTAINER_NAME}" -v "${QEMU_WASM_REPO_ABS}":/qemu/:ro buildqemu-tmp
EXTRA_CFLAGS="-O3 -g -fno-inline-functions -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG -DG_DISABLE_ASSERT -D_GNU_SOURCE -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH -sTOTAL_MEMORY=2300MB -sWASM_BIGINT -sMALLOC=emmalloc --js-library=/build/node_modules/xterm-pty/emscripten-pty.js -sEXPORT_ES6=1 "
docker exec -it "${BUILD_CONTAINER_NAME}" emconfigure /qemu/configure --static --target-list=aarch64-softmmu --cpu=wasm32 --cross-prefix= \
       --without-default-features --enable-system --with-coroutine=fiber \
       --extra-cflags="$EXTRA_CFLAGS" --extra-cxxflags="$EXTRA_CFLAGS" --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY"
docker exec -it "${BUILD_CONTAINER_NAME}" emmake make -j $(nproc) qemu-system-aarch64

TMPDIR=$(mktemp -d)

mkdir "${TMPDIR}/pack"
docker build --output=type=local,dest="${TMPDIR}/pack" "${QEMU_WASM_REPO_V}"/examples/raspi3ap/image/
docker cp "${TMPDIR}/pack" "${BUILD_CONTAINER_NAME}":/
docker exec -it "${BUILD_CONTAINER_NAME}" /bin/sh -c "/emsdk/upstream/emscripten/tools/file_packager.py qemu-system-aarch64.data --preload /pack > load.js"

mkdir "${DEST}/raspi3ap"
docker cp "${BUILD_CONTAINER_NAME}":/build/qemu-system-aarch64 "${DEST}/raspi3ap/out.js"
for f in qemu-system-aarch64.wasm qemu-system-aarch64.worker.js qemu-system-aarch64.data load.js ; do
    docker cp "${BUILD_CONTAINER_NAME}":/build/${f} "${DEST}/raspi3ap/"
done

# alpine demo
EXTRA_CFLAGS="-O3 -g -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG -DG_DISABLE_ASSERT -D_GNU_SOURCE -sLZ4=1 -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH -sTOTAL_MEMORY=2300MB -sWASM_BIGINT -sMALLOC=emmalloc --js-library=/build/node_modules/xterm-pty/emscripten-pty.js -sEXPORT_ES6=1 -sASYNCIFY_IMPORTS=ffi_call_js"
docker exec -it "${BUILD_CONTAINER_NAME}" emconfigure /qemu/configure --static --target-list=x86_64-softmmu --cpu=wasm32 --cross-prefix= \
       --without-default-features --enable-system --with-coroutine=fiber --enable-virtfs \
       --extra-cflags="$EXTRA_CFLAGS" --extra-cxxflags="$EXTRA_CFLAGS" --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS"
docker exec -it "${BUILD_CONTAINER_NAME}" emmake make -j $(nproc) qemu-system-x86_64

mkdir "${DEST}/alpine-x86_64"

mkdir "${TMPDIR}"/{pack-kernel,pack-initramfs,pack-rootfs,pack-rom}
docker build --progress=plain --build-arg PACKAGES="vim python3" --output type=local,dest="${TMPDIR}" "${QEMU_WASM_REPO_V}"/examples/x86_64-alpine/image/
cp "${TMPDIR}"/vmlinuz-virt "${TMPDIR}"/pack-kernel/
cp "${TMPDIR}"/initramfs-virt "${TMPDIR}"/pack-initramfs/
cp "${TMPDIR}"/disk-rootfs.img "${TMPDIR}"/pack-rootfs/
cp "${QEMU_WASM_REPO_V}"/pc-bios/{bios-256k.bin,vgabios-stdvga.bin,kvmvapic.bin,linuxboot_dma.bin,efi-virtio.rom} "${TMPDIR}"/pack-rom/
for f in kernel initramfs rom rootfs ; do
    docker cp "${TMPDIR}"/pack-${f} "${BUILD_CONTAINER_NAME}":/
    flags=
    if [ "${f}" == "rootfs" ] ; then
       flags=--lz4
    fi
    docker exec -it "${BUILD_CONTAINER_NAME}" /bin/sh -c "/emsdk/upstream/emscripten/tools/file_packager.py load-${f}.data ${flags} --preload /pack-${f} > load-${f}.js"
    docker cp "${BUILD_CONTAINER_NAME}":/build/load-${f}.js "${DEST}/alpine-x86_64/"
    docker cp "${BUILD_CONTAINER_NAME}":/build/load-${f}.data "${DEST}/alpine-x86_64/"
done
( cd "${QEMU_WASM_REPO_V}"/examples/networking/htdocs/ && npx webpack )
cp -R "${QEMU_WASM_REPO_V}"/examples/networking/htdocs/dist "${DEST}/alpine-x86_64/"
wget -O - https://github.com/ktock/container2wasm/releases/download/v0.5.0/c2w-net-proxy.wasm | gzip > "${DEST}/alpine-x86_64/c2w-net-proxy.wasm.gzip"
docker cp "${BUILD_CONTAINER_NAME}":/build/qemu-system-x86_64 "${DEST}/alpine-x86_64/out.js"
for f in qemu-system-x86_64.wasm qemu-system-x86_64.worker.js ; do
    docker cp "${BUILD_CONTAINER_NAME}":/build/${f} "${DEST}/alpine-x86_64/"
done

docker kill "${BUILD_CONTAINER_NAME}"
rm -r "${TMPDIR}"
