# Start from a robust base image that includes CUDA, Python, and PyTorch
# This saves us from having to install all the core dependencies ourselves.
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# Set up the environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/miniconda3/bin:${PATH}"

# Install necessary system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    wget \
    curl \
    aria2 \
    sudo \
    rsync \
    locales \
    && rm -rf /var/lib/apt/lists/*

# Set up Conda environment
RUN wget \
    https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
    && mkdir /root/.conda \
    && bash Miniconda3-latest-Linux-x86_64.sh -b -p /root/miniconda3 \
    && rm -f Miniconda3-latest-Linux-x86_64.sh
RUN conda install -y python=3.10 pip && conda clean --all

# Set the working directory
WORKDIR /

# Install ComfyUI and its dependencies
RUN git clone https://github.com/comfyanonymous/ComfyUI.git
WORKDIR /ComfyUI
RUN pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
RUN pip install -r requirements.txt
RUN pip install jupyterlab

# Create the /workspace directory
RUN mkdir -p /workspace

# Set the command to run our start script when the container is started
CMD ["/bin/bash"]

# Set the command to run our start script when the container is started
# This assumes the start script is copied into the image later, or cloned via a volume.
CMD ["/bin/bash"]
