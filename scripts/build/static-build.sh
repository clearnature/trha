#!/bin/bash
# Static build script for trha using Alpine Linux + Musl

set -e

# Configuration
PROJECT_NAME="trha"
BUILD_DIR="dist/static"
ALPINE_VERSION="3.19"
GHC_VERSION="9.4.8"
CABAL_VERSION="3.10.2.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on Alpine Linux
check_alpine() {
    if [ ! -f /etc/alpine-release ]; then
        log_error "This script must be run on Alpine Linux"
        exit 1
    fi
    log_info "Running on Alpine Linux $(cat /etc/alpine-release)"
}

# Install dependencies
install_dependencies() {
    log_info "Installing dependencies..."
    
    apk update
    apk add --no-cache \
        bash \
        curl \
        wget \
        git \
        gcc \
        g++ \
        make \
        musl-dev \
        zlib-dev \
        zlib-static \
        libffi-dev \
        libffi-static \
        gmp-dev \
        gmp-static \
        ncurses-dev \
        ncurses-static \
        xz \
        tar \
        gzip \
        bzip2 \
        perl \
        python3 \
        py3-pip
    
    log_info "Dependencies installed successfully"
}

# Install GHC
install_ghc() {
    log_info "Installing GHC ${GHC_VERSION}..."
    
    # Download GHC binary
    GHC_URL="https://downloads.haskell.org/~ghc/${GHC_VERSION}/ghc-${GHC_VERSION}-x86_64-alpine-linux.tar.xz"
    
    if [ ! -f "ghc-${GHC_VERSION}-x86_64-alpine-linux.tar.xz" ]; then
        wget -q "$GHC_URL"
    fi
    
    # Extract and install
    tar -xf "ghc-${GHC_VERSION}-x86_64-alpine-linux.tar.xz"
    cd "ghc-${GHC_VERSION}"
    ./configure --prefix=/usr/local
    make install
    cd ..
    
    # Cleanup
    rm -rf "ghc-${GHC_VERSION}" "ghc-${GHC_VERSION}-x86_64-alpine-linux.tar.xz"
    
    log_info "GHC ${GHC_VERSION} installed successfully"
}

# Install Cabal
install_cabal() {
    log_info "Installing Cabal ${CABAL_VERSION}..."
    
    # Download Cabal binary
    CABAL_URL="https://downloads.haskell.org/~cabal/cabal-install-${CABAL_VERSION}/cabal-install-${CABAL_VERSION}-x86_64-linux-musl.tar.xz"
    
    if [ ! -f "cabal-install-${CABAL_VERSION}-x86_64-linux-musl.tar.xz" ]; then
        wget -q "$CABAL_URL"
    fi
    
    # Extract and install
    tar -xf "cabal-install-${CABAL_VERSION}-x86_64-linux-musl.tar.xz"
    mv cabal /usr/local/bin/
    
    # Cleanup
    rm -f "cabal-install-${CABAL_VERSION}-x86_64-linux-musl.tar.xz"
    
    log_info "Cabal ${CABAL_VERSION} installed successfully"
}

