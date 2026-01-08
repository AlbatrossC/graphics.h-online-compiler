# =========================
# Base Image
# =========================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# =========================
# Base tools + Node 20
# =========================
RUN apt-get update && \
    apt-get install -y \
        curl \
        wget \
        ca-certificates \
        gnupg2 \
        software-properties-common \
        apt-transport-https \
        build-essential \
        xauth \
        xvfb \
        net-tools \
        procps \
        dos2unix \
        dbus-x11 \
        --no-install-recommends && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# =========================
# Enable i386 + Wine + MinGW
# =========================
RUN dpkg --add-architecture i386 && \
    sed -i 's|http://security.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y \
        gcc-mingw-w64-i686 \
        g++-mingw-w64-i686 \
        wine \
        wine32 \
        --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# =========================
# graphics.h install (exact WSL replica)
# =========================
RUN mkdir -p /usr/local/include/graphics_h /usr/local/lib/graphics_h

RUN wget -q https://raw.githubusercontent.com/acsfid/graphics.h/main/graphics.h \
        -O /usr/local/include/graphics_h/graphics.h && \
    wget -q https://raw.githubusercontent.com/acsfid/graphics.h/main/winbgim.h \
        -O /usr/local/include/graphics_h/winbgim.h && \
    wget -q https://raw.githubusercontent.com/acsfid/graphics.h/main/libbgi.a \
        -O /usr/local/lib/graphics_h/libbgi.a

# --- const-correctness patch (same as WSL script)
# ---- const-correctness patch (SAFE, targeted)
RUN sed -i 's/void initgraph( int \*graphdriver, int \*graphmode, char \*pathtodriver )/void initgraph( int *graphdriver, int *graphmode, const char *pathtodriver )/g' /usr/local/include/graphics_h/graphics.h && \
    sed -i 's/void initgraph(int\*, int\*, char\*)/void initgraph(int*, int*, const char*)/g' /usr/local/include/graphics_h/graphics.h && \
    sed -i 's/void initgraph(int \*, int \*, char \*)/void initgraph(int *, int *, const char *)/g' /usr/local/include/graphics_h/graphics.h && \
    sed -i 's/void outtext(char \*textstring)/void outtext(const char *textstring)/g' /usr/local/include/graphics_h/graphics.h && \
    sed -i 's/void outtextxy(int x, int y, char \*textstring)/void outtextxy(int x, int y, const char *textstring)/g' /usr/local/include/graphics_h/graphics.h && \
    sed -i 's/char \*getdrivername/const char *getdrivername/g' /usr/local/include/graphics_h/graphics.h

# =========================
# graphics.h wrapper (WSL-accurate)
# =========================
RUN cat > /usr/local/bin/graphics.h << 'EOF'
#!/usr/bin/env bash

if [ $# -eq 0 ]; then
    echo "Usage: graphics.h <source_file.cpp> [output_name]"
    exit 1
fi

SOURCE_FILE="$1"
OUTPUT_NAME="${2:-$(basename "${SOURCE_FILE%.*}")}"

if [[ ! "$OUTPUT_NAME" =~ \.exe$ ]]; then
    OUTPUT_NAME="${OUTPUT_NAME}.exe"
fi

if [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: Source file '$SOURCE_FILE' not found"
    exit 1
fi

i686-w64-mingw32-g++ "$SOURCE_FILE" \
  -I /usr/local/include/graphics_h \
  -L /usr/local/lib/graphics_h \
  -lbgi -lgdi32 -lcomdlg32 -luuid -loleaut32 -lole32 \
  -static-libgcc -static-libstdc++ \
  -o "$OUTPUT_NAME"
EOF

RUN dos2unix /usr/local/bin/graphics.h && chmod +x /usr/local/bin/graphics.h

# =========================
# Xpra (HTML5 streaming)
# =========================
RUN mkdir -p /etc/apt/keyrings && \
    wget -qO- https://xpra.org/gpg.asc | gpg --dearmor -o /etc/apt/keyrings/xpra.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/xpra.gpg] https://xpra.org/ jammy main" \
        > /etc/apt/sources.list.d/xpra.list && \
    apt-get update && \
    apt-get install -y \
        xpra \
        xpra-html5 \
        xpra-x11 \
        python3-xdg \
        --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# =========================
# Wine template (matches ~/.wine32_graphics)
# =========================
ENV WINEARCH=win32
ENV WINEPREFIX=/opt/wine-template
ENV DISPLAY=:99

RUN Xvfb :99 -screen 0 1024x768x16 & \
    sleep 2 && \
    wineboot -u && \
    sleep 5 && \
    wineserver -k || true

# =========================
# Application
# =========================
WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .

# Fix CRLF from Windows host (critical)
RUN find /app -type f \( -name "*.sh" -o -name "*.js" \) -exec dos2unix {} \;

RUN mkdir -p /app/temp

EXPOSE 3000

CMD ["node", "server.js"]
