#!/usr/bin/env bash

# This script sets up a ComfyUI environment for WAN 2.1 on a cloud instance like Runpod.
# It is designed to be placed at the root of a GitHub repository cloned by a Runpod template.

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# ===============================================
# 1. System Dependency Setup and Checks
# ===============================================

# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "/workspace/additional_params.sh" ]; then
    chmod +x /workspace/additional_params.sh
    echo "Executing additional_params.sh..."
    /workspace/additional_params.sh
else
    echo "additional_params.sh not found in /workspace. Skipping..."
fi

# Check for and install essential command-line tools with sudo for elevated privileges
for tool in aria2 curl rsync; do
    if ! which "$tool" > /dev/null 2>&1; then
        echo "Installing $tool..."
        sudo apt-get update && sudo apt-get install -y "$tool"
    else
        echo "$tool is already installed"
    fi
done

# ===============================================
# 2. JupyterLab and Directory Setup
# ===============================================

# Set the network volume path
NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

# Start standard JupyterLab on port 8888, pointing to the persistent workspace directory
echo "Starting standard JupyterLab on port 8888..."
jupyter-lab --ip=0.0.0.0 --port=8888 --allow-root --no-browser --notebook-dir=/workspace &

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

# The Dockerfile already clones ComfyUI to /ComfyUI. We simply move it to the persistent volume.
if [ ! -d "$COMFYUI_DIR" ]; then
    mv /ComfyUI "$COMFYUI_DIR"
else
    echo "Directory already exists, skipping move."
fi

# Create necessary directories
mkdir -p "$CUSTOM_NODES_DIR" "$WORKFLOW_DIR"

# ===============================================
# 3. Custom Node and Optimization Setup
# ===============================================

# Downloading CivitAI download script
echo "Downloading CivitAI download script to /usr/local/bin"
if [ ! -d "/tmp/CivitAI_Downloader" ]; then
    git clone "https://github.com/Hearmeman24/CivitAI_Downloader.git" /tmp/CivitAI_Downloader
fi
mv /tmp/CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || { echo "Move failed"; exit 1; }
chmod +x "/usr/local/bin/download_with_aria.py" || { echo "Chmod failed"; exit 1; }
rm -rf /tmp/CivitAI_Downloader  # Clean up the cloned repo
pip install onnxruntime-gpu &

# Clone and update custom nodes
for repo in "ComfyUI-WanVideoWrapper" "ComfyUI-KJNodes"; do
    REPO_URL="https://github.com/kijai/$repo.git"
    DIR_PATH="$CUSTOM_NODES_DIR/$repo"

    if [ ! -d "$DIR_PATH" ]; then
        echo "Cloning $repo..."
        (cd "$CUSTOM_NODES_DIR" && git clone "$REPO_URL")
    else
        echo "Updating $repo"
        (cd "$DIR_PATH" && git pull)
    fi
done

# Install custom node dependencies in the background
echo "🔧 Installing custom node packages..."
pip install --no-cache-dir -r "$CUSTOM_NODES_DIR/ComfyUI-KJNodes/requirements.txt" &
KJ_PID=$!
pip install --no-cache-dir -r "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper/requirements.txt" &
WAN_PID=$!

# Build SageAttention and Triton in the background
export change_preview_method="true"
echo "Building SageAttention in the background"
(
  git clone https://github.com/thu-ml/SageAttention.git
  cd SageAttention || exit 1
  python3 setup.py install
  cd /
  pip install --no-cache-dir triton
) &> /var/log/sage_build.log &
BUILD_PID=$!
echo "Background build started (PID: $BUILD_PID)"

# ===============================================
# 4. Model Download Logic
# ===============================================

# Function to download a model using aria2c
download_model() {
    local url="$1"
    local full_path="$2"
    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))
        if [ "$size_bytes" -lt 10485760 ]; then
            echo "🗑️ Deleting corrupted file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    if [ -f "${full_path}.aria2" ]; then
        echo "🗑️ Deleting .aria2 control file: ${full_path}.aria2"
        rm -f "${full_path}.aria2"
        rm -f "$full_path"
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."
    aria2c -x 16 -s 16 -k 1M --continue=true -d "$destination_dir" -o "$destination_file" "$url" &
    echo "Download started in background for $destination_file (PID: $!)"
}

# Define base paths for models
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
CLIP_VISION_DIR="$NETWORK_VOLUME/ComfyUI/models/clip_vision"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"

# Conditional Model Downloads
if [ "$download_480p_native_models" == "true" ]; then
    echo "Downloading 480p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
fi

# ... (rest of the script is the same as before) ...
# Please paste the rest of the script from your original version here
