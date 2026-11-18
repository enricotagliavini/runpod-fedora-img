# Start with a clean Fedora base
FROM docker://registry.fedoraproject.org/fedora-minimal:44

# Prevent interactive prompts during build
ENV TZ=Etc/UTC

# Install base tools and compilation dependencies
RUN dnf update -y && \
    # dnf install dnf5-plugins -y && \
    echo -e '\ninstall_weak_deps=False\n' >> /etc/dnf/dnf.conf && \
    dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm && \
    dnf install wget xorg-x11-drv-nvidia-cuda openssh-server uv -y && \
    wget "https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo" -O /etc/yum.repos.d/cuda-fedora44.repo && \
    dnf install createrepo_c htop bash vim less bc sudo tee coreutils libcublas13-cuda-13 cuda-compat-13-5 -y && \
    /usr/libexec/openssh/sshd-keygen ed25519 && \
    uv pip install --system huggingface_hub
    # dnf install -y cuda-toolkit \

COPY id_rsa.pub /root/.ssh/fallback_key.pub
RUN wget -O /etc/yum.repos.d/ai-custom-infra.repo https://enricotagliavini.github.io/repositories/ai-custom-infra/ai-custom-infra.repo && \
    dnf install -y lemonade-server llama-cpp && dnf clean all

COPY lemonadectl /app/lemonadectl
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh /app/lemonadectl

# Set up working directory
WORKDIR /app
# Expose ports for SSH (22)
EXPOSE 22
# if you want to expose multiple ports:
#EXPOSE 22 12345

CMD ["/app/run.sh"]


