#!/usr/bin/env bash
# This is a simplified startup script for a Runpod template with a custom Docker image.

# Exit immediately if a command exits with a non-zero status.
set -e

# Get the directory of the script itself
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
COMFYUI_DIR="/workspace/ComfyUI"

# 1. Mount the ComfyUI installation to the persistent volume
echo "Checking if ComfyUI is mounted..."
if [ ! -d "$COMFYUI_DIR" ]; then
    echo "Mounting ComfyUI to persistent volume..."
    mv /ComfyUI "$COMFYUI_DIR"
else
    echo "ComfyUI already mounted. Skipping."
fi

# 2. Check and Install Custom Nodes
echo "Installing custom nodes..."
cd "$COMFYUI_DIR/custom_nodes"
for repo in ComfyUI-WanVideoWrapper ComfyUI-KJNodes; do
    if [ ! -d "$repo" ]; then
        git clone "https://github.com/kijai/$repo.git"
    fi
    pip install --no-cache-dir -r "$repo/requirements.txt"
done

# 3. Build SageAttention (if enabled)
if [ "$enable_optimizations" != "false" ]; then
    echo "Building SageAttention..."
    if [ ! -d "SageAttention" ]; then
        git clone https://github.com/thu-ml/SageAttention.git
    fi
    cd SageAttention
    python3 setup.py install
    cd "$COMFYUI_DIR/custom_nodes"
fi

# 4. Start ComfyUI
echo "Starting ComfyUI..."
cd "$COMFYUI_DIR"
python3 main.py --listen
