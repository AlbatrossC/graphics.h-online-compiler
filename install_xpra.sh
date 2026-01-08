#!/bin/bash

# Stop script on any error
set -e

echo "--- 1. Updating System and Installing Prerequisites ---"
sudo apt-get update
sudo apt-get install -y wget gnupg2 software-properties-common apt-transport-https

echo "--- 2. Adding Xpra GPG Key ---"
# Download key and add it to trusted keys
wget -q https://xpra.org/gpg.asc -O- | sudo apt-key add -

echo "--- 3. Adding Xpra Repository for Ubuntu 22.04 (Jammy) ---"
sudo add-apt-repository "deb https://xpra.org/ jammy main" -y

echo "--- 4. Installing Xpra, HTML5 Client, and Dummy Driver ---"
sudo apt-get update
sudo apt-get install -y xpra xpra-html5 

echo "--- 5. Verifying Installation ---"
xpra --version

echo "-------------------------------------------------------"
echo "Installation Complete."
