#!/usr/bin/env bash
# Provision the browser-in-browser development VM:
# build tooling + Emscripten SDK (emsdk) + prerequisites for building
# Gecko/Firefox to WebAssembly (https://github.com/bit4bit/firefox-wasm).
#
# Versions follow the project's CI (.github/workflows/build-release.yml):
#   - Rust 1.95.0 exactly (newer rustc breaks the fork's rust.configure)
#   - libclang 21 (bindgen parses emscripten 6.0.1's LLVM-23 libc++ headers;
#     Ubuntu's stock libclang 18 is too old)
#   - Node 22 + pnpm via corepack
#   - ~24 GB swapfile: headroom for the wasm-opt / libxul link memory spikes
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
RUST_VERSION="1.95.0"
LLVM_VER=21
EMSDK_VERSION="6.0.1"  # pinned to the version the firefox-wasm fork builds with

echo "==> Installing build dependencies"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    cloud-guest-utils \
    cmake \
    curl \
    git \
    gnupg \
    libpulse-dev \
    lsb-release \
    mercurial \
    ninja-build \
    pkg-config \
    python3 \
    rsync \
    software-properties-common \
    unzip \
    wget \
    xz-utils \
    zstd

# bindgen (Gecko) needs a recent libclang to parse emscripten's libc++ headers.
if [ ! -e "/usr/lib/llvm-${LLVM_VER}/lib/libclang.so" ]; then
    echo "==> Installing libclang ${LLVM_VER} from apt.llvm.org"
    wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh
    chmod +x /tmp/llvm.sh
    sudo /tmp/llvm.sh "${LLVM_VER}"
    sudo apt-get install -y --no-install-recommends "libclang-${LLVM_VER}-dev"
fi

# ---------------------------------------------------------------------------
# Node.js 22 + pnpm (via corepack) for the gecko.js bundle and demos.
# ---------------------------------------------------------------------------
if ! command -v node > /dev/null 2>&1; then
    echo "==> Installing Node.js 22"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y --no-install-recommends nodejs
fi
sudo corepack enable

# ---------------------------------------------------------------------------
# Rust pinned to the version the firefox-wasm fork's configure supports,
# with rust-src and the wasm32-unknown-emscripten target (-Z build-std).
# ---------------------------------------------------------------------------
if ! command -v rustup > /dev/null 2>&1; then
    echo "==> Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal
fi
# shellcheck source=/dev/null
source "${HOME}/.cargo/env"
rustup toolchain install "${RUST_VERSION}" --profile minimal
rustup default "${RUST_VERSION}"
rustup component add rust-src
rustup target add wasm32-unknown-emscripten

# ---------------------------------------------------------------------------
# Shell environment: libclang for bindgen, larger stack for wasm-opt.
# ---------------------------------------------------------------------------
LIBCLANG_LINE="export LIBCLANG_PATH=/usr/lib/llvm-${LLVM_VER}/lib"
if grep -qF "LIBCLANG_PATH" "${HOME}/.bashrc"; then
    sed -i "s|^export LIBCLANG_PATH=.*|${LIBCLANG_LINE}|" "${HOME}/.bashrc"
else
    printf '\n# libclang for Gecko bindgen\n%s\n' "${LIBCLANG_LINE}" >> "${HOME}/.bashrc"
fi
if ! grep -qF "ulimit -s" "${HOME}/.bashrc"; then
    printf '# wasm-opt needs a big stack on the ~250MB gecko module\nulimit -s unlimited 2>/dev/null || true\n' >> "${HOME}/.bashrc"
fi

# ---------------------------------------------------------------------------
# Swap headroom for the libxul/wasm-opt link peaks (see CI workflow).
# Skipped while the root disk is still the small box image -- `rake dev:up`
# grows the disk first and then creates the swapfile (same commands).
# ---------------------------------------------------------------------------
AVAIL_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
if swapon --show | grep -q swapfile; then
    :
elif [ "${AVAIL_GB}" -lt 30 ]; then
    echo "==> Skipping swapfile (only ${AVAIL_GB}G free); created after disk grow"
else
    echo "==> Adding 24G swapfile"
    sudo fallocate -l 24G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=24576
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile > /dev/null
    sudo swapon /swapfile
    grep -qF "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
fi

# ---------------------------------------------------------------------------
# Emscripten SDK (system-wide checkout for standalone experiments; the
# firefox-wasm build clones its own repo-local emsdk 6.0.1 via `make emsdk`).
# ---------------------------------------------------------------------------
EMSDK_DIR="${HOME}/emsdk"

if [ ! -d "${EMSDK_DIR}" ]; then
    echo "==> Cloning emsdk"
    git clone --depth 1 https://github.com/emscripten-core/emsdk.git "${EMSDK_DIR}"
fi

echo "==> Installing Emscripten ${EMSDK_VERSION}"
"${EMSDK_DIR}/emsdk" install "${EMSDK_VERSION}"
"${EMSDK_DIR}/emsdk" activate "${EMSDK_VERSION}"

# Make emcc & friends available in login shells.
EMSENV_LINE='source "${HOME}/emsdk/emsdk_env.sh" > /dev/null 2>&1 || true'
if ! grep -qF "emsdk_env.sh" "${HOME}/.bashrc"; then
    echo "==> Adding emsdk environment to ~/.bashrc"
    printf '\n# Emscripten SDK\n%s\n' "${EMSENV_LINE}" >> "${HOME}/.bashrc"
fi

echo "==> Done. Installed versions:"
source "${EMSDK_DIR}/emsdk_env.sh" > /dev/null
emcc --version | head -1
clang --version | head -1
rustc --version
node --version
cmake --version | head -1
ninja --version
python3 --version
free -h | grep -i swap
