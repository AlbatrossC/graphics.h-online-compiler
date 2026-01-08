# graphics.h Docker environment with noVNC (browser display)
# More reliable than Xpra with proper web interface

FROM ubuntu:22.04

# ============================================================================
# LAYER 1: Package Installation (CACHED)
# ============================================================================
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gcc-mingw-w64-i686 \
        g++-mingw-w64-i686 \
        wine32 \
        wine \
        nano \
        vim \
        curl \
        git \
        supervisor \
        x11vnc \
        xvfb \
        fluxbox \
        novnc \
        websockify \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ============================================================================
# LAYER 2: Wine Initialization (CACHED)
# ============================================================================
ENV WINEARCH=win32
ENV WINEPREFIX=/root/.wine32_graphics
ENV DISPLAY=:99
ENV WINEDEBUG=-all

RUN wineboot -u 2>/dev/null || true

# ============================================================================
# LAYER 3: Directory Setup (CACHED)
# ============================================================================
RUN mkdir -p /usr/local/include/graphics_h /usr/local/lib/graphics_h

# ============================================================================
# LAYER 4: Copy and Patch graphics.h files
# ============================================================================
COPY graphics/winbgim.h /usr/local/include/graphics_h/
COPY graphics/libbgi.a /usr/local/lib/graphics_h/
COPY graphics/graphics.h /tmp/graphics.h

# Patch graphics.h for const-correctness
RUN sed -i 's/void initgraph( int \*graphdriver, int \*graphmode, char \*pathtodriver )/void initgraph( int *graphdriver, int *graphmode, const char *pathtodriver )/g' /tmp/graphics.h && \
    sed -i 's/void initgraph(int\*, int\*, char\*)/void initgraph(int*, int*, const char*)/g' /tmp/graphics.h && \
    sed -i 's/void outtext(char \*textstring)/void outtext(const char *textstring)/g' /tmp/graphics.h && \
    sed -i 's/void outtext(char\*)/void outtext(const char*)/g' /tmp/graphics.h && \
    sed -i 's/void outtextxy(int x, int y, char \*textstring)/void outtextxy(int x, int y, const char *textstring)/g' /tmp/graphics.h && \
    sed -i 's/void outtextxy(int, int, char\*)/void outtextxy(int, int, const char*)/g' /tmp/graphics.h && \
    sed -i 's/char \*getdrivername/const char *getdrivername/g' /tmp/graphics.h && \
    sed -i 's/char\* getdrivername/const char* getdrivername/g' /tmp/graphics.h && \
    mv /tmp/graphics.h /usr/local/include/graphics_h/

# ============================================================================
# LAYER 5: Setup noVNC
# ============================================================================
RUN mkdir -p /opt/noVNC/utils/websockify && \
    ln -s /usr/share/novnc/vnc.html /opt/noVNC/index.html && \
    ln -s /usr/share/novnc/app /opt/noVNC/ && \
    ln -s /usr/share/novnc/core /opt/noVNC/ && \
    ln -s /usr/share/novnc/vendor /opt/noVNC/

# ============================================================================
# LAYER 6: Create wrapper scripts
# ============================================================================