# Build static binary
build_static() {
    log_info "Building static binary..."
    
    # Create build directory
    mkdir -p "$BUILD_DIR"
    
    # Update cabal packages
    cabal update
    
    # Build with static linking
    cabal build all \
        --ghc-options='-optl-static -optl-pthread' \
        --constraint='ghc-patched-unboxed-memcpy +static' \
        --constraint='base +static' \
        --constraint='bytestring +static' \
        --constraint='containers +static' \
        --constraint='text +static' \
        --constraint='transformers +static' \
        --constraint='mtl +static' \
        --constraint='stm +static' \
        --constraint='directory +static' \
        --constraint='filepath +static' \
        --constraint='process +static' \
        --constraint='time +static' \
        --constraint='unix +static' \
        --constraint='network +static' \
        --constraint='warp +static' \
        --constraint='wai +static' \
        --constraint='http-types +static' \
        --constraint='aeson +static' \
        --constraint='bytestring +static' \
        --constraint='text +static' \
        --constraint='vector +static' \
        --constraint='hashable +static' \
        --constraint='unordered-containers +static' \
        --constraint='scientific +static' \
        --constraint='integer-logarithms +static' \
        --constraint='primitive +static' \
        --constraint='tagged +static' \
        --constraint='base-compat +static' \
        --constraint='base-compat-batteries +static' \
        --constraint='dlist +static' \
        --constraint='generics-sop +static' \
        --constraint='indexed-traversable +static' \
        --constraint='indexed-traversable-instances +static' \
        --constraint='OneTuple +static' \
        --constraint='singleton-bool +static' \
        --constraint='some +static' \
        --constraint='strict +static' \
        --constraint='these +static' \
        --constraint='time-compat +static' \
        --constraint='tree-diff +static' \
        --constraint='uuid-types +static' \
        --constraint='witherable +static' \
        --constraint='contravariant +static' \
        --constraint='StateVar +static' \
        --constraint='assoc +static' \
        --constraint='bifunctors +static' \
        --constraint='comonad +static' \
        --constraint='distributive +static' \
        --constraint='invariant +static' \
        --constraint='profunctors +static' \
        --constraint='semigroupoids +static' \
        --constraint='semigroups +static' \
        --constraint='adjunctions +static' \
        --constraint='kan-extensions +static' \
        --constraint='free +static' \
        --constraint='exceptions +static' \
        --constraint='mmorph +static' \
        --constraint='resourcet +static' \
        --constraint='unliftio-core +static' \
        --constraint='lifted-base +static' \
        --constraint='lifted-async +static' \
        --constraint='safe-exceptions +static' \
        --constraint='unliftio +static' \
        --constraint='http-client +static' \
        --constraint='http-client-tls +static' \
        --constraint='http-types +static' \
        --constraint='mime-types +static' \
        --constraint='http-media +static' \
        --constraint='servant +static' \
        --constraint='servant-server +static' \
        --constraint='servant-client +static' \
        --constraint='servant-client-core +static' \
        --constraint='servant-server +static' \
        --constraint='warp +static' \
        --constraint='wai +static' \
        --constraint='wai-extra +static' \
        --constraint='wai-app-static +static' \
        --constraint='warp-tls +static' \
        --constraint='tls +static' \
        --constraint='crypton +static' \
        --constraint='crypton-x509 +static' \
        --constraint='crypton-x509-store +static' \
        --constraint='crypton-x509-validation +static' \
        --constraint='crypton-connection +static' \
        --constraint='data-default +static' \
        --constraint='data-default-class +static' \
        --constraint='data-default-instances-containers +static' \
        --constraint='data-default-instances-dlist +static' \
        --constraint='data-default-instances-old-locale +static' \
        --constraint='old-locale +static' \
        --constraint='old-time +static' \
        --constraint='simple-sendfile +static' \
        --constraint='unix-compat +static' \
        --constraint='unix-time +static' \
        --constraint='wai-logger +static' \
        --constraint='fast-logger +static' \
        --constraint='auto-update +static' \
        --constraint='easy-file +static' \
        --constraint='byteorder +static' \
        --constraint='word8 +static' \
        --constraint='iproute +static' \
        --constraint='network-byte-order +static' \
        --constraint='appar +static' \
        --constraint='bsb-http-chunked +static' \
        --constraint='case-insensitive +static' \
        --constraint='cookie +static' \
        --constraint='http-api-data +static' \
        --constraint='http-date +static' \
        --constraint='http-semantics +static' \
        --constraint='memory +static' \
        --constraint='basement +static' \
        --constraint='socks +static' \
        --constraint='x509 +static' \
        --constraint='x509-store +static' \
        --constraint='x509-system +static' \
        --constraint='x509-validation +static' \
        --constraint='async +static' \
        --constraint='hashable +static' \
        --constraint='random +static' \
        --constraint='splitmix +static' \
        --constraint='stm +static' \
        --constraint='tasty +static' \
        --constraint='tasty-hunit +static' \
        --constraint='tasty-quickcheck +static' \
        --constraint='QuickCheck +static' \
        --constraint='quickcheck-instances +static' \
        --constraint='tasty-discover +static' \
        --constraint='tasty-expected-failure +static' \
        --constraint='tasty-hedgehog +static' \
        --constraint='tasty-rerun +static' \
        --constraint='tasty-silver +static' \
        --constraint='tasty-th +static' \
        --constraint='tasty-wai +static' \
        --constraint='tasty-warp +static' \
        --constraint='hspec +static' \
        --constraint='hspec-core +static' \
        --constraint='hspec-discover +static' \
        --constraint='hspec-expectations +static' \
        --constraint='hspec-wai +static' \
        --constraint='hspec-wai-json +static' \
        --constraint='HUnit +static' \
        --constraint='call-stack +static' \
        --constraint='hspec-discover +static' \
        --constraint='QuickCheck +static' \
        --constraint='quickcheck-instances +static' \
        --constraint='random +static' \
        --constraint='splitmix +static' \
        --constraint='tf-random +static' \
        --constraint='tasty +static' \
        --constraint='tasty-hunit +static' \
        --constraint='tasty-quickcheck +static' \
        --constraint='tasty-discover +static' \
        --constraint='tasty-expected-failure +static' \
        --constraint='tasty-hedgehog +static' \
        --constraint='tasty-rerun +static' \
        --constraint='tasty-silver +static' \
        --constraint='tasty-th +static' \
        --constraint='tasty-wai +static' \
        --constraint='tasty-warp +static' \
        --constraint='tasty-hspec +static'
    
    # Copy binary to build directory
    cp dist-newstyle/build/x86_64-linux/ghc-${GHC_VERSION}/gh-harness-0.1.0.0/x/gh-harness/build/gh-harness/gh-harness "$BUILD_DIR/"
    
    log_info "Static binary built successfully"
}

