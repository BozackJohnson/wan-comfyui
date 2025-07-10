#!/usr/bin/env bash

# This script sets up a ComfyUI environment for WAN 2.1 on a cloud instance like Runpod.

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
        echo "$tool is already installed."
    fi
done

# ===============================================
# 2. JupyterLab and Directory Setup
# ===============================================

# Set the network volume path
NETWORK_VOLUME="/workspace"
URL="http://127.0.0.1:8188"

# Check if NETWORK_VOLUME exists; if not, use root directory instead
if [ ! -d "$NETWORK_VOLUME" ]; then
    echo "NETWORK_VOLUME directory '$NETWORK_VOLUME' does not exist. You are NOT using a network volume. Setting NETWORK_VOLUME to '/' (root directory)."
    NETWORK_VOLUME="/"
    echo "NETWORK_VOLUME directory doesn't exist. Starting JupyterLab on root directory..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/ &
else
    echo "NETWORK_VOLUME directory exists. Starting JupyterLab..."
    jupyter-lab --ip=0.0.0.0 --allow-root --no-browser --NotebookApp.token='' --NotebookApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True --notebook-dir=/workspace &
fi

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$NETWORK_VOLUME/ComfyUI/custom_nodes"

# Move ComfyUI to the network volume if it exists in the root
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
git clone "https://github.com/Hearmeman24/CivitAI_Downloader.git" || { echo "Git clone failed"; exit 1; }
mv CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || { echo "Move failed"; exit 1; }
chmod +x "/usr/local/bin/download_with_aria.py" || { echo "Chmod failed"; exit 1; }
rm -rf CivitAI_Downloader

# Install onnxruntime-gpu in background
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
echo "🔧 Installing custom node packages in the background..."
(pip install --no-cache-dir -r "$CUSTOM_NODES_DIR/ComfyUI-KJNodes/requirements.txt") &
KJ_PID=$!
(pip install --no-cache-dir -r "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper/requirements.txt") &
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

    # Corruption check and existing file check in one
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))
        if [ "$size_bytes" -lt 10485760 ]; then # Less than 10MB
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

if [ "$debug_models" == "true" ]; then
    echo "Downloading 480p native debug models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_fp16.safetensors"
fi

if [ "$download_wan_fun_and_sdxl_helper" == "true" ]; then
    echo "Downloading Wan Fun 14B Model"
    download_model "https://huggingface.co/alibaba-pai/Wan2.1-Fun-14B-Control/resolve/main/diffusion_pytorch_model.safetensors" "$DIFFUSION_MODELS_DIR/diffusion_pytorch_model.safetensors"

    UNION_DIR="$NETWORK_VOLUME/ComfyUI/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
    mkdir -p "$UNION_DIR"
    download_model "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "$UNION_DIR/diffusion_pytorch_model_promax.safetensors"
fi

if [ "$download_vace" == "true" ]; then
    echo "Downloading VACE models..."
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_14B_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_1_3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_1_3B_bf16.safetensors"
fi

if [ "$download_vace_debug" == "true" ]; then
    echo "Downloading VACE debug models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_vace_14B_fp16.safetensors"
fi

if [ "$download_720p_native_models" == "true" ]; then
    echo "Downloading 720p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_720p_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
fi

echo "Downloading optimization loras..."
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_CausVid_14B_T2V_lora_rank32.safetensors" "$LORAS_DIR/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors" "$LORAS_DIR/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"

# Download other essential models
echo "Downloading text encoders..."
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TEXT_ENCODERS_DIR/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"

echo "Downloading CLIP vision models..."
mkdir -p "$CLIP_VISION_DIR"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIP_VISION_DIR/clip_vision_h.safetensors"

echo "Downloading VAEs..."
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE_DIR/wan_2.1_vae.safetensors"

# Wait for all background aria2c processes to complete
echo "Waiting for all model downloads to complete..."
while pgrep -x "aria2c" > /dev/null; do
    echo "🔽 Model Downloads still in progress..."
    sleep 5
done
echo "✅ All models downloaded successfully!"

# ===============================================
# 5. Final Setup and Launch
# ===============================================

# Wait for background pip and build jobs
echo "⏳ Waiting for custom node package installations to complete..."
wait $KJ_PID
KJ_STATUS=$?
wait $WAN_PID
WAN_STATUS=$?

if [ $KJ_STATUS -ne 0 ]; then
    echo "❌ KJNodes install failed."
    exit 1
fi
if [ $WAN_STATUS -ne 0 ]; then
    echo "❌ WanVideoWrapper install failed."
    exit 1
fi
echo "✅ KJNodes and WanVideoWrapper installs complete."

# Wait for the SageAttention build to complete
echo "⏳ Waiting for SageAttention build to complete... (this can take around 5 minutes)"
while kill -0 "$BUILD_PID" 2>/dev/null; do
    echo "🛠️ Building SageAttention in progress..."
    sleep 10
done
echo "✅ SageAttention build complete."

# Renaming loras downloaded as zip files
echo "Renaming loras downloaded as zip files to safetensors files"
cd $LORAS_DIR || exit 1
for file in *.zip; do
    if [ -f "$file" ]; then
        echo "Renaming $file to ${file%.zip}.safetensors"
        mv "$file" "${file%.zip}.safetensors"
    fi
done

# Check and copy workflows
echo "Checking and copying workflow..."
SOURCE_DIR="/comfyui-wan/workflows"
for file in "$SOURCE_DIR"/*; do
    if [ -f "$file" ]; then
        dest_file="$WORKFLOW_DIR/$(basename "$file")"
        if [[ -e "$dest_file" ]]; then
            echo "File already exists in destination. Deleting: $file"
            rm -f "$file"
        else
            echo "Moving: $file to $WORKFLOW_DIR"
            mv "$file" "$WORKFLOW_DIR"
        fi
    fi
done

# Configure ComfyUI-Manager
if [ "$change_preview_method" == "true" ]; then
    echo "Updating default preview method via config.ini..."
    CONFIG_PATH="$NETWORK_VOLUME/ComfyUI/user/default/ComfyUI-Manager"
