#!/usr/bin/env bash
set -e

echo "=========================================="
echo "  graphics.h System-Wide Installer"
echo "=========================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Check if running as root for system-wide installation
if [ "$EUID" -eq 0 ]; then 
    print_error "Please do not run this script as root. It will use sudo when needed."
    exit 1
fi

# 1. Install dependencies
echo ""
echo "[1/6] Installing required packages..."
sudo dpkg --add-architecture i386 2>/dev/null || true
sudo apt update
sudo apt install -y \
  gcc-mingw-w64-i686 \
  g++-mingw-w64-i686 \
  wine32 \
  wine \
  wget \
  ca-certificates

print_status "Dependencies installed"

# 2. Create system-wide directories
echo ""
echo "[2/6] Creating system-wide directories..."
sudo mkdir -p /usr/local/include/graphics_h
sudo mkdir -p /usr/local/lib/graphics_h

print_status "Directories created"

# 3. Download headers and library from corrected URLs
echo ""
echo "[3/6] Downloading graphics.h, winbgim.h, libbgi.a..."

# Create temp directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Download files (using raw.githubusercontent.com for direct file access)
wget -q https://raw.githubusercontent.com/acsfid/graphics.h/main/graphics.h -O graphics.h
wget -q https://raw.githubusercontent.com/acsfid/graphics.h/main/winbgim.h -O winbgim.h
wget -q https://raw.githubusercontent.com/acsfid/graphics.h/main/libbgi.a -O libbgi.a

if [ ! -f graphics.h ] || [ ! -f winbgim.h ] || [ ! -f libbgi.a ]; then
    print_error "Failed to download required files"
    exit 1
fi

print_status "Files downloaded successfully"

# 4. Fix const-correctness in graphics.h
echo ""
echo "[4/6] Patching graphics.h for modern C++ (const-correctness)..."

# Fix initgraph
sed -i 's/void initgraph( int \*graphdriver, int \*graphmode, char \*pathtodriver )/void initgraph( int *graphdriver, int *graphmode, const char *pathtodriver )/g' graphics.h
sed -i 's/void initgraph(int\*, int\*, char\*)/void initgraph(int*, int*, const char*)/g' graphics.h
sed -i 's/void initgraph(int \*, int \*, char \*)/void initgraph(int *, int *, const char *)/g' graphics.h

# Fix outtext functions
sed -i 's/void outtext(char \*textstring)/void outtext(const char *textstring)/g' graphics.h
sed -i 's/void outtext(char\*)/void outtext(const char*)/g' graphics.h

sed -i 's/void outtextxy(int x, int y, char \*textstring)/void outtextxy(int x, int y, const char *textstring)/g' graphics.h
sed -i 's/void outtextxy(int, int, char\*)/void outtextxy(int, int, const char*)/g' graphics.h

# Fix settextstyle if present
sed -i 's/void settextstyle(int font, int direction, int charsize, char\*)/void settextstyle(int font, int direction, int charsize, const char*)/g' graphics.h
sed -i 's/void settextstyle(int, int, int, char\*)/void settextstyle(int, int, int, const char*)/g' graphics.h

# Additional common string functions that might need fixing
sed -i 's/char \*getdrivername/const char *getdrivername/g' graphics.h
sed -i 's/char\* getdrivername/const char* getdrivername/g' graphics.h

print_status "graphics.h patched for const-correctness"

# 5. Install files system-wide
echo ""
echo "[5/6] Installing files system-wide..."

sudo cp graphics.h /usr/local/include/graphics_h/
sudo cp winbgim.h /usr/local/include/graphics_h/
sudo cp libbgi.a /usr/local/lib/graphics_h/

# Verify installation
if [ ! -f /usr/local/include/graphics_h/graphics.h ]; then
    print_error "Installation failed"
    exit 1
fi

print_status "Files installed to /usr/local/include/graphics_h and /usr/local/lib/graphics_h"

# 6. Create compilation wrapper script
echo ""
echo "[6/6] Creating 'graphics.h' command wrapper..."

sudo tee /usr/local/bin/graphics.h > /dev/null << 'WRAPPER_EOF'
#!/usr/bin/env bash

# graphics.h compilation wrapper
# Usage: graphics.h filename.cpp

if [ $# -eq 0 ]; then
    echo "Usage: graphics.h <source_file.cpp> [output_name]"
    echo ""
    echo "Examples:"
    echo "  graphics.h program.cpp          # Creates program.exe"
    echo "  graphics.h program.cpp myapp    # Creates myapp.exe"
    echo ""
    echo "After compilation, run with:"
    echo "  wine program.exe"
    exit 1
fi

SOURCE_FILE="$1"
OUTPUT_NAME="${2:-$(basename "${SOURCE_FILE%.*}")}"

# Add .exe extension if not present
if [[ ! "$OUTPUT_NAME" =~ \.exe$ ]]; then
    OUTPUT_NAME="${OUTPUT_NAME}.exe"
fi

if [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: Source file '$SOURCE_FILE' not found"
    exit 1
fi

echo "Compiling $SOURCE_FILE -> $OUTPUT_NAME"
echo ""

i686-w64-mingw32-g++ "$SOURCE_FILE" \
  -I /usr/local/include/graphics_h \
  -L /usr/local/lib/graphics_h \
  -lbgi -lgdi32 -lcomdlg32 -luuid -loleaut32 -lole32 \
  -static-libgcc -static-libstdc++ \
  -o "$OUTPUT_NAME"

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Compilation successful: $OUTPUT_NAME"
    echo ""
    echo "Run with: wine $OUTPUT_NAME"
else
    echo ""
    echo "✗ Compilation failed"
    exit 1
fi
WRAPPER_EOF

sudo chmod +x /usr/local/bin/graphics.h

print_status "Wrapper script created at /usr/local/bin/graphics.h"

# Cleanup
cd ~
rm -rf "$TEMP_DIR"

# Configure Wine for optimal graphics.h performance (32-bit, reduce flickering)
echo ""
echo "Configuring Wine for graphics.h..."

# Set Wine to 32-bit mode
export WINEARCH=win32
export WINEPREFIX="$HOME/.wine32_graphics"

# Initialize Wine prefix (this will be quick if already done)
wineboot -u 2>/dev/null || true

print_status "Wine configured for 32-bit Windows programs"

# Final instructions
echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""
echo "Usage:"
echo "  1. Write your graphics.h program (e.g., program.cpp)"
echo "  2. Compile with: graphics.h program.cpp"
echo "  3. Run with: wine program.exe"
echo ""
echo "Example:"
echo "  graphics.h myanimation.cpp"
echo "  wine myanimation.exe"
echo ""
print_status "System ready for graphics.h programming!"
echo ""