# Verify binary
verify_binary() {
    log_info "Verifying binary..."
    
    BINARY="$BUILD_DIR/gh-harness"
    
    if [ ! -f "$BINARY" ]; then
        log_error "Binary not found: $BINARY"
        exit 1
    fi
    
    # Check if binary is statically linked
    if file "$BINARY" | grep -q "statically linked"; then
        log_info "Binary is statically linked"
    else
        log_warn "Binary may not be statically linked"
    fi
    
    # Check binary size
    SIZE=$(du -h "$BINARY" | cut -f1)
    log_info "Binary size: $SIZE"
    
    # Test binary
    if "$BINARY" --version >/dev/null 2>&1; then
        log_info "Binary is executable"
    else
        log_error "Binary is not executable"
        exit 1
    fi
    
    log_info "Binary verification completed"
}

# Create distribution package
create_package() {
    log_info "Creating distribution package..."
    
    PACKAGE_NAME="${PROJECT_NAME}-linux-x86_64"
    PACKAGE_DIR="$BUILD_DIR/$PACKAGE_NAME"
    
    # Create package directory
    mkdir -p "$PACKAGE_DIR"
    
    # Copy binary
    cp "$BUILD_DIR/gh-harness" "$PACKAGE_DIR/"
    
    # Create README
    cat > "$PACKAGE_DIR/README.md" << EOF
# gh-harness

A microkernel agent harness written in Haskell.

## Installation

1. Download the binary
2. Make it executable: \`chmod +x trha\`
3. Run it: \`./trha --help\`

## Usage

\`\`\`bash
# Start the CLI
./trha

# Start the HTTP server
./trha --server --port 8080

# Show help
./trha --help
\`\`\`

## Requirements

- Linux x86_64
- No additional dependencies required (statically linked)

## License

MIT
EOF
    
    # Create tar.gz package
    cd "$BUILD_DIR"
    tar -czf "${PACKAGE_NAME}.tar.gz" "$PACKAGE_NAME"
    cd -
    
    log_info "Distribution package created: $BUILD_DIR/${PACKAGE_NAME}.tar.gz"
}

# Main function
main() {
    log_info "Starting static build for $PROJECT_NAME"
    
    check_alpine
    install_dependencies
    install_ghc
    install_cabal
    build_static
    verify_binary
    create_package
    
    log_info "Static build completed successfully"
    log_info "Binary location: $BUILD_DIR/gh-harness"
    log_info "Package location: $BUILD_DIR/${PROJECT_NAME}-linux-x86_64.tar.gz"
}

# Run main function
main "$@"