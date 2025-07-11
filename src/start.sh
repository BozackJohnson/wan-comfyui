#!/usr/bin/env bash

# This script sets up a ComfyUI environment for WAN 2.1 on a cloud instance like Runpod.

# Set -x to print every command that is executed. This is for debugging.
set -x

# Get the directory of the script itself, to handle relative paths correctly
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# ===============================================
# 1. System Dependency Setup and Checks
# ===============================================

# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "$SCRIPT_DIR/additional_params.sh" ]; then
    chmod +x "$SCRIPT_DIR/additional_params.sh"
    echo "Executing additional_params.sh..."
    "$SCRIPT_DIR/additional_params.sh"
else
    echo "additional_params.sh not found in $SCRIPT_DIR. Skipping..."
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

echo "Downloading optimization loras"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_CausVid_14B_T2V_lora_rank32.safetensors" "$LORAS_DIR/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors" "$LORAS_DIR/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"

# Download text encoders
echo "Downloading text encoders..."
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TEXT_ENCODERS_DIR/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"

# Create CLIP vision directory and download models
mkdir -p "$CLIP_VISION_DIR"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIP_VISION_DIR/clip_vision_h.safetensors"

# Download VAE
echo "Downloading VAE..."
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE_DIR/wan_2.1_vae.safetensors"

# Keep checking until no aria2c processes are running
while pgrep -x "aria2c" > /dev/null; do
    echo "🔽 Model Downloads still in progress..."
    sleep 5  # Check every 5 seconds
done

declare -A MODEL_CATEGORIES=(
    ["$NETWORK_VOLUME/ComfyUI/models/checkpoints"]="$CHECKPOINT_IDS_TO_DOWNLOAD"
    ["$NETWORK_VOLUME/ComfyUI/models/loras"]="$LORAS_IDS_TO_DOWNLOAD"
)

# Counter to track background jobs
download_count=0

# Ensure directories exist and schedule downloads in background
for TARGET_DIR in "${!MODEL_CATEGORIES[@]}"; do
    mkdir -p "$TARGET_DIR"
    IFS=',' read -ra MODEL_IDS <<< "${MODEL_CATEGORIES[$TARGET_DIR]}"

    for MODEL_ID in "${MODEL_IDS[@]}"; do
        sleep 1
        echo "🚀 Scheduling download: $MODEL_ID to $TARGET_DIR"
        (cd "$TARGET_DIR" && download_with_aria.py -m "$MODEL_ID") &
        ((download_count++))
    done
done

echo "📋 Scheduled $download_count downloads in background"

# Wait for all downloads to complete
echo "⏳ Waiting for downloads to complete..."
while pgrep -x "aria2c" > /dev/null; do
    echo "🔽 LoRA Downloads still in progress..."
    sleep 5  # Check every 5 seconds
done


echo "✅ All models downloaded successfully!"

# poll every 5 s until the PID is gone
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    echo "🛠️ Building SageAttention in progress... (this can take around 5 minutes)"
    sleep 10
  done

  echo "Build complete"

echo "All downloads completed!"


echo "Downloading upscale models"
mkdir -p "$NETWORK_VOLUME/ComfyUI/models/upscale_models"
if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth" ]; then
    if [ -f "/4xLSDIR.pth" ]; then
        mv "/4xLSDIR.pth" "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth"
        echo "Moved 4xLSDIR.pth to the correct location."
    else
        echo "4xLSDIR.pth not found in the root directory."
    fi
else
    echo "4xLSDIR.pth already exists. Skipping."
fi

echo "Finished downloading models!"


echo "Checking and copying workflow..."
mkdir -p "$WORKFLOW_DIR"

# Ensure the file exists in the current directory before moving it
cd /

SOURCE_DIR="/comfyui-wan/workflows"

# Ensure destination directory exists
mkdir -p "$WORKFLOW_DIR"

# Loop over each file in the source directory
for file in "$SOURCE_DIR"/*; do
    # Skip if it's not a file
    [[ -f "$file" ]] || continue

    dest_file="$WORKFLOW_DIR/$(basename "$file")"

    if [[ -e "$dest_file" ]]; then
        echo "File already exists in destination. Deleting: $file"
        rm -f "$file"
    else
        echo "Moving: $file to $WORKFLOW_DIR"
        mv "$file" "$WORKFLOW_DIR"
    fi
done

if [ "$change_preview_method" == "true" ]; then
    echo "Updating default preview method..."
    sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js
    CONFIG_PATH="/ComfyUI/user/default/ComfyUI-Manager"
    CONFIG_FILE="$CONFIG_PATH/config.ini"

# Ensure the directory exists
mkdir -p "$CONFIG_PATH"

# Create the config file if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.ini..."
    cat <<EOL > "$CONFIG_FILE"
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
EOL
else
    echo "config.ini already exists. Updating preview_method..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
fi
echo "Config file setup complete!"
    echo "Default preview method updated to 'auto'"
else
    echo "Skipping preview method update (change_preview_method is not 'true')."
fi

# Workspace as main working directory
echo "cd $NETWORK_VOLUME" >> ~/.bashrc


# Install dependencies
wait $KJ_PID
  KJ_STATUS=$?

wait $WAN_PID
WAN_STATUS=$?
echo "✅ KJNodes install complete"
echo "✅ WanVideoWrapper install complete"

# Check results
if [ $KJ_STATUS -ne 0 ]; then
  echo "❌ KJNodes install failed."
  exit 1
fi

if [ $WAN_STATUS -ne 0 ]; then
  echo "❌ WanVideoWrapper install failed."
  exit 1
fi

echo "Renaming loras downloaded as zip files to safetensors files"
cd $LORAS_DIR
for file in *.zip; do
    mv "$file" "${file%.zip}.safetensors"
done

# Start ComfyUI
echo "▶️  Starting ComfyUI"
if [ "$enable_optimizations" = "false" ]; then
    python3 "$NETWORK_VOLUME/ComfyUI/main.py" --listen
else
    nohup python3 "$NETWORK_VOLUME/ComfyUI/main.py" --listen --use-sage-attention > "$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log" 2>&1 &
    # python3 "$NETWORK_VOLUME/ComfyUI/main.py" --listen --use-sage-attention
    until curl --silent --fail "$URL" --output /dev/null; do
      echo "🔄  ComfyUI Starting Up... You can view the startup logs here: $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID}_nohup.log"
      sleep 2
    done
    echo "🚀 ComfyUI is UP"
    sleep infinity
fi
