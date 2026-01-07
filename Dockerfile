FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Enable 32-bit architecture
RUN dpkg --add-architecture i386

# Install MinGW, Wine, nano
RUN apt update && \
    apt install -y --no-install-recommends \
        gcc-mingw-w64-i686 \
        g++-mingw-w64-i686 \
        wine \
        wine32 \
        wine64 \
        ca-certificates \
        nano && \
    rm -rf /var/lib/apt/lists/*

# Workspace mounted from host
WORKDIR /workspace

# Initialize Wine prefix (optional but avoids first-run noise)
RUN wineboot --init || true

# Interactive shell
CMD ["/bin/bash"]