# Compilation wrapper
RUN echo '#!/bin/bash\n\
\n\
COMPILE_ONLY=false\n\
if [ "$1" = "--compile-only" ] || [ "$1" = "-c" ]; then\n\
    COMPILE_ONLY=true\n\
    shift\n\
fi\n\
\n\
if [ $# -eq 0 ]; then\n\
    echo "Usage: graphics.h [--compile-only|-c] <source_file.cpp> [output_name]"\n\
    echo ""\n\
    echo "Examples:"\n\
    echo "  graphics.h program.cpp               # Compile and run"\n\
    echo "  graphics.h --compile-only prog.cpp   # Compile only"\n\
    echo "  graphics.h -c prog.cpp               # Compile only (short)"\n\
    exit 1\n\
fi\n\
\n\
SOURCE_FILE="$1"\n\
OUTPUT_NAME="${2:-$(basename "${SOURCE_FILE%.*}")}"\n\
\n\
if [[ ! "$OUTPUT_NAME" =~ \\.exe$ ]]; then\n\
    OUTPUT_NAME="${OUTPUT_NAME}.exe"\n\
fi\n\
\n\
if [ ! -f "$SOURCE_FILE" ]; then\n\
    echo "Error: Source file '\''$SOURCE_FILE'\'' not found"\n\
    exit 1\n\
fi\n\
\n\
echo "Compiling $SOURCE_FILE -> $OUTPUT_NAME"\n\
\n\
i686-w64-mingw32-g++ "$SOURCE_FILE" \\\n\
  -I /usr/local/include/graphics_h \\\n\
  -L /usr/local/lib/graphics_h \\\n\
  -lbgi -lgdi32 -lcomdlg32 -luuid -loleaut32 -lole32 \\\n\
  -static-libgcc -static-libstdc++ \\\n\
  -o "$OUTPUT_NAME"\n\
\n\
if [ $? -eq 0 ]; then\n\
    echo ""\n\
    echo "✓ Compilation successful: $OUTPUT_NAME"\n\
    \n\
    if [ "$COMPILE_ONLY" = false ]; then\n\
        echo ""\n\
        echo "Running $OUTPUT_NAME with Wine..."\n\
        echo "========================================"\n\
        wine "$OUTPUT_NAME" 2>&1 | grep -v "fixme:"\n\
    else\n\
        echo ""\n\
        echo "To run: wine $OUTPUT_NAME"\n\
    fi\n\
else\n\
    echo ""\n\
    echo "✗ Compilation failed"\n\
    exit 1\n\
fi' > /usr/local/bin/graphics.h && \
    chmod +x /usr/local/bin/graphics.h

# Supervisor configuration
RUN echo '[supervisord]\n\
nodaemon=true\n\
user=root\n\
\n\
[program:xvfb]\n\
command=/usr/bin/Xvfb :99 -screen 0 1280x720x24\n\
autorestart=true\n\
stdout_logfile=/dev/stdout\n\
stdout_logfile_maxbytes=0\n\
stderr_logfile=/dev/stderr\n\
stderr_logfile_maxbytes=0\n\
\n\
[program:fluxbox]\n\
command=/usr/bin/fluxbox\n\
environment=DISPLAY=":99"\n\
autorestart=true\n\
stdout_logfile=/dev/stdout\n\
stdout_logfile_maxbytes=0\n\
stderr_logfile=/dev/stderr\n\
stderr_logfile_maxbytes=0\n\
\n\
[program:x11vnc]\n\
command=/usr/bin/x11vnc -display :99 -xkb -forever -shared -repeat\n\
autorestart=true\n\
stdout_logfile=/dev/stdout\n\
stdout_logfile_maxbytes=0\n\
stderr_logfile=/dev/stderr\n\
stderr_logfile_maxbytes=0\n\
\n\
[program:novnc]\n\
command=/usr/bin/websockify --web=/usr/share/novnc 6080 localhost:5900\n\
autorestart=true\n\
stdout_logfile=/dev/stdout\n\
stdout_logfile_maxbytes=0\n\
stderr_logfile=/dev/stderr\n\
stderr_logfile_maxbytes=0' > /etc/supervisor/conf.d/supervisord.conf

# Startup script
RUN echo '#!/bin/bash\n\
echo "========================================"\n\
echo "  graphics.h with noVNC (Browser Display)"\n\
echo "========================================"\n\
echo ""\n\
echo "Starting services..."\n\
\n\
# Start supervisor in background\n\
/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf &\n\
\n\
# Wait for services to start\n\
sleep 3\n\
\n\
echo ""\n\
echo "✓ All services started!"\n\
echo ""\n\
echo "========================================"\n\
echo "  Access graphics in your browser:"\n\
echo "  http://localhost:6080/vnc.html"\n\
echo "========================================"\n\
echo ""\n\
echo "Quick Start:"\n\
echo "  1. Open http://localhost:6080/vnc.html"\n\
echo "  2. Click '\''Connect'\'' (no password needed)"\n\
echo "  3. Right-click desktop -> Terminal"\n\
echo "  4. Write code: nano program.cpp"\n\
echo "  5. Compile and run: graphics.h program.cpp"\n\
echo "  6. Graphics will appear in browser!"\n\
echo ""\n\
\n\
# Keep container running with bash\n\
exec bash' > /usr/local/bin/start-vnc && \
    chmod +x /usr/local/bin/start-vnc

# ============================================================================
# FINAL: Working directory and ports
# ============================================================================
WORKDIR /workspace
EXPOSE 6080 5900

CMD ["/usr/local/bin/start-vnc"